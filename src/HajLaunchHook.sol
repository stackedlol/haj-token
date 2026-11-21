// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @title Launch hook for the HAJ/ETH pool on Uniswap v4
/// @notice Sniper protection. The pool's LP fee starts at 80% the moment the founder's liquidity lands and falls
///         along a quadratic curve to 1% over 90 seconds, then stays at 1% forever:
///
///             fee(t) = 1% + (80% − 1%) × ((90 − t) / 90)²      for 0 ≤ t < 90 s,   1% after
///
///         A bot that buys in the launch block pays 80% of what it puts in; a person who buys two minutes later
///         pays 1%. The fee is an LP fee, so everything paid goes to the pool's liquidity: the locked launch position.
///
///         This contract has no owner, no admin function and no setter. Every number is a constant or an immutable
///         set at deploy. The one piece of state, `startedAt`, is written once by the launch and never again.
///
///         It serves exactly one pool: native ETH / HAJ, dynamic fee, tick spacing 200, this hook. Only the founder
///         can open it, so nobody can open the HAJ pool first at another price. Before the founder's liquidity
///         lands, nobody can add liquidity or swap; during the 90 seconds only the founder can add liquidity, so
///         the high fees go to the locked position and to no one else.
contract HajLaunchHook is IHooks {
    uint24 public constant START_FEE = 800_000; // 80%, in Uniswap's hundredths of a bip (1_000_000 = 100%)
    uint24 public constant END_FEE = 10_000; // 1%
    uint256 public constant DURATION = 90; // seconds
    int24 public constant TICK_SPACING = 200;

    IPoolManager public immutable poolManager;
    address public immutable founder;
    address public immutable haj;

    /// @notice When the founder's liquidity landed and the fee clock started. 0 until the launch.
    uint64 public startedAt;

    event Live(uint64 startedAt);

    error NotPoolManager();
    error NotFounder();
    error WrongPool();
    error NotLive();
    error LaunchWindow();
    error HookNotImplemented();

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    constructor(IPoolManager poolManager_, address founder_, address haj_) {
        poolManager = poolManager_;
        founder = founder_;
        haj = haj_;
        // The pool manager reads a hook's permissions from its address; this one must be mined to match exactly.
        Hooks.validateHookPermissions(
            this,
            Hooks.Permissions({
                beforeInitialize: true,
                afterInitialize: false,
                beforeAddLiquidity: true,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: true,
                afterSwap: false,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            })
        );
    }

    /// @notice The one pool this hook serves.
    function poolKey() public view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)), // native ETH always sorts first
            currency1: Currency.wrap(haj),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: this
        });
    }

    /// @notice The LP fee `elapsed` seconds after launch.
    function feeAt(uint256 elapsed) public pure returns (uint24) {
        if (elapsed >= DURATION) return END_FEE;
        uint256 remaining = DURATION - elapsed;
        return uint24(END_FEE + (uint256(START_FEE - END_FEE) * remaining * remaining) / (DURATION * DURATION));
    }

    /// @notice The fee a swap would pay right now (80% before launch, though no swap can happen then).
    function currentFee() external view returns (uint24) {
        return startedAt == 0 ? START_FEE : feeAt(block.timestamp - startedAt);
    }

    // ── Hook calls ─────────────────────────────────────────────────────────────────────────────────────────────

    /// @dev `sender` is whoever called PoolManager.initialize: it must be the founder's own address.
    function beforeInitialize(address sender, PoolKey calldata key, uint160)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        if (sender != founder) revert NotFounder();
        if (!_isOurPool(key)) revert WrongPool();
        return IHooks.beforeInitialize.selector;
    }

    /// @dev Liquidity arrives through the position manager, so `sender` is that contract, not a person; the
    ///      transaction's signer (tx.origin) is what tells the founder's launch apart. The first liquidity the
    ///      founder adds starts the fee clock; nobody else can add any until the 90 seconds are over.
    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4)
    {
        uint64 started = startedAt;
        if (started == 0) {
            if (tx.origin != founder) revert NotLive();
            startedAt = uint64(block.timestamp);
            emit Live(uint64(block.timestamp));
        } else if (block.timestamp < started + DURATION && tx.origin != founder) {
            revert LaunchWindow();
        }
        return IHooks.beforeAddLiquidity.selector;
    }

    /// @dev Overrides the pool's LP fee for this swap with the curve's value now.
    function beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        uint64 started = startedAt;
        if (started == 0) revert NotLive();
        uint24 fee = feeAt(block.timestamp - started);
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    function _isOurPool(PoolKey calldata key) private view returns (bool) {
        return Currency.unwrap(key.currency0) == address(0) && Currency.unwrap(key.currency1) == haj
            && key.fee == LPFeeLibrary.DYNAMIC_FEE_FLAG && key.tickSpacing == TICK_SPACING
            && address(key.hooks) == address(this);
    }

    // ── Calls this hook never takes (its address doesn't carry their flags; the pool manager won't make them) ──

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        external
        pure
        returns (bytes4, int128)
    {
        revert HookNotImplemented();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }
}
