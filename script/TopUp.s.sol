// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {HajLPLock} from "../src/HajLPLock.sol";
import {HajLaunchHook} from "../src/HajLaunchHook.sol";
import {Networks, PriceMath} from "./lib/Uniswap.sol";

/// @notice Adds deeper liquidity: an ETH-only position between LOW_BPS and HIGH_BPS of HAJ's current price (e.g.
///         5000 and 9500 = from half the price up to 95% of it). It holds only ETH, so it needs no HAJ, and it is
///         minted straight into the lock with its own 365-day unlock. Writes deployments/topups/<network>-<tokenId>.json.
///
///   FOUNDER=0x… TOPUP_ETH=<wei> LOW_BPS=5000 HIGH_BPS=9500 \
///   forge script script/TopUp.s.sol --rpc-url base --ledger --sender $FOUNDER --broadcast
contract TopUp is Script {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    struct Range {
        int24 lower;
        int24 upper;
        int24 tickNow;
        uint128 liquidity;
    }

    function run() external returns (uint256 tokenId) {
        string memory json = vm.readFile(string.concat("deployments/", Networks.name(block.chainid), ".json"));
        HajLaunchHook hook = HajLaunchHook(vm.parseJsonAddress(json, ".hook"));
        HajLPLock lock = HajLPLock(vm.parseJsonAddress(json, ".lpLock"));
        uint256 eth = vm.envUint("TOPUP_ETH");
        Range memory r;
        (tokenId, r) = add(vm.envAddress("FOUNDER"), hook, lock, eth, vm.envUint("LOW_BPS"), vm.envUint("HIGH_BPS"));
        if (vm.envOr("WRITE_DEPLOYMENTS", true)) {
            string memory k = "topup";
            vm.serializeUint(k, "tokenId", tokenId);
            vm.serializeUint(k, "eth", eth);
            vm.serializeInt(k, "tickLower", r.lower);
            vm.serializeInt(k, "tickUpper", r.upper);
            vm.serializeInt(k, "tickAtAdd", r.tickNow);
            string memory out = vm.serializeUint(k, "unlockAt", lock.unlockAt(tokenId));
            vm.writeJson(
                out,
                string.concat("deployments/topups/", Networks.name(block.chainid), "-", vm.toString(tokenId), ".json")
            );
        }
    }

    /// @notice The ETH-only range for HAJ prices between lowBps and highBps of now, on the pool's tick spacing.
    /// @dev    ETH is currency0 and the pool's price is HAJ per ETH, so a lower HAJ price is a higher tick, and a range
    ///         wholly above the current tick holds only currency0 = ETH.
    function _range(IPoolManager pm, PoolKey memory key, uint256 eth, uint256 lowBps, uint256 highBps)
        internal
        view
        returns (Range memory r)
    {
        uint160 price;
        (price, r.tickNow,,) = pm.getSlot0(key.toId());
        require(price != 0, "no pool yet");
        int24 near = int24(int256(PriceMath.ticksFor(highBps)));
        int24 far = int24(int256(PriceMath.ticksFor(lowBps)));
        r.lower = PriceMath.ceilTo(r.tickNow + near + 1, Networks.SPACING);
        r.upper = PriceMath.ceilTo(r.tickNow + far + 1, Networks.SPACING);
        if (r.upper > Networks.FULL_UPPER) r.upper = Networks.FULL_UPPER; // HAJ already near zero: stop at the edge
        require(r.lower < r.upper, "range too narrow for the 200-tick spacing");
        r.liquidity = LiquidityAmounts.getLiquidityForAmount0(
            TickMath.getSqrtPriceAtTick(r.lower), TickMath.getSqrtPriceAtTick(r.upper), eth
        );
        require(r.liquidity > 0, "TOPUP_ETH too small");
    }

    function _mintCall(PoolKey memory key, Range memory r, uint256 eth, address lock, address founder)
        internal
        pure
        returns (bytes memory unlockData)
    {
        bytes memory actions =
            abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP));
        bytes[] memory params = new bytes[](3);
        // ETH-only: at most `eth` of ETH, and no HAJ at all.
        params[0] = abi.encode(key, r.lower, r.upper, uint256(r.liquidity), uint128(eth), uint128(0), lock, "");
        params[1] = abi.encode(key.currency0, key.currency1);
        params[2] = abi.encode(key.currency0, founder);
        unlockData = abi.encode(actions, params);
    }

    function add(address founder, HajLaunchHook hook, HajLPLock lock, uint256 eth, uint256 lowBps, uint256 highBps)
        public
        returns (uint256 tokenId, Range memory r)
    {
        require(eth > 0, "TOPUP_ETH");
        require(lowBps < highBps && highBps < 10_000, "need LOW_BPS < HIGH_BPS < 10000");
        Networks.Uniswap memory u = Networks.uniswap(block.chainid);
        r = _range(u.poolManager, hook.poolKey(), eth, lowBps, highBps);
        tokenId = u.positionManager.nextTokenId();
        bytes memory mint = _mintCall(hook.poolKey(), r, eth, address(lock), founder);

        vm.startBroadcast(founder);
        u.positionManager.modifyLiquidities{value: eth}(mint, block.timestamp + 20 minutes);
        lock.register(tokenId);
        vm.stopBroadcast();

        require(IERC721(address(u.positionManager)).ownerOf(tokenId) == address(lock), "position should be in the lock");
        require(u.positionManager.getPositionLiquidity(tokenId) == r.liquidity, "position liquidity");
        console.log("top-up position", tokenId, "locked until", lock.unlockAt(tokenId));
    }
}
