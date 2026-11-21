// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {PositionInfo, PositionInfoLibrary} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {HajLPLock} from "../src/HajLPLock.sol";
import {HajLaunchHook} from "../src/HajLaunchHook.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {Pool} from "../script/Pool.s.sol";
import {TopUp} from "../script/TopUp.s.sol";
import {Networks} from "../script/lib/Uniswap.sol";

interface IPermit2Holder {
    function permit2() external view returns (address);
}

interface IChainlinkFeed {
    function decimals() external view returns (uint8);
    function latestRoundData() external view returns (uint80, int256 answer, uint256, uint256 updatedAt, uint80);
}

/// @notice The launch, start to finish, on a copy of Base (and of Base Sepolia) with the real Uniswap v4 contracts:
///         deploy → nobody else can open the pool → pool + position into the lock in one go → a sniper's $100 at
///         second 0 against a person's $100 at second 120 → fees to the founder → nothing comes out of the lock
///         early → a top-up → a year passes → only then positions come back. Runs the same Deploy / Pool / TopUp
///         code the Ledger signs. Needs network access (public RPCs by default; BASE_RPC_URL / BASE_SEPOLIA_RPC_URL
///         override).
contract ForkTest is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using PositionInfoLibrary for PositionInfo;

    address founder;
    uint256 founderKey;
    address seasons = makeAddr("seasons");
    address sniper = makeAddr("sniper");
    address person = makeAddr("person");
    address stranger = makeAddr("stranger");

    uint256 constant POOL_ETH = 1 ether; // a rehearsal amount; the launch uses POOL_ETH from the environment

    // Chainlink ETH / USD, from Chainlink's feed directory (reference-data-directory.vercel.app, read 2026-11-20).
    IChainlinkFeed constant BASE_ETH_USD = IChainlinkFeed(0xa4250cE1aA15Ff4cb5E5a8655293b65694e436Ed);
    IChainlinkFeed constant BASE_SEPOLIA_ETH_USD = IChainlinkFeed(0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1);

    Deploy.Deployed d;
    Networks.Uniswap u;
    PoolKey key;
    PoolSwapTest swapper;

    function test_base_fullLaunch() public {
        vm.createSelectFork(vm.envOr("BASE_RPC_URL", string("https://mainnet.base.org")));
        fullLaunch(BASE_ETH_USD);
    }

    function test_baseSepolia_fullLaunch() public {
        vm.createSelectFork(vm.envOr("BASE_SEPOLIA_RPC_URL", string("https://sepolia.base.org")));
        fullLaunch(BASE_SEPOLIA_ETH_USD);
    }

    function fullLaunch(IChainlinkFeed ethUsd) internal {
        (founder, founderKey) = makeAddrAndKey("founder");
        vm.setEnv("WRITE_DEPLOYMENTS", "false");
        vm.deal(founder, 10 ether);
        u = Networks.uniswap(block.chainid);
        // The addresses in script/lib/Uniswap.sol belong together.
        assertEq(address(u.positionManager.poolManager()), address(u.poolManager), "position manager's pool manager");
        assertEq(IPermit2Holder(address(u.positionManager)).permit2(), address(u.permit2), "position manager's permit2");
        assertGt(address(u.permit2).code.length, 0, "permit2");

        // 1. Deploy. The hook lands at a mined address carrying exactly its three flags.
        d = new Deploy().deploy(founder, seasons);
        key = d.hook.poolKey();
        assertEq(
            uint160(address(d.hook)) & Hooks.ALL_HOOK_MASK,
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
        );

        // 2. Nobody but the founder can open the HAJ pool, at any price.
        initializeAs(stranger, 1 << 96);
        initializeAs(sniper, 79228162514264337593543950336000); // a thousand times the launch-ish price

        // 3. The launch: pool, full-range position minted into the lock, fee clock running, in one broadcast.
        uint256 position = new Pool().open(founder, d.hook, d.lock, address(d.seasonsVest), POOL_ETH);
        uint64 launchedAt = uint64(block.timestamp);
        assertEq(d.hook.startedAt(), launchedAt, "fee clock starts with the liquidity");
        assertEq(d.hook.currentFee(), 800_000);
        assertEq(d.token.balanceOf(founder), 0, "founder holds 0 HAJ");
        assertEq(IERC721(address(u.positionManager)).ownerOf(position), address(d.lock), "position in the lock");
        assertEq(d.lock.unlockAt(position), d.launch + 365 days);
        uint128 liquidity = u.positionManager.getPositionLiquidity(position);
        assertGt(liquidity, 0);
        // Everything is where the README says it is: 600,000 in the pool (less dust to seasons), the rest locked.
        assertApproxEqAbs(d.token.balanceOf(address(u.poolManager)), 600_000e18, 1e12);
        assertApproxEqAbs(d.token.balanceOf(address(d.seasonsVest)), 200_000e18, 1e12);
        assertEq(d.token.balanceOf(address(d.claim)), 100_000e18);
        assertEq(d.token.balanceOf(address(d.founderVest)), 100_000e18);
        assertEq(d.token.allowance(founder, address(u.permit2)), 0, "no allowance left behind");

        // 4. $100 of ETH at second 0 (a sniper in the launch block) against $100 at second 120 (a person).
        swapper = new PoolSwapTest(u.poolManager);
        uint256 hundred = dollars(ethUsd, 100);
        uint256 snapshot = vm.snapshotState();
        uint256 sniperGot = buy(sniper, hundred);
        // The sniper's 80% fee went to the locked position; collecting pays it to the founder.
        uint256 before = founder.balance;
        vm.prank(founder);
        (uint256 feeEth,) = d.lock.collect(position);
        assertEq(founder.balance - before, feeEth);
        assertApproxEqRel(feeEth, (hundred * 80) / 100, 0.01e18, "80% of the sniper's ETH, paid to the founder");
        assertEq(u.positionManager.getPositionLiquidity(position), liquidity, "collect never touches liquidity");

        vm.revertToState(snapshot);
        vm.warp(launchedAt + 120);
        assertEq(d.hook.currentFee(), 10_000);
        uint256 personGot = buy(person, hundred);
        console.log("$100 of ETH, wei:", hundred);
        console.log("HAJ for $100 at second 0:  ", sniperGot / 1e18);
        console.log("HAJ for $100 at second 120:", personGot / 1e18);
        console.log("second 0 gets this % of second 120:", (sniperGot * 100) / personGot);
        // 20% of the input vs 99%: about a fifth as much HAJ (a little more, as a smaller trade moves the price less).
        assertGt(sniperGot * 100, personGot * 19);
        assertLt(sniperGot * 100, personGot * 25);

        // 5. Nothing comes out of the lock early, whoever asks and however.
        noWayOut(position, liquidity);
        vm.prank(stranger);
        vm.expectRevert(HajLPLock.NotOwner.selector);
        d.lock.collect(position);

        // 6. A month in, a top-up: ETH only, priced below HAJ's price now, locked a year from now.
        skip(30 days);
        (uint256 top,) = new TopUp().add(founder, d.hook, d.lock, 0.01 ether, 5000, 9500);
        assertEq(IERC721(address(u.positionManager)).ownerOf(top), address(d.lock));
        assertEq(d.lock.unlockAt(top), block.timestamp + 365 days);
        assertGt(u.positionManager.getPositionLiquidity(top), 0);
        (, int24 tick,,) = u.poolManager.getSlot0(key.toId());
        PositionInfo info = u.positionManager.positionInfo(top);
        assertGt(info.tickLower(), tick, "ETH-only: wholly above the current tick (ETH is currency0)");
        assertLt(info.tickLower(), info.tickUpper());

        // 7. A year after launch the launch position is free; the top-up still has a month to go.
        vm.warp(d.launch + 365 days);
        vm.startPrank(founder);
        d.lock.withdraw(position, founder);
        assertEq(IERC721(address(u.positionManager)).ownerOf(position), founder);
        vm.expectRevert(abi.encodeWithSelector(HajLPLock.Locked.selector, d.lock.unlockAt(top)));
        d.lock.withdraw(top, founder);
        vm.stopPrank();
    }

    /// @dev The real pool manager wraps the hook's NotFounder in its own error; check the whole thing.
    function initializeAs(address who, uint160 price) internal {
        vm.prank(who);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(d.hook),
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(HajLaunchHook.NotFounder.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        u.poolManager.initialize(key, price);
    }

    function dollars(IChainlinkFeed feed, uint256 usd) internal view returns (uint256 wei_) {
        (, int256 answer,,,) = feed.latestRoundData();
        require(answer > 0, "feed");
        wei_ = (usd * 1e18 * 10 ** feed.decimals()) / uint256(answer);
    }

    function buy(address who, uint256 eth) internal returns (uint256 got) {
        vm.deal(who, eth);
        uint256 before = d.token.balanceOf(who);
        vm.prank(who);
        swapper.swap{value: eth}(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(eth), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        got = d.token.balanceOf(who) - before;
    }

    /// @notice Every way of pulling liquidity out of a locked position before its unlock time reverts: through the
    ///         lock (withdraw) and straight at the position manager (decrease, burn, transfer, approve, subscribe,
    ///         permit), for the founder and for anyone else.
    function noWayOut(uint256 position, uint128 liquidity) internal {
        address[2] memory who = [founder, stranger];
        for (uint256 i; i < who.length; i++) {
            vm.startPrank(who[i], who[i]);
            if (who[i] == founder) {
                vm.expectRevert(abi.encodeWithSelector(HajLPLock.Locked.selector, d.lock.unlockAt(position)));
            } else {
                vm.expectRevert(HajLPLock.NotOwner.selector);
            }
            d.lock.withdraw(position, who[i]);

            vm.expectRevert();
            u.positionManager.modifyLiquidities(decrease(position, liquidity, who[i]), block.timestamp);
            vm.expectRevert();
            u.positionManager.modifyLiquidities(burn(position, who[i]), block.timestamp);
            vm.expectRevert();
            IERC721(address(u.positionManager)).transferFrom(address(d.lock), who[i], position);
            vm.expectRevert();
            IERC721(address(u.positionManager)).safeTransferFrom(address(d.lock), who[i], position);
            vm.expectRevert();
            IERC721(address(u.positionManager)).approve(who[i], position);
            vm.expectRevert();
            u.positionManager.subscribe(position, who[i], "");
            vm.stopPrank();
        }
        // A permit signed by the founder's key is not the lock's signature (the lock can't sign anything).
        bytes32 digest = keccak256("not the lock");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(founderKey, digest);
        vm.prank(founder);
        vm.expectRevert();
        u.positionManager.permit(founder, position, block.timestamp + 1 hours, 0, abi.encodePacked(r, s, v));

        assertEq(IERC721(address(u.positionManager)).ownerOf(position), address(d.lock));
        assertEq(u.positionManager.getPositionLiquidity(position), liquidity);
        assertEq(address(u.positionManager.subscriber(position)), address(0));
    }

    function decrease(uint256 position, uint128 liquidity, address to) internal view returns (bytes memory) {
        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(position, uint256(liquidity), uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1, to);
        return abi.encode(actions, params);
    }

    function burn(uint256 position, address to) internal view returns (bytes memory) {
        bytes memory actions = abi.encodePacked(uint8(Actions.BURN_POSITION), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(position, uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1, to);
        return abi.encode(actions, params);
    }
}
