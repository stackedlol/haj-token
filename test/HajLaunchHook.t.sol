// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {HajLaunchHook} from "../src/HajLaunchHook.sol";

/// @notice The launch hook on its own, called the way the pool manager calls it. The fork tests run it inside the
///         real Uniswap v4 pool manager on Base and Base Sepolia.
contract HajLaunchHookTest is Test {
    address manager = makeAddr("poolManager");
    address founder = makeAddr("founder");
    address haj = makeAddr("haj");
    address stranger = makeAddr("stranger");
    HajLaunchHook hook;
    PoolKey k;

    uint160 constant FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG;

    function setUp() public {
        vm.warp(1_795_651_200); // Fri Nov 20, 2026
        hook = HajLaunchHook(at(FLAGS));
        deployCodeTo("HajLaunchHook.sol:HajLaunchHook", abi.encode(manager, founder, haj), address(hook));
        k = hook.poolKey(); // held here: calling poolKey() between a prank and its call would use up the prank
    }

    /// @dev An address whose low 14 bits are `flags`, the way Uniswap v4 reads a hook's permissions.
    function at(uint160 flags) internal pure returns (address) {
        return address((uint160(uint256(keccak256("haj launch hook"))) & ~Hooks.ALL_HOOK_MASK) | flags);
    }

    function addLiquidity(address origin) internal {
        ModifyLiquidityParams memory p;
        vm.prank(manager, origin);
        hook.beforeAddLiquidity(address(0xbeef), k, p, "");
    }

    function swapFee() internal returns (uint24 fee) {
        SwapParams memory p;
        vm.prank(manager);
        (,, fee) = hook.beforeSwap(stranger, k, p, "");
    }

    // ── The fee curve ──────────────────────────────────────────────────────────────────────────────────────────

    function test_feeCurve() public pure {
        // fee = 1% + 79% × ((90 − t) / 90)², in hundredths of a bip; 1% from 90 s on.
        assertEq(feeAt(0), 800_000); // 80%
        assertEq(feeAt(15), 558_611); // 55.86%
        assertEq(feeAt(30), 361_111); // 36.11%
        assertEq(feeAt(60), 97_777); // 9.78%
        assertEq(feeAt(90), 10_000); // 1%
        assertEq(feeAt(120), 10_000); // 1%
    }

    function feeAt(uint256 t) internal pure returns (uint24) {
        // The same formula written out, so the test doesn't just call the contract against itself.
        if (t >= 90) return 10_000;
        return uint24(10_000 + (790_000 * (90 - t) ** 2) / 8100);
    }

    function test_feeCurve_matchesContract_andSwapsPayIt() public {
        uint256[6] memory ts = [uint256(0), 15, 30, 60, 90, 120];
        for (uint256 i; i < ts.length; i++) {
            assertEq(hook.feeAt(ts[i]), feeAt(ts[i]));
        }

        addLiquidity(founder); // launch: the clock starts now
        uint256 launch = block.timestamp;
        for (uint256 i; i < ts.length; i++) {
            vm.warp(launch + ts[i]);
            uint24 fee = swapFee();
            assertEq(fee, feeAt(ts[i]) | LPFeeLibrary.OVERRIDE_FEE_FLAG, "swap overrides the LP fee with the curve");
            assertEq(hook.currentFee(), feeAt(ts[i]));
        }
        vm.warp(launch + 3650 days);
        assertEq(swapFee(), 10_000 | LPFeeLibrary.OVERRIDE_FEE_FLAG, "1% forever");
    }

    function testFuzz_feeOnlyFalls_andStaysBetween1And80Percent(uint256 a, uint256 b) public view {
        a = bound(a, 0, 10_000);
        b = bound(b, a, 10_000);
        assertGe(hook.feeAt(a), hook.feeAt(b));
        assertLe(hook.feeAt(a), 800_000);
        assertGe(hook.feeAt(b), 10_000);
    }

    // ── Opening the pool ───────────────────────────────────────────────────────────────────────────────────────

    function testFuzz_initialize_revertsForAnyoneButTheFounder(address sender, uint160 price) public {
        vm.assume(sender != founder);
        vm.prank(manager);
        vm.expectRevert(HajLaunchHook.NotFounder.selector);
        hook.beforeInitialize(sender, k, price);
    }

    function test_initialize_founderOpensOnlyThisPool() public {
        vm.prank(manager);
        assertEq(hook.beforeInitialize(founder, k, 1 << 96), IHooks.beforeInitialize.selector);

        PoolKey[4] memory wrong = [k, k, k, k];
        wrong[0].currency1 = Currency.wrap(makeAddr("another token"));
        wrong[1].fee = 10_000; // a static fee would ignore the curve
        wrong[2].tickSpacing = 60;
        wrong[3].currency0 = Currency.wrap(makeAddr("weth"));
        for (uint256 i; i < wrong.length; i++) {
            vm.prank(manager);
            vm.expectRevert(HajLaunchHook.WrongPool.selector);
            hook.beforeInitialize(founder, wrong[i], 1 << 96);
        }
    }

    function test_onlyThePoolManagerCallsIn() public {
        ModifyLiquidityParams memory lp;
        SwapParams memory sp;
        vm.startPrank(founder, founder);
        vm.expectRevert(HajLaunchHook.NotPoolManager.selector);
        hook.beforeInitialize(founder, k, 1 << 96);
        vm.expectRevert(HajLaunchHook.NotPoolManager.selector);
        hook.beforeAddLiquidity(founder, k, lp, "");
        vm.expectRevert(HajLaunchHook.NotPoolManager.selector);
        hook.beforeSwap(founder, k, sp, "");
        vm.stopPrank();
        assertEq(hook.startedAt(), 0);
    }

    // ── Before, during and after the 90 seconds ────────────────────────────────────────────────────────────────

    function test_nothingHappensBeforeTheFoundersLiquidity() public {
        SwapParams memory sp;
        vm.prank(manager);
        vm.expectRevert(HajLaunchHook.NotLive.selector);
        hook.beforeSwap(stranger, k, sp, "");

        ModifyLiquidityParams memory lp;
        vm.prank(manager, stranger);
        vm.expectRevert(HajLaunchHook.NotLive.selector);
        hook.beforeAddLiquidity(stranger, k, lp, "");
        assertEq(hook.startedAt(), 0);
        assertEq(hook.currentFee(), 800_000);
    }

    function test_clockStartsOnce_withTheFoundersLiquidity() public {
        addLiquidity(founder);
        assertEq(hook.startedAt(), block.timestamp);
        uint64 started = hook.startedAt();
        skip(30);
        addLiquidity(founder); // a second add doesn't restart the clock
        assertEq(hook.startedAt(), started);
    }

    function test_onlyTheFounderAddsLiquidityDuringTheWindow() public {
        addLiquidity(founder);
        uint256 launch = block.timestamp;

        ModifyLiquidityParams memory lp;
        vm.warp(launch + 89);
        vm.prank(manager, stranger);
        vm.expectRevert(HajLaunchHook.LaunchWindow.selector);
        hook.beforeAddLiquidity(stranger, k, lp, "");

        vm.warp(launch + 90);
        addLiquidity(stranger); // anyone, once the fee is down to 1%
    }

    // ── Nobody can change anything ─────────────────────────────────────────────────────────────────────────────

    function test_noOwnerNoAdminNoSetters() public {
        string[9] memory sigs = [
            "owner()",
            "transferOwnership(address)",
            "renounceOwnership()",
            "setFee(uint24)",
            "setStartFee(uint24)",
            "setEndFee(uint24)",
            "setDuration(uint256)",
            "pause()",
            "upgradeToAndCall(address,bytes)"
        ];
        for (uint256 i; i < sigs.length; i++) {
            vm.prank(founder);
            (bool ok,) = address(hook).call(abi.encodeWithSignature(sigs[i], founder));
            assertFalse(ok, sigs[i]);
        }
        assertEq(hook.START_FEE(), 800_000);
        assertEq(hook.END_FEE(), 10_000);
        assertEq(hook.DURATION(), 90);
    }

    function test_unusedCallsRevert() public {
        ModifyLiquidityParams memory lp;
        SwapParams memory sp;
        BalanceDelta zero;
        vm.startPrank(manager);
        vm.expectRevert(HajLaunchHook.HookNotImplemented.selector);
        hook.afterInitialize(founder, k, 1 << 96, 0);
        vm.expectRevert(HajLaunchHook.HookNotImplemented.selector);
        hook.beforeRemoveLiquidity(founder, k, lp, "");
        vm.expectRevert(HajLaunchHook.HookNotImplemented.selector);
        hook.afterAddLiquidity(founder, k, lp, zero, zero, "");
        vm.expectRevert(HajLaunchHook.HookNotImplemented.selector);
        hook.afterSwap(founder, k, sp, zero, "");
        vm.expectRevert(HajLaunchHook.HookNotImplemented.selector);
        hook.beforeDonate(founder, k, 1, 1, "");
        vm.stopPrank();
    }

    function test_hookAddressMustCarryExactlyItsFlags() public {
        uint160[3] memory bad = [FLAGS | Hooks.AFTER_SWAP_FLAG, FLAGS & ~Hooks.BEFORE_SWAP_FLAG, uint160(0)];
        for (uint256 i; i < bad.length; i++) {
            vm.expectRevert();
            this.deployAt(at(bad[i]));
        }
    }

    function deployAt(address where) external {
        deployCodeTo("HajLaunchHook.sol:HajLaunchHook", abi.encode(manager, founder, haj), where);
    }
}
