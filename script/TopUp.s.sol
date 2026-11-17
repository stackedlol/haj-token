// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {HajLPLock} from "../src/HajLPLock.sol";
import {IPositionManager, IUniswapV3Factory, IUniswapV3Pool, Networks, PriceMath} from "./lib/Uniswap.sol";

/// @notice Adds deeper liquidity: an ETH-only position between LOW_BPS and HIGH_BPS of HAJ's current price (e.g.
///         5000 and 9500 = from half the price up to 95% of it). It holds only ETH, so it needs no HAJ, and it goes
///         straight into the lock with its own 365-day unlock. Writes deployments/topups/<network>-<tokenId>.json.
///
///   FOUNDER=0x… TOPUP_ETH=<wei> LOW_BPS=5000 HIGH_BPS=9500 \
///   forge script script/TopUp.s.sol --rpc-url base --ledger --sender $FOUNDER --broadcast
contract TopUp is Script {
    struct Range {
        int24 lower;
        int24 upper;
        int24 tickNow;
        address t0;
        address t1;
        uint256 a0;
        uint256 a1;
    }

    function run() external returns (uint256 tokenId) {
        string memory json = vm.readFile(string.concat("deployments/", Networks.name(block.chainid), ".json"));
        address haj = vm.parseJsonAddress(json, ".token");
        HajLPLock lock = HajLPLock(vm.parseJsonAddress(json, ".lpLock"));
        uint256 eth = vm.envUint("TOPUP_ETH");
        Range memory r;
        (tokenId, r) = add(vm.envAddress("FOUNDER"), haj, lock, eth, vm.envUint("LOW_BPS"), vm.envUint("HIGH_BPS"));
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

    function _params(Range memory r, address founder) internal view returns (IPositionManager.MintParams memory) {
        // ETH-only: the WETH side must land at least 99%, the HAJ side is zero.
        return IPositionManager.MintParams({
            token0: r.t0,
            token1: r.t1,
            fee: Networks.FEE,
            tickLower: r.lower,
            tickUpper: r.upper,
            amount0Desired: r.a0,
            amount1Desired: r.a1,
            amount0Min: (r.a0 * 99) / 100,
            amount1Min: (r.a1 * 99) / 100,
            recipient: founder,
            deadline: block.timestamp + 20 minutes
        });
    }

    function _mint(IPositionManager pm, IPositionManager.MintParams memory p, uint256 eth)
        internal
        returns (uint256 tokenId)
    {
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(IPositionManager.mint, (p));
        calls[1] = abi.encodeCall(IPositionManager.refundETH, ());
        bytes[] memory out = pm.multicall{value: eth}(calls);
        (tokenId,,,) = abi.decode(out[0], (uint256, uint128, uint256, uint256));
    }

    /// @notice The ETH-only range for HAJ prices between lowBps and highBps of now, on the pool's tick spacing.
    function _range(IPositionManager pm, address haj, uint256 eth, uint256 lowBps, uint256 highBps)
        internal
        view
        returns (Range memory r)
    {
        address weth = pm.WETH9();
        address pool = IUniswapV3Factory(pm.factory()).getPool(haj, weth, Networks.FEE);
        require(pool != address(0), "no pool yet");
        (, r.tickNow,,,,,) = IUniswapV3Pool(pool).slot0();

        // HAJ's price in ETH falls as the tick falls when HAJ is token0, and rises with it when HAJ is token1.
        int24 near = int24(int256(PriceMath.ticksFor(highBps)));
        int24 far = int24(int256(PriceMath.ticksFor(lowBps)));
        if (haj < weth) {
            // Below the current tick the position is all token1 = WETH.
            r.upper = PriceMath.floorTo(r.tickNow - near, Networks.SPACING);
            r.lower = PriceMath.floorTo(r.tickNow - far, Networks.SPACING);
            (r.t0, r.t1, r.a0, r.a1) = (haj, weth, 0, eth);
        } else {
            // Above the current tick the position is all token0 = WETH.
            r.lower = PriceMath.ceilTo(r.tickNow + near + 1, Networks.SPACING);
            r.upper = PriceMath.ceilTo(r.tickNow + far + 1, Networks.SPACING);
            (r.t0, r.t1, r.a0, r.a1) = (weth, haj, eth, 0);
        }
        require(r.lower < r.upper, "range too narrow for the 200-tick spacing");
    }

    function add(address founder, address haj, HajLPLock lock, uint256 eth, uint256 lowBps, uint256 highBps)
        public
        returns (uint256 tokenId, Range memory r)
    {
        require(eth > 0, "TOPUP_ETH");
        require(lowBps < highBps && highBps < 10_000, "need LOW_BPS < HIGH_BPS < 10000");
        IPositionManager pm = Networks.positionManager(block.chainid);
        r = _range(pm, haj, eth, lowBps, highBps);

        vm.startBroadcast(founder);
        tokenId = _mint(pm, _params(r, founder), eth);
        pm.safeTransferFrom(founder, address(lock), tokenId);
        vm.stopBroadcast();

        require(pm.ownerOf(tokenId) == address(lock), "position should be in the lock");
        console.log("top-up position", tokenId, "locked until", lock.unlockAt(tokenId));
    }
}
