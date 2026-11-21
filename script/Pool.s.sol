// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {HajLPLock} from "../src/HajLPLock.sol";
import {HajLaunchHook} from "../src/HajLaunchHook.sol";
import {Networks, PriceMath} from "./lib/Uniswap.sol";

/// @notice Launch step 2, one Ledger-signed broadcast: opens the native-ETH/HAJ Uniswap v4 pool with the launch hook
///         at the price the founder's 600,000 HAJ and POOL_ETH make, adds them as one full-range position minted
///         straight into the lock, and registers it there. The founder's liquidity is what starts the hook's fee
///         clock (80% falling to 1% over 90 s), so the clock starts the moment liquidity exists. Afterwards the
///         founder holds 0 HAJ (any rounding dust goes to the seasons lock) and gets back any ETH the mint didn't use.
///
///   FOUNDER=0x… POOL_ETH=<wei> forge script script/Pool.s.sol --rpc-url base --ledger --sender $FOUNDER --broadcast
contract Pool is Script {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    function run() external returns (uint256 tokenId) {
        string memory path = string.concat("deployments/", Networks.name(block.chainid), ".json");
        string memory json = vm.readFile(path);
        tokenId = open(
            vm.envAddress("FOUNDER"),
            HajLaunchHook(vm.parseJsonAddress(json, ".hook")),
            HajLPLock(vm.parseJsonAddress(json, ".lpLock")),
            vm.parseJsonAddress(json, ".seasonsVesting"),
            vm.envUint("POOL_ETH")
        );
        if (vm.envOr("WRITE_DEPLOYMENTS", true)) vm.writeJson(vm.toString(tokenId), path, ".launchPosition");
    }

    /// @notice The full-range mint: MINT_POSITION owned by the lock, pay both sides, sweep unused ETH back.
    function _mintCall(PoolKey memory key, uint128 liquidity, uint256 eth, address lock, address founder)
        internal
        pure
        returns (bytes memory unlockData)
    {
        bytes memory actions =
            abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP));
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            key,
            Networks.FULL_LOWER,
            Networks.FULL_UPPER,
            uint256(liquidity),
            uint128(eth),
            uint128(600_000e18),
            lock,
            ""
        );
        params[1] = abi.encode(key.currency0, key.currency1);
        params[2] = abi.encode(key.currency0, founder);
        unlockData = abi.encode(actions, params);
    }

    /// @notice One launch: who, which contracts, how much ETH, the starting price and the position it makes.
    struct Launch {
        address founder;
        HajLaunchHook hook;
        HajLPLock lock;
        address seasons;
        uint256 eth;
        uint160 price;
        uint128 liquidity;
        uint256 tokenId;
    }

    function open(address founder, HajLaunchHook hook, HajLPLock lock, address seasons, uint256 eth)
        public
        returns (uint256 tokenId)
    {
        Networks.Uniswap memory u = Networks.uniswap(block.chainid);
        Launch memory l = Launch(founder, hook, lock, seasons, eth, 0, 0, 0);
        _check(u, l);
        l.price = PriceMath.sqrtPriceX96(eth, 600_000e18); // ETH is currency0, HAJ currency1
        l.liquidity = LiquidityAmounts.getLiquidityForAmounts(
            l.price,
            TickMath.getSqrtPriceAtTick(Networks.FULL_LOWER),
            TickMath.getSqrtPriceAtTick(Networks.FULL_UPPER),
            eth,
            600_000e18
        );
        l.tokenId = tokenId = u.positionManager.nextTokenId();
        uint256 dust = _launch(u, l);
        _verify(u, l);
        console.log("pool id");
        console.logBytes32(PoolId.unwrap(hook.poolKey().toId()));
        console.log("position", tokenId, "locked until", lock.unlockAt(tokenId));
        console.log("HAJ dust sent to seasons", dust);
    }

    function _check(Networks.Uniswap memory u, Launch memory l) internal view {
        require(l.hook.founder() == l.founder, "hook is for another founder");
        require(address(l.hook.poolManager()) == address(u.poolManager), "hook is for another pool manager");
        require(address(l.lock.positions()) == address(u.positionManager) && l.lock.owner() == l.founder, "lock");
        require(IERC20(l.hook.haj()).balanceOf(l.founder) == 600_000e18, "founder should hold exactly 600,000 HAJ");
        require(l.eth > 0, "POOL_ETH");
        (uint160 already,,,) = u.poolManager.getSlot0(l.hook.poolKey().toId());
        require(already == 0, "pool already open: stop and check");
    }

    /// @notice Everything the Ledger signs, in order.
    function _launch(Networks.Uniswap memory u, Launch memory l) internal returns (uint256 dust) {
        IERC20 haj = IERC20(l.hook.haj());
        PoolKey memory key = l.hook.poolKey();
        bytes memory mint = _mintCall(key, l.liquidity, l.eth, address(l.lock), l.founder);

        vm.startBroadcast(l.founder);
        // Permit2 is how the v4 position manager pulls tokens: allow exactly 600,000 HAJ, for 20 minutes.
        haj.approve(address(u.permit2), 600_000e18);
        u.permit2.approve(address(haj), address(u.positionManager), 600_000e18, uint48(block.timestamp + 20 minutes));
        // Only the founder can open this pool (the hook checks); nobody can add liquidity or swap until the next call.
        u.poolManager.initialize(key, l.price);
        u.positionManager.modifyLiquidities{value: l.eth}(mint, block.timestamp + 20 minutes);
        l.lock.register(l.tokenId);
        dust = haj.balanceOf(l.founder);
        if (dust > 0) haj.transfer(l.seasons, dust);
        haj.approve(address(u.permit2), 0);
        u.permit2.approve(address(haj), address(u.positionManager), 0, 0);
        vm.stopBroadcast();
    }

    function _verify(Networks.Uniswap memory u, Launch memory l) internal view {
        (uint160 opened,,,) = u.poolManager.getSlot0(l.hook.poolKey().toId());
        require(opened == l.price, "pool should sit at the launch price");
        require(l.hook.startedAt() == block.timestamp, "fee clock should start with the liquidity");
        require(IERC20(l.hook.haj()).balanceOf(l.founder) == 0, "founder should hold 0 HAJ");
        require(u.positionManager.getPositionLiquidity(l.tokenId) == l.liquidity, "position liquidity");
        require(
            IERC721(address(u.positionManager)).ownerOf(l.tokenId) == address(l.lock), "position should be in the lock"
        );
        require(l.lock.unlockAt(l.tokenId) >= l.lock.launchUnlock(), "position should be locked");
    }
}
