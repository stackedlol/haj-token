// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

/// @notice Where Uniswap v4 lives on each network the scripts run on.
/// @dev    From Uniswap's deployments page (developers.uniswap.org/docs/protocols/v4/deployments, read 2026-11-20).
///         Checked on chain the same day: each PositionManager reports this PoolManager and this Permit2, and the
///         fork tests check it again on every run. Base mainnet addresses also checked on Basescan (verified source).
library Networks {
    int24 internal constant SPACING = 200; // the launch pool's tick spacing, as with v3's 1% tier
    int24 internal constant FULL_LOWER = -887_200; // the widest ticks on that spacing
    int24 internal constant FULL_UPPER = 887_200;

    struct Uniswap {
        IPoolManager poolManager;
        IPositionManager positionManager;
        IAllowanceTransfer permit2;
    }

    function uniswap(uint256 chainId) internal pure returns (Uniswap memory u) {
        u.permit2 = IAllowanceTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3); // same on every chain
        if (chainId == 8453) {
            // Base
            u.poolManager = IPoolManager(0x498581fF718922c3f8e6A244956aF099B2652b2b);
            u.positionManager = IPositionManager(0x7C5f5A4bBd8fD63184577525326123B519429bDc);
        } else if (chainId == 84532) {
            // Base Sepolia
            u.poolManager = IPoolManager(0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408);
            u.positionManager = IPositionManager(0x4B2C77d209D3405F41a037Ec6c77F7F5b8e2ca80);
        } else {
            revert("no Uniswap v4 on this chain");
        }
    }

    function name(uint256 chainId) internal pure returns (string memory) {
        if (chainId == 8453) return "base";
        if (chainId == 84532) return "base-sepolia";
        return "local";
    }
}

library PriceMath {
    /// @notice The pool's starting price for `amount1` of currency1 against `amount0` of currency0, as Uniswap
    ///         stores it.
    function sqrtPriceX96(uint256 amount0, uint256 amount1) internal pure returns (uint160) {
        return uint160(Math.sqrt(Math.mulDiv(amount1, 1 << 192, amount0)));
    }

    /// @notice 1.0001^n in 18-decimal fixed point (n ≤ ~200,000).
    function pow10001(uint256 n) internal pure returns (uint256 r) {
        uint256 base = 1.0001e18;
        r = 1e18;
        while (n > 0) {
            if (n & 1 == 1) r = (r * base) / 1e18;
            base = (base * base) / 1e18;
            n >>= 1;
        }
    }

    /// @notice How many ticks a price moves for a factor of 10,000 / bps (bps < 10,000): the smallest n with
    ///         1.0001^n ≥ 10,000 / bps. A 5% drop (9,500) is 513 ticks, a halving (5,000) is 6,932.
    function ticksFor(uint256 bps) internal pure returns (uint256 lo) {
        require(bps > 0 && bps < 10_000, "bps out of range");
        uint256 target = (10_000e18) / bps;
        uint256 hi = 200_000;
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            if (pow10001(mid) >= target) hi = mid;
            else lo = mid + 1;
        }
    }

    function floorTo(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 q = tick / spacing;
        if (tick < 0 && tick % spacing != 0) q -= 1;
        return q * spacing;
    }

    function ceilTo(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 f = floorTo(tick, spacing);
        return f == tick ? tick : f + spacing;
    }
}
