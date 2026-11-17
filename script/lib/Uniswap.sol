// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {INonfungiblePositionManager as ILockPositions} from "../../src/HajLPLock.sol";

/// @notice The Uniswap v3 calls the launch and top-up scripts make (periphery v1.0, as deployed on Base).
interface IPositionManager is ILockPositions {
    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    function factory() external view returns (address);
    function WETH9() external view returns (address);
    function createAndInitializePoolIfNecessary(address token0, address token1, uint24 fee, uint160 sqrtPriceX96)
        external
        payable
        returns (address pool);
    function mint(MintParams calldata params)
        external
        payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
    function refundETH() external payable;
    function multicall(bytes[] calldata data) external payable returns (bytes[] memory results);
    function positions(uint256 tokenId)
        external
        view
        returns (
            uint96 nonce,
            address operator,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        );
}

interface IUniswapV3Factory {
    function getPool(address a, address b, uint24 fee) external view returns (address);
}

interface IUniswapV3Pool {
    function slot0() external view returns (uint160 sqrtPriceX96, int24 tick, uint16, uint16, uint16, uint8, bool);
}

/// @notice Where Uniswap v3 lives on each network the scripts run on.
library Networks {
    uint24 internal constant FEE = 10_000; // the 1% tier
    int24 internal constant SPACING = 200; // its tick spacing
    int24 internal constant FULL_LOWER = -887_200; // the widest ticks on that spacing
    int24 internal constant FULL_UPPER = 887_200;

    function positionManager(uint256 chainId) internal pure returns (IPositionManager) {
        if (chainId == 8453) return IPositionManager(0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1); // Base
        if (chainId == 84532) return IPositionManager(0x27F971cb582BF9E50F397e4d29a5C7A34f11faA2); // Base Sepolia
        revert("no Uniswap v3 on this chain");
    }

    function name(uint256 chainId) internal pure returns (string memory) {
        if (chainId == 8453) return "base";
        if (chainId == 84532) return "base-sepolia";
        return "local";
    }
}

library PriceMath {
    /// @notice The pool's starting price for `amount1` of token1 against `amount0` of token0, as Uniswap stores it.
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
