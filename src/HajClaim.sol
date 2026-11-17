// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

/// @title Season 1 claims
/// @notice Holds the 100,000 HAJ for Season 1 from launch day. The reward list is a Merkle root of (address, amount)
///         leaves, set exactly once, by `rootSetter`, when Season 1 ends; that is the only privileged action here.
///         - No claims before the root is set.
///         - A wallet registers its amount with a proof, then its HAJ unlocks evenly over 90 days from the moment
///           claims open; it can collect what has unlocked at any time, as often as it likes.
///         - Wallets that haven't registered within 180 days of claims opening lose their share; anyone can then
///           sweep it to the seasons lock (the seasons VestingWallet), never anywhere else. HAJ already owed to
///           registered wallets stays here for them.
///         - If no root is ever set within a year of deployment, the whole balance can be swept to the seasons lock.
contract HajClaim {
    using SafeERC20 for IERC20;

    uint256 public constant UNLOCK = 90 days;
    uint256 public constant WINDOW = 180 days;
    uint256 public constant ROOT_DEADLINE = 365 days;

    IERC20 public immutable token;
    /// @notice The one address that may set the root, once.
    address public immutable rootSetter;
    /// @notice Where unclaimed HAJ goes: the later-seasons lock.
    address public immutable seasons;
    uint64 public immutable deployedAt;

    bytes32 public root;
    uint64 public opensAt;

    mapping(address account => uint256) public allocation;
    mapping(address account => uint256) public released;
    /// @notice Registered but not yet collected, across all wallets: never swept.
    uint256 public outstanding;

    event RootSet(bytes32 root, uint64 opensAt);
    event Registered(address indexed account, uint256 amount);
    event Released(address indexed account, uint256 amount);
    event Swept(address indexed to, uint256 amount);

    error NotRootSetter();
    error RootAlreadySet();
    error EmptyRoot();
    error TooLate();
    error NotOpen();
    error WindowClosed();
    error BadProof();
    error NothingToSweep();
    error NotYet();
    error ZeroAddress();

    constructor(IERC20 token_, address rootSetter_, address seasons_) {
        if (address(token_) == address(0) || rootSetter_ == address(0) || seasons_ == address(0)) revert ZeroAddress();
        token = token_;
        rootSetter = rootSetter_;
        seasons = seasons_;
        deployedAt = uint64(block.timestamp);
    }

    /// @notice Sets the Season 1 reward list and opens claims. Once only.
    function setRoot(bytes32 root_) external {
        if (msg.sender != rootSetter) revert NotRootSetter();
        if (root != bytes32(0)) revert RootAlreadySet();
        if (root_ == bytes32(0)) revert EmptyRoot();
        if (block.timestamp >= deployedAt + ROOT_DEADLINE) revert TooLate();
        root = root_;
        opensAt = uint64(block.timestamp);
        emit RootSet(root_, opensAt);
    }

    /// @notice Registers `account`'s amount (first call, with its proof) and sends it whatever has unlocked so far.
    ///         Anyone may call it for any account; the HAJ only ever goes to `account`. After registering, `amount`
    ///         and `proof` are ignored.
    function claim(address account, uint256 amount, bytes32[] calldata proof) external returns (uint256 sent) {
        if (root == bytes32(0)) revert NotOpen();
        if (allocation[account] == 0) {
            if (block.timestamp >= opensAt + WINDOW) revert WindowClosed();
            bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(account, amount))));
            if (amount == 0 || !MerkleProof.verifyCalldata(proof, root, leaf)) revert BadProof();
            allocation[account] = amount;
            outstanding += amount;
            emit Registered(account, amount);
        }
        sent = releasable(account);
        if (sent > 0) {
            released[account] += sent;
            outstanding -= sent;
            emit Released(account, sent);
            token.safeTransfer(account, sent);
        }
    }

    /// @notice How much of `account`'s registered amount has unlocked: evenly over UNLOCK from opensAt.
    function vested(address account) public view returns (uint256) {
        uint256 total = allocation[account];
        if (total == 0 || opensAt == 0) return 0;
        uint256 elapsed = block.timestamp - opensAt;
        return elapsed >= UNLOCK ? total : (total * elapsed) / UNLOCK;
    }

    function releasable(address account) public view returns (uint256) {
        return vested(account) - released[account];
    }

    /// @notice After the claim window (or a year without a root), sends everything nobody registered for to the
    ///         seasons lock. Callable by anyone, as many times as there is something to send.
    function sweep() external returns (uint256 amount) {
        bool closed =
            root != bytes32(0) ? block.timestamp >= opensAt + WINDOW : block.timestamp >= deployedAt + ROOT_DEADLINE;
        if (!closed) revert NotYet();
        amount = token.balanceOf(address(this)) - outstanding;
        if (amount == 0) revert NothingToSweep();
        emit Swept(seasons, amount);
        token.safeTransfer(seasons, amount);
    }
}
