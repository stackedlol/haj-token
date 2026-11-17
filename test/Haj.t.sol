// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {VestingWallet} from "@openzeppelin/contracts/finance/VestingWallet.sol";
import {Hashes} from "@openzeppelin/contracts/utils/cryptography/Hashes.sol";
import {HajToken} from "../src/HajToken.sol";
import {HajClaim} from "../src/HajClaim.sol";
import {HajLPLock, INonfungiblePositionManager} from "../src/HajLPLock.sol";

/// @dev Stands in for Uniswap's position manager in the unit tests (the fork test uses the real one). collect()
///      records who it paid, so the tests can check fees only ever go to the lock's owner.
contract MockPositions is ERC721 {
    address public lastRecipient;
    uint256 public collects;

    constructor() ERC721("pos", "POS") {}

    function mint(address to, uint256 id) external {
        _mint(to, id);
    }

    function collect(INonfungiblePositionManager.CollectParams calldata p) external payable returns (uint256, uint256) {
        require(ownerOf(p.tokenId) == msg.sender, "not owner");
        lastRecipient = p.recipient;
        collects++;
        return (1, 2);
    }
}

contract HajTest is Test {
    address founder = makeAddr("founder");
    address seasonsWallet = makeAddr("seasons");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address dave = makeAddr("dave");

    HajToken token;
    VestingWallet founderVest;
    VestingWallet seasonsVest;
    HajClaim claim;
    HajLPLock lock;
    MockPositions pm;
    uint64 launch;

    // Season 1 list: four wallets, 100,000 HAJ between them.
    uint256 constant A = 50e18;
    uint256 constant B = 1_000e18;
    uint256 constant C = 49_000e18;
    uint256 constant D = 49_950e18;
    bytes32[4] leaves;
    bytes32 root;

    function setUp() public {
        vm.warp(1_795_651_200); // Fri Nov 20, 2026
        launch = uint64(block.timestamp);
        pm = new MockPositions();
        vm.startPrank(founder);
        token = new HajToken();
        founderVest = new VestingWallet(founder, launch + 365 days, 365 days);
        seasonsVest = new VestingWallet(seasonsWallet, launch + 365 days, 0);
        claim = new HajClaim(token, founder, address(seasonsVest));
        lock = new HajLPLock(INonfungiblePositionManager(address(pm)), founder);
        token.transfer(address(claim), 100_000e18);
        token.transfer(address(seasonsVest), 200_000e18);
        token.transfer(address(founderVest), 100_000e18);
        vm.stopPrank();

        leaves[0] = leaf(alice, A);
        leaves[1] = leaf(bob, B);
        leaves[2] = leaf(carol, C);
        leaves[3] = leaf(dave, D);
        root = Hashes.commutativeKeccak256(
            Hashes.commutativeKeccak256(leaves[0], leaves[1]), Hashes.commutativeKeccak256(leaves[2], leaves[3])
        );
    }

    function leaf(address account, uint256 amount) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(account, amount))));
    }

    function proof(uint256 i) internal view returns (bytes32[] memory p) {
        p = new bytes32[](2);
        p[0] = leaves[i ^ 1];
        p[1] = i < 2
            ? Hashes.commutativeKeccak256(leaves[2], leaves[3])
            : Hashes.commutativeKeccak256(leaves[0], leaves[1]);
    }

    function open() internal {
        vm.prank(founder);
        claim.setRoot(root);
    }

    // ── Token ──────────────────────────────────────────────────────────────────────────────────────────────────

    function test_supplyIsFixedAndDistributed() public view {
        assertEq(token.totalSupply(), 1_000_000e18);
        assertEq(token.balanceOf(founder), 600_000e18); // the pool's share, for script/Pool.s.sol
        assertEq(token.balanceOf(address(claim)), 100_000e18);
        assertEq(token.balanceOf(address(seasonsVest)), 200_000e18);
        assertEq(token.balanceOf(address(founderVest)), 100_000e18);
        assertEq(token.name(), "haj");
        assertEq(token.symbol(), "HAJ");
    }

    function test_noMintNoOwnerNoPause() public {
        string[6] memory sigs = [
            "mint(address,uint256)",
            "owner()",
            "pause()",
            "burn(uint256)",
            "transferOwnership(address)",
            "upgradeToAndCall(address,bytes)"
        ];
        for (uint256 i; i < sigs.length; i++) {
            (bool ok,) = address(token).call(abi.encodeWithSignature(sigs[i], founder, 1));
            assertFalse(ok, sigs[i]);
        }
        assertEq(token.totalSupply(), 1_000_000e18);
    }

    function testFuzz_transfersNeverChangeSupply(address to, uint256 amount) public {
        vm.assume(to != address(0));
        amount = bound(amount, 0, 600_000e18);
        vm.prank(founder);
        token.transfer(to, amount);
        assertEq(token.totalSupply(), 1_000_000e18);
    }

    // ── Claims ─────────────────────────────────────────────────────────────────────────────────────────────────

    function test_noClaimsBeforeRoot() public {
        vm.expectRevert(HajClaim.NotOpen.selector);
        claim.claim(alice, A, proof(0));
    }

    function test_onlyRootSetter_once_nonEmpty() public {
        vm.prank(alice);
        vm.expectRevert(HajClaim.NotRootSetter.selector);
        claim.setRoot(root);

        vm.prank(founder);
        vm.expectRevert(HajClaim.EmptyRoot.selector);
        claim.setRoot(bytes32(0));

        open();
        assertEq(claim.root(), root);
        assertEq(claim.opensAt(), block.timestamp);

        vm.prank(founder);
        vm.expectRevert(HajClaim.RootAlreadySet.selector);
        claim.setRoot(keccak256("another list"));
    }

    function test_badProofsFail() public {
        open();
        vm.expectRevert(HajClaim.BadProof.selector);
        claim.claim(alice, A + 1, proof(0)); // wrong amount
        vm.expectRevert(HajClaim.BadProof.selector);
        claim.claim(alice, A, proof(1)); // someone else's proof
        vm.expectRevert(HajClaim.BadProof.selector);
        claim.claim(makeAddr("eve"), A, proof(0)); // not on the list
    }

    function test_unlocksEvenlyOver90Days() public {
        open();
        assertEq(claim.claim(bob, B, proof(1)), 0); // registered at t=0: nothing unlocked yet
        assertEq(claim.allocation(bob), B);

        skip(45 days);
        assertEq(claim.claim(bob, 0, new bytes32[](0)), B / 2); // amount and proof ignored once registered
        assertEq(token.balanceOf(bob), B / 2);

        skip(45 days);
        claim.claim(bob, 0, new bytes32[](0));
        assertEq(token.balanceOf(bob), B);

        skip(400 days);
        assertEq(claim.claim(bob, 0, new bytes32[](0)), 0); // never more than the allocation
        assertEq(token.balanceOf(bob), B);
    }

    function testFuzz_unlockMath(uint256 t) public {
        t = bound(t, 0, 180 days - 1); // registering closes at 180 days
        open();
        skip(t);
        claim.claim(carol, C, proof(2));
        uint256 expected = t >= 90 days ? C : (C * t) / 90 days;
        assertEq(token.balanceOf(carol), expected);
        assertEq(claim.outstanding(), C - expected);
    }

    function test_claimOncePerAddress_noDoublePay() public {
        open();
        skip(90 days);
        claim.claim(alice, A, proof(0));
        claim.claim(alice, A, proof(0));
        claim.claim(alice, A, proof(0));
        assertEq(token.balanceOf(alice), A);
    }

    function test_sweepOnlyAfter180Days_onlyToSeasons_keepsWhatIsOwed() public {
        open();
        claim.claim(alice, A, proof(0)); // registered, nothing collected yet
        skip(30 days);
        claim.claim(bob, B, proof(1)); // registered, a third collected

        vm.expectRevert(HajClaim.NotYet.selector);
        claim.sweep();

        skip(150 days); // 180 days after claims opened
        vm.expectRevert(HajClaim.WindowClosed.selector);
        claim.claim(carol, C, proof(2)); // too late to register

        uint256 owed = claim.outstanding();
        assertEq(owed, A + B - (B * 30 days) / 90 days);
        uint256 seasonsBefore = token.balanceOf(address(seasonsVest));
        vm.prank(makeAddr("anyone"));
        uint256 swept = claim.sweep();
        assertEq(swept, C + D); // carol and dave never registered
        assertEq(token.balanceOf(address(seasonsVest)), seasonsBefore + C + D);
        assertEq(token.balanceOf(founder), 600_000e18); // founder got nothing

        // Registered wallets still collect after the sweep.
        claim.claim(alice, 0, new bytes32[](0));
        claim.claim(bob, 0, new bytes32[](0));
        assertEq(token.balanceOf(alice), A);
        assertEq(token.balanceOf(bob), B);
        assertEq(token.balanceOf(address(claim)), 0);

        vm.expectRevert(HajClaim.NothingToSweep.selector);
        claim.sweep();
    }

    function test_noRootForAYear_everythingGoesToSeasons() public {
        skip(364 days);
        vm.expectRevert(HajClaim.NotYet.selector);
        claim.sweep();
        skip(1 days);
        vm.prank(founder);
        vm.expectRevert(HajClaim.TooLate.selector);
        claim.setRoot(root);
        claim.sweep();
        assertEq(token.balanceOf(address(seasonsVest)), 300_000e18);
    }

    // ── Vesting ────────────────────────────────────────────────────────────────────────────────────────────────

    function test_founderGetsNothingBeforeMonth12_thenLinear() public {
        address t = address(token);
        skip(365 days - 1);
        assertEq(founderVest.releasable(t), 0);
        founderVest.release(t);
        assertEq(token.balanceOf(founder), 600_000e18);

        skip(1 + 365 days / 2);
        assertApproxEqAbs(founderVest.releasable(t), 50_000e18, 1e18);
        skip(365 days);
        founderVest.release(t);
        assertEq(token.balanceOf(founder), 700_000e18);
    }

    function test_seasonsLockedForAYear_thenAll() public {
        address t = address(token);
        skip(365 days - 1);
        assertEq(seasonsVest.releasable(t), 0);
        skip(1);
        seasonsVest.release(t);
        assertEq(token.balanceOf(seasonsWallet), 200_000e18);
    }

    // ── Liquidity lock ─────────────────────────────────────────────────────────────────────────────────────────

    function test_lpLock_manyPositions_eachWithItsOwnUnlock() public {
        pm.mint(founder, 1);
        pm.mint(founder, 2);
        pm.mint(founder, 3);
        vm.startPrank(founder);
        pm.safeTransferFrom(founder, address(lock), 1); // launch position
        skip(30 days);
        pm.safeTransferFrom(founder, address(lock), 2); // a top-up a month later
        skip(400 days);
        pm.safeTransferFrom(founder, address(lock), 3); // a top-up after the launch unlock
        vm.stopPrank();

        assertEq(lock.unlockAt(1), launch + 365 days);
        assertEq(lock.unlockAt(2), launch + 30 days + 365 days);
        assertEq(lock.unlockAt(3), launch + 430 days + 365 days);
        assertEq(lock.count(), 3);

        // Fees, on every position, to the owner only.
        for (uint256 id = 1; id <= 3; id++) {
            vm.prank(founder);
            lock.collect(id);
            assertEq(pm.lastRecipient(), founder);
        }
        vm.prank(alice);
        vm.expectRevert(HajLPLock.NotOwner.selector);
        lock.collect(1);

        // Now = launch + 430 days: 1 and 2 are open, 3 is not.
        vm.startPrank(founder);
        lock.withdraw(1, founder);
        lock.withdraw(2, founder);
        vm.expectRevert(abi.encodeWithSelector(HajLPLock.Locked.selector, launch + 795 days));
        lock.withdraw(3, founder);
        vm.stopPrank();
        assertEq(pm.ownerOf(1), founder);
        assertEq(pm.ownerOf(3), address(lock));
    }

    function test_lpLock_noWithdrawBeforeUnlock_evenForOwner() public {
        pm.mint(founder, 7);
        vm.prank(founder);
        pm.safeTransferFrom(founder, address(lock), 7);
        skip(365 days - 1);
        vm.prank(founder);
        vm.expectRevert(abi.encodeWithSelector(HajLPLock.Locked.selector, launch + 365 days));
        lock.withdraw(7, founder);
        vm.prank(alice);
        vm.expectRevert(HajLPLock.NotOwner.selector);
        lock.withdraw(7, alice);
    }

    function test_lpLock_plainTransferCanBeRegistered_notTwice() public {
        pm.mint(founder, 9);
        vm.prank(founder);
        pm.transferFrom(founder, address(lock), 9); // no callback
        assertEq(lock.unlockAt(9), 0);
        lock.register(9);
        assertEq(lock.unlockAt(9), launch + 365 days);
        vm.expectRevert(HajLPLock.AlreadyLocked.selector);
        lock.register(9);
    }

    function test_lpLock_onlyAcceptsPositions() public {
        vm.expectRevert(HajLPLock.NotPositionManager.selector);
        lock.onERC721Received(alice, alice, 1, "");
    }
}
