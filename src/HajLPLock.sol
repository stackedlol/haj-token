// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @title Liquidity lock
/// @notice Holds Uniswap v4 position NFTs: the launch position and every later top-up. Each one gets its own unlock
///         time, 365 days after it arrives and never before the launch position's. Until then the owner can only
///         collect trading fees, paid to the owner. This contract makes exactly one kind of call to the position
///         manager: decrease liquidity by zero (which settles the fees) and take both currencies to the owner. It
///         never removes liquidity, never approves anyone, never sets a subscriber, and only hands a position back
///         after its unlock time.
contract HajLPLock is IERC721Receiver {
    uint256 public constant LOCK = 365 days;

    IPositionManager public immutable positions;
    address public immutable owner;
    /// @notice No position unlocks before this: 365 days after this lock was deployed (launch day).
    uint64 public immutable launchUnlock;

    mapping(uint256 tokenId => uint64) public unlockAt;
    uint256[] public tokenIds;

    event Deposited(uint256 indexed tokenId, uint64 unlockAt);
    event Collected(uint256 indexed tokenId, uint256 amount0, uint256 amount1);
    event Withdrawn(uint256 indexed tokenId, address to);

    error NotOwner();
    error NotPositionManager();
    error NotHeld();
    error AlreadyLocked();
    error Locked(uint64 unlockAt);
    error ZeroAddress();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(IPositionManager positions_, address owner_) {
        if (address(positions_) == address(0) || owner_ == address(0)) revert ZeroAddress();
        positions = positions_;
        owner = owner_;
        launchUnlock = uint64(block.timestamp + LOCK);
    }

    /// @notice A position sent with safeTransferFrom locks itself on arrival.
    function onERC721Received(address, address, uint256 tokenId, bytes calldata) external returns (bytes4) {
        if (msg.sender != address(positions)) revert NotPositionManager();
        _lock(tokenId);
        return IERC721Receiver.onERC721Received.selector;
    }

    /// @notice For a position minted straight to this lock, or sent by plain transferFrom (neither calls back):
    ///         locks it from now. Anyone may call.
    function register(uint256 tokenId) external {
        if (IERC721(address(positions)).ownerOf(tokenId) != address(this)) revert NotHeld();
        _lock(tokenId);
    }

    /// @notice Sends a position's trading fees to the owner. The liquidity stays: this decreases it by zero, which
    ///         is how v4 pays out fees, then takes both currencies to the owner.
    function collect(uint256 tokenId) external onlyOwner returns (uint256 amount0, uint256 amount1) {
        (PoolKey memory key,) = positions.getPoolAndPositionInfo(tokenId);
        uint256 before0 = key.currency0.balanceOf(owner);
        uint256 before1 = key.currency1.balanceOf(owner);

        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, uint256(0), uint128(0), uint128(0), bytes("")); // liquidity: 0, always
        params[1] = abi.encode(key.currency0, key.currency1, owner);
        positions.modifyLiquidities(abi.encode(actions, params), block.timestamp);

        amount0 = key.currency0.balanceOf(owner) - before0;
        amount1 = key.currency1.balanceOf(owner) - before1;
        emit Collected(tokenId, amount0, amount1);
    }

    /// @notice Hands a position back, only once its unlock time has passed.
    function withdraw(uint256 tokenId, address to) external onlyOwner {
        uint64 at = unlockAt[tokenId];
        if (at == 0) revert NotHeld();
        if (block.timestamp < at) revert Locked(at);
        if (to == address(0)) revert ZeroAddress();
        delete unlockAt[tokenId];
        emit Withdrawn(tokenId, to);
        IERC721(address(positions)).safeTransferFrom(address(this), to, tokenId);
    }

    /// @notice Every position ever deposited (withdrawn ones read unlockAt == 0).
    function count() external view returns (uint256) {
        return tokenIds.length;
    }

    function _lock(uint256 tokenId) private {
        if (unlockAt[tokenId] != 0) revert AlreadyLocked();
        uint64 at = uint64(block.timestamp + LOCK);
        if (at < launchUnlock) at = launchUnlock;
        unlockAt[tokenId] = at;
        tokenIds.push(tokenId);
        emit Deposited(tokenId, at);
    }
}
