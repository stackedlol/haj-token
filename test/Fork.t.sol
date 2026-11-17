// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {HajLPLock} from "../src/HajLPLock.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {Pool} from "../script/Pool.s.sol";
import {TopUp} from "../script/TopUp.s.sol";
import {IPositionManager, IUniswapV3Factory, IUniswapV3Pool, Networks} from "../script/lib/Uniswap.sol";

interface ISwapRouter02 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

/// @notice The launch, start to finish, on a copy of Base (and of Base Sepolia) with the real Uniswap v3 contracts:
///         deploy → pool → people buy → fees collected → a top-up → a year passes → only then positions come back.
///         Runs the same Deploy / Pool / TopUp code the Ledger signs. Needs network access (public RPCs by default;
///         BASE_RPC_URL / BASE_SEPOLIA_RPC_URL override).
contract ForkTest is Test {
    address founder = makeAddr("founder");
    address seasons = makeAddr("seasons");
    address buyer = makeAddr("buyer");

    address constant BASE_FACTORY = 0x33128a8fC17869897dcE68Ed026d694621f6FDfD;
    address constant BASE_SEPOLIA_FACTORY = 0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    ISwapRouter02 constant BASE_ROUTER = ISwapRouter02(0x2626664c2603336E57B271c5C0b26F421741e481);

    function launch() internal returns (Deploy.Deployed memory d, uint256 position, IPositionManager pm) {
        vm.setEnv("WRITE_DEPLOYMENTS", "false");
        vm.deal(founder, 1 ether);
        d = new Deploy().deploy(founder, seasons);
        position = new Pool().open(founder, IERC20(address(d.token)), d.lock, address(d.seasonsVest), 0.03 ether);
        pm = Networks.positionManager(block.chainid);

        assertEq(d.token.balanceOf(founder), 0, "founder holds 0 HAJ");
        assertEq(pm.ownerOf(position), address(d.lock), "launch position in the lock");
        assertEq(d.lock.unlockAt(position), d.launch + 365 days);
        (,,,,,,, uint128 liquidity,,,,) = pm.positions(position);
        assertGt(liquidity, 0);
        // Everything is where the README says it is: 600,000 in the pool (less dust to seasons), the rest locked.
        address pool = IUniswapV3Factory(pm.factory()).getPool(address(d.token), WETH, Networks.FEE);
        assertApproxEqAbs(d.token.balanceOf(pool), 600_000e18, 1e12);
        assertApproxEqAbs(d.token.balanceOf(address(d.seasonsVest)), 200_000e18, 1e12);
        assertEq(d.token.balanceOf(address(d.claim)), 100_000e18);
        assertEq(d.token.balanceOf(address(d.founderVest)), 100_000e18);
    }

    function test_base_fullLaunch() public {
        vm.createSelectFork(vm.envOr("BASE_RPC_URL", string("https://mainnet.base.org")));
        (Deploy.Deployed memory d, uint256 position, IPositionManager pm) = launch();
        assertEq(pm.factory(), BASE_FACTORY, "Uniswap v3 factory on Base");
        assertEq(pm.WETH9(), WETH);

        // People buy HAJ with ETH, paying the 1% fee into the position.
        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        uint256 got = BASE_ROUTER.exactInputSingle{value: 0.01 ether}(
            ISwapRouter02.ExactInputSingleParams(WETH, address(d.token), Networks.FEE, buyer, 0.01 ether, 0, 0)
        );
        assertGt(got, 0);
        assertEq(d.token.balanceOf(buyer), got);

        // Fees go to the founder; the liquidity doesn't move.
        (,,,,,,, uint128 before,,,,) = pm.positions(position);
        vm.prank(founder);
        d.lock.collect(position);
        assertGt(IERC20(WETH).balanceOf(founder), 0, "fee in WETH");
        (,,,,,,, uint128 afterCollect,,,,) = pm.positions(position);
        assertEq(afterCollect, before, "collect never touches liquidity");
        vm.prank(buyer);
        vm.expectRevert(HajLPLock.NotOwner.selector);
        d.lock.collect(position);

        // A month in, a top-up: ETH only, below the price, locked a year from now.
        skip(30 days);
        vm.deal(founder, 1 ether);
        (uint256 top,) = new TopUp().add(founder, address(d.token), d.lock, 0.01 ether, 5000, 9500);
        assertEq(pm.ownerOf(top), address(d.lock));
        assertEq(d.lock.unlockAt(top), block.timestamp + 365 days);
        (,, address t0,,, int24 lo, int24 hi, uint128 topLiquidity,,,,) = pm.positions(top);
        assertGt(topLiquidity, 0);
        address pool = IUniswapV3Factory(pm.factory()).getPool(address(d.token), WETH, Networks.FEE);
        (, int24 tick,,,,,) = IUniswapV3Pool(pool).slot0();
        // ETH-only: entirely on WETH's side of the current price.
        if (t0 == WETH) assertGt(lo, tick);
        else assertLt(hi, tick);

        // Nothing comes back early.
        vm.startPrank(founder);
        vm.expectRevert(abi.encodeWithSelector(HajLPLock.Locked.selector, d.launch + 365 days));
        d.lock.withdraw(position, founder);

        // A year after launch the launch position is free; the top-up still has a month to go.
        vm.warp(d.launch + 365 days);
        d.lock.withdraw(position, founder);
        assertEq(pm.ownerOf(position), founder);
        vm.expectRevert(abi.encodeWithSelector(HajLPLock.Locked.selector, d.launch + 395 days));
        d.lock.withdraw(top, founder);
        vm.stopPrank();
    }

    function test_baseSepolia_launch() public {
        vm.createSelectFork(vm.envOr("BASE_SEPOLIA_RPC_URL", string("https://sepolia.base.org")));
        (,, IPositionManager pm) = launch();
        assertEq(pm.factory(), BASE_SEPOLIA_FACTORY, "Uniswap v3 factory on Base Sepolia");
        assertEq(pm.WETH9(), WETH);
    }
}
