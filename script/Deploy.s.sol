// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {VestingWallet} from "@openzeppelin/contracts/finance/VestingWallet.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HajToken} from "../src/HajToken.sol";
import {HajClaim} from "../src/HajClaim.sol";
import {HajLPLock} from "../src/HajLPLock.sol";
import {HajLaunchHook} from "../src/HajLaunchHook.sol";
import {Networks} from "./lib/Uniswap.sol";

/// @notice Launch step 1: deploys the token, both vesting wallets, the claim contract, the liquidity lock and the
///         launch hook, and hands out 400,000 HAJ. The other 600,000 stay with the founder for exactly one more step,
///         script/Pool.s.sol, which opens the pool, puts them in it and the position in the lock.
///
///   FOUNDER=0x… (Ledger account 0, signs) SEASONS=0x… (Ledger account 1) \
///   forge script script/Deploy.s.sol --rpc-url base --ledger --sender $FOUNDER --broadcast --verify
contract Deploy is Script {
    uint64 internal constant YEAR = 365 days;

    /// @notice What the hook's address must say: before initialize, before add liquidity, before swap, nothing else.
    uint160 internal constant HOOK_FLAGS =
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG;

    struct Deployed {
        HajToken token;
        VestingWallet founderVest;
        VestingWallet seasonsVest;
        HajClaim claim;
        HajLPLock lock;
        HajLaunchHook hook;
        uint64 launch;
    }

    function run() external returns (Deployed memory d) {
        d = deploy(vm.envAddress("FOUNDER"), vm.envAddress("SEASONS"));
        if (vm.envOr("WRITE_DEPLOYMENTS", true)) write(d);
    }

    function deploy(address founder, address seasons) public returns (Deployed memory d) {
        require(
            founder != address(0) && seasons != address(0) && founder != seasons, "founder and seasons: two addresses"
        );
        Networks.Uniswap memory u = Networks.uniswap(block.chainid);
        d.launch = uint64(block.timestamp);

        vm.startBroadcast(founder);
        d.token = new HajToken();
        // Founder: nothing for a year, then evenly over the next year. Seasons: all of it at once, after a year.
        d.founderVest = new VestingWallet(founder, d.launch + YEAR, YEAR);
        d.seasonsVest = new VestingWallet(seasons, d.launch + YEAR, 0);
        // Season 1: the founder sets the reward list once; unclaimed HAJ can only go to the seasons lock.
        d.claim = new HajClaim(d.token, founder, address(d.seasonsVest));
        d.lock = new HajLPLock(u.positionManager, founder);

        d.token.transfer(address(d.claim), 100_000e18);
        d.token.transfer(address(d.seasonsVest), 200_000e18);
        d.token.transfer(address(d.founderVest), 100_000e18);
        vm.stopBroadcast();

        // The hook goes through the standard CREATE2 deployer, called directly (an ordinary transaction to it, the
        // same on every chain and under every signer), at a salt mined here before anything is signed, so its
        // address carries exactly HOOK_FLAGS. Forge's own routing of `new X{salt: …}` can't be relied on for this:
        // forge 1.9 ran it from the founder's address in a script, which lands somewhere else.
        bytes memory initcode =
            abi.encodePacked(type(HajLaunchHook).creationCode, abi.encode(u.poolManager, founder, address(d.token)));
        (bytes32 salt, address at) = mine(keccak256(initcode));
        vm.broadcast(founder);
        (bool ok, bytes memory made) = CREATE2_FACTORY.call(abi.encodePacked(salt, initcode));
        require(ok && made.length == 20 && address(bytes20(made)) == at, "hook did not land at the mined address");
        d.hook = HajLaunchHook(at);

        require(d.token.balanceOf(founder) == 600_000e18, "founder should hold exactly the pool's 600,000");
        require(d.hook.founder() == founder && d.hook.haj() == address(d.token), "hook");
        require(address(d.hook.poolManager()) == address(u.poolManager), "hook pool manager");
    }

    /// @notice The first salt whose CREATE2 address carries exactly the hook's flags and holds no code yet.
    function mine(bytes32 initcodeHash) public view returns (bytes32 salt, address at) {
        for (uint256 i; i < 400_000; i++) {
            salt = bytes32(i);
            at = vm.computeCreate2Address(salt, initcodeHash, CREATE2_FACTORY);
            if (uint160(at) & Hooks.ALL_HOOK_MASK == HOOK_FLAGS && at.code.length == 0) return (salt, at);
        }
        revert("no hook salt found");
    }

    function write(Deployed memory d) internal {
        string memory k = "deployment";
        vm.serializeUint(k, "chainId", block.chainid);
        vm.serializeUint(k, "launch", d.launch);
        vm.serializeAddress(k, "token", address(d.token));
        vm.serializeAddress(k, "founderVesting", address(d.founderVest));
        vm.serializeAddress(k, "seasonsVesting", address(d.seasonsVest));
        vm.serializeAddress(k, "claim", address(d.claim));
        vm.serializeAddress(k, "hook", address(d.hook));
        vm.serializeUint(k, "launchPosition", 0); // filled in by script/Pool.s.sol
        string memory json = vm.serializeAddress(k, "lpLock", address(d.lock));
        string memory path = string.concat("deployments/", Networks.name(block.chainid), ".json");
        vm.writeJson(json, path);
        console.log("wrote", path);
    }
}
