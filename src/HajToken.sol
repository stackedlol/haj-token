// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title $HAJ
/// @notice 1,000,000 tokens, minted once to the deployer, who hands every one of them to its lock in the same deploy
///         (script/Deploy.s.sol). There is no owner, no mint, no burn-from, no pause, no blocklist and no upgrade:
///         this contract is plain OpenZeppelin ERC-20 plus the one mint below.
contract HajToken is ERC20 {
    uint256 public constant SUPPLY = 1_000_000e18;

    constructor() ERC20("haj", "HAJ") {
        _mint(msg.sender, SUPPLY); // the only mint, ever
    }
}
