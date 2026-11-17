// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {VestingWallet} from "@openzeppelin/contracts/finance/VestingWallet.sol";
import {HajToken} from "../src/HajToken.sol";
import {HajClaim} from "../src/HajClaim.sol";
import {HajLPLock} from "../src/HajLPLock.sol";
import {Networks} from "./lib/Uniswap.sol";

/// @notice Launch step 1: deploys the token, both vesting wallets, the claim contract and the liquidity lock, and hands
///         out 400,000 HAJ. The other 600,000 stay with the founder for exactly one more step, script/Pool.s.sol,
///         which puts them in the pool and the position in the lock.
///
///   FOUNDER=0x… (Ledger account 0, signs) SEASONS=0x… (Ledger account 1) \
///   forge script script/Deploy.s.sol --rpc-url base --ledger --sender $FOUNDER --broadcast --verify
contract Deploy is Script {
    uint64 internal constant YEAR = 365 days;

    struct Deployed {
        HajToken token;
        VestingWallet founderVest;
        VestingWallet seasonsVest;
        HajClaim claim;
        HajLPLock lock;
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
        d.launch = uint64(block.timestamp);

        vm.startBroadcast(founder);
        d.token = new HajToken();
        // Founder: nothing for a year, then evenly over the next year. Seasons: all of it at once, after a year.
        d.founderVest = new VestingWallet(founder, d.launch + YEAR, YEAR);
        d.seasonsVest = new VestingWallet(seasons, d.launch + YEAR, 0);
        // Season 1: the founder sets the reward list once; unclaimed HAJ can only go to the seasons lock.
        d.claim = new HajClaim(d.token, founder, address(d.seasonsVest));
        d.lock = new HajLPLock(Networks.positionManager(block.chainid), founder);

        d.token.transfer(address(d.claim), 100_000e18);
        d.token.transfer(address(d.seasonsVest), 200_000e18);
        d.token.transfer(address(d.founderVest), 100_000e18);
        vm.stopBroadcast();

        require(d.token.balanceOf(founder) == 600_000e18, "founder should hold exactly the pool's 600,000");
    }

    function write(Deployed memory d) internal {
        string memory k = "deployment";
        vm.serializeUint(k, "chainId", block.chainid);
        vm.serializeUint(k, "launch", d.launch);
        vm.serializeAddress(k, "token", address(d.token));
        vm.serializeAddress(k, "founderVesting", address(d.founderVest));
        vm.serializeAddress(k, "seasonsVesting", address(d.seasonsVest));
        vm.serializeAddress(k, "claim", address(d.claim));
        vm.serializeUint(k, "launchPosition", 0); // filled in by script/Pool.s.sol
        string memory json = vm.serializeAddress(k, "lpLock", address(d.lock));
        string memory path = string.concat("deployments/", Networks.name(block.chainid), ".json");
        vm.writeJson(json, path);
        console.log("wrote", path);
    }
}
