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
///         at a starting value the founder picks, and mints two positions straight into the lock:
///
///         - the sale: all 600,000 HAJ, from the starting price up (single-sided: it holds no ETH at the start). A
///           buy moves the price as if START_ETH × 0.6 of ETH stood behind the pool, so the starting value, not the
///           ETH, sets how far a buy moves the price.
///         - the floor: FLOOR_ETH of ETH only, waiting between FLOOR_HIGH_BPS and FLOOR_LOW_BPS of the starting price
///           (default 95% down to 50%), so HAJ sold below the start meets real ETH.
///
///         The founder's first liquidity starts the hook's fee clock (80% falling to 1% over 90 s), so the clock starts
///         the moment the pool can trade. Afterwards the founder holds 0 HAJ (rounding dust goes to the seasons lock).
///
///   FOUNDER=0x… START_ETH=<wei: the value of all 1,000,000 HAJ at open> FLOOR_ETH=<wei> \
///   forge script script/Pool.s.sol --rpc-url base --ledger --sender $FOUNDER --broadcast
contract Pool is Script {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    uint256 internal constant SALE = 600_000e18;

    /// @notice One launch: who, which contracts, the starting value, the floor, and the two positions it makes.
    struct Launch {
        address founder;
        HajLaunchHook hook;
        HajLPLock lock;
        address seasons;
        uint256 startEth;
        uint256 floorEth;
        uint256 floorLowBps;
        uint256 floorHighBps;
        int24 tick; // the pool opens exactly on this tick: the sale's upper edge
        uint160 price;
        int24 floorLower;
        int24 floorUpper;
        uint128 saleLiquidity;
        uint128 floorLiquidity;
        uint256 sale; // position ids
        uint256 floor;
    }

    function run() external returns (uint256 sale, uint256 floor) {
        string memory path = string.concat("deployments/", Networks.name(block.chainid), ".json");
        string memory json = vm.readFile(path);
        (sale, floor) = open(
            vm.envAddress("FOUNDER"),
            HajLaunchHook(vm.parseJsonAddress(json, ".hook")),
            HajLPLock(vm.parseJsonAddress(json, ".lpLock")),
            vm.parseJsonAddress(json, ".seasonsVesting"),
            vm.envUint("START_ETH"),
            vm.envUint("FLOOR_ETH"),
            vm.envOr("FLOOR_LOW_BPS", uint256(5000)),
            vm.envOr("FLOOR_HIGH_BPS", uint256(9500))
        );
        if (vm.envOr("WRITE_DEPLOYMENTS", true)) {
            vm.writeJson(vm.toString(sale), path, ".launchPosition");
            vm.writeJson(vm.toString(floor), path, ".floorPosition");
        }
    }

    function open(
        address founder,
        HajLaunchHook hook,
        HajLPLock lock,
        address seasons,
        uint256 startEth,
        uint256 floorEth,
        uint256 floorLowBps,
        uint256 floorHighBps
    ) public returns (uint256 sale, uint256 floor) {
        Networks.Uniswap memory u = Networks.uniswap(block.chainid);
        Launch memory l;
        (l.founder, l.hook, l.lock, l.seasons) = (founder, hook, lock, seasons);
        (l.startEth, l.floorEth, l.floorLowBps, l.floorHighBps) = (startEth, floorEth, floorLowBps, floorHighBps);
        _check(u, l);
        plan(l);
        l.sale = sale = u.positionManager.nextTokenId();
        l.floor = floor = sale + 1;
        uint256 dust = _launch(u, l);
        _verify(u, l);
        console.log("pool id");
        console.logBytes32(PoolId.unwrap(hook.poolKey().toId()));
        console.log("opening tick", vm.toString(l.tick));
        console.log("sale position", sale, "locked until", lock.unlockAt(sale));
        console.log("floor position", floor, "locked until", lock.unlockAt(floor));
        console.log("HAJ dust sent to seasons", dust);
    }

    /// @notice The numbers, before anything is signed. ETH is currency0 and the pool's price is HAJ per ETH, so a
    ///         dearer HAJ is a lower tick: the sale (HAJ only) sits wholly below the opening tick, the floor (ETH
    ///         only) wholly above it.
    function plan(Launch memory l) public pure {
        // The opening tick: the starting value's price, rounded onto the 200-tick spacing toward a cheaper HAJ, so
        // the pool opens at or (by under 2%) below the value asked for.
        int24 exact = TickMath.getTickAtSqrtPrice(PriceMath.sqrtPriceX96(l.startEth, 1_000_000e18));
        l.tick = PriceMath.ceilTo(exact, Networks.SPACING);
        l.price = TickMath.getSqrtPriceAtTick(l.tick);
        l.saleLiquidity =
            LiquidityAmounts.getLiquidityForAmount1(TickMath.getSqrtPriceAtTick(Networks.FULL_LOWER), l.price, SALE);
        l.floorLower = PriceMath.ceilTo(l.tick + int24(int256(PriceMath.ticksFor(l.floorHighBps))), Networks.SPACING);
        l.floorUpper = PriceMath.ceilTo(l.tick + int24(int256(PriceMath.ticksFor(l.floorLowBps))), Networks.SPACING);
        require(l.tick < l.floorLower && l.floorLower < l.floorUpper, "floor range too narrow for the spacing");
        require(l.floorUpper <= Networks.FULL_UPPER, "starting value too low");
        l.floorLiquidity = LiquidityAmounts.getLiquidityForAmount0(
            TickMath.getSqrtPriceAtTick(l.floorLower), TickMath.getSqrtPriceAtTick(l.floorUpper), l.floorEth
        );
        require(l.saleLiquidity > 0 && l.floorLiquidity > 0, "positions too small");
    }

    /// @notice Both mints in one call: MINT_POSITION ×2 owned by the lock, pay (HAJ for the sale, ETH for the floor),
    ///         sweep any unused ETH back to the founder.
    function _mintCall(PoolKey memory key, Launch memory l) internal pure returns (bytes memory unlockData) {
        bytes memory actions = abi.encodePacked(
            uint8(Actions.MINT_POSITION), uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP)
        );
        bytes[] memory params = new bytes[](4);
        params[0] = abi.encode(
            key, Networks.FULL_LOWER, l.tick, uint256(l.saleLiquidity), uint128(0), uint128(SALE), address(l.lock), ""
        );
        params[1] = abi.encode(
            key, l.floorLower, l.floorUpper, uint256(l.floorLiquidity), uint128(l.floorEth), uint128(0), address(l.lock), ""
        );
        params[2] = abi.encode(key.currency0, key.currency1);
        params[3] = abi.encode(key.currency0, l.founder);
        unlockData = abi.encode(actions, params);
    }

    function _check(Networks.Uniswap memory u, Launch memory l) internal view {
        require(l.hook.founder() == l.founder, "hook is for another founder");
        require(address(l.hook.poolManager()) == address(u.poolManager), "hook is for another pool manager");
        require(address(l.lock.positions()) == address(u.positionManager) && l.lock.owner() == l.founder, "lock");
        require(IERC20(l.hook.haj()).balanceOf(l.founder) == SALE, "founder should hold exactly 600,000 HAJ");
        require(l.startEth > 0, "START_ETH");
        require(l.floorEth > 0, "FLOOR_ETH");
        require(l.floorLowBps < l.floorHighBps && l.floorHighBps < 10_000, "need FLOOR_LOW_BPS < FLOOR_HIGH_BPS < 10000");
        (uint160 already,,,) = u.poolManager.getSlot0(l.hook.poolKey().toId());
        require(already == 0, "pool already open: stop and check");
    }

    /// @notice Everything the Ledger signs, in order.
    function _launch(Networks.Uniswap memory u, Launch memory l) internal returns (uint256 dust) {
        IERC20 haj = IERC20(l.hook.haj());
        PoolKey memory key = l.hook.poolKey();
        bytes memory mint = _mintCall(key, l);

        vm.startBroadcast(l.founder);
        // Permit2 is how the v4 position manager pulls tokens: allow exactly 600,000 HAJ, for 20 minutes.
        haj.approve(address(u.permit2), SALE);
        u.permit2.approve(address(haj), address(u.positionManager), uint160(SALE), uint48(block.timestamp + 20 minutes));
        // Only the founder can open this pool (the hook checks); nobody can add liquidity or swap until the next call.
        u.poolManager.initialize(key, l.price);
        u.positionManager.modifyLiquidities{value: l.floorEth}(mint, block.timestamp + 20 minutes);
        l.lock.register(l.sale);
        l.lock.register(l.floor);
        dust = haj.balanceOf(l.founder);
        if (dust > 0) haj.transfer(l.seasons, dust);
        haj.approve(address(u.permit2), 0);
        u.permit2.approve(address(haj), address(u.positionManager), 0, 0);
        vm.stopBroadcast();
    }

    function _verify(Networks.Uniswap memory u, Launch memory l) internal view {
        (uint160 opened, int24 tick,,) = u.poolManager.getSlot0(l.hook.poolKey().toId());
        require(opened == l.price && tick == l.tick, "pool should sit at the launch price");
        require(l.hook.startedAt() == block.timestamp, "fee clock should start with the liquidity");
        require(IERC20(l.hook.haj()).balanceOf(l.founder) == 0, "founder should hold 0 HAJ");
        require(u.positionManager.getPositionLiquidity(l.sale) == l.saleLiquidity, "sale liquidity");
        require(u.positionManager.getPositionLiquidity(l.floor) == l.floorLiquidity, "floor liquidity");
        IERC721 nft = IERC721(address(u.positionManager));
        require(nft.ownerOf(l.sale) == address(l.lock) && nft.ownerOf(l.floor) == address(l.lock), "positions in the lock");
        require(l.lock.unlockAt(l.sale) >= l.lock.launchUnlock(), "sale should be locked");
        require(l.lock.unlockAt(l.floor) >= l.lock.launchUnlock(), "floor should be locked");
    }
}
