<p align="center"><img src="assets/banner.gif" alt="haj" width="100%"></p>

<p align="center"><b>haj</b> · a fixed-supply utility token for <a href="https://www.haj.trading">haj</a> · Base · mint Nov 20, 2026</p>

**Supply**

```
1,000,000 HAJ   minted once, never again

  600,000  60%  HAJ/ETH pool, Uniswap v4 on Base  · position locked 12 months
  200,000  20%  later seasons                     · locked 12 months
  100,000  10%  Season 1, first 1,000 users       · claims open Dec 18, 2026
  100,000  10%  founder                           · nothing for 12 months, then linear over 12
```

**Token** · [`src/HajToken.sol`](src/HajToken.sol)

```solidity
contract HajToken is ERC20 {
    uint256 public constant SUPPLY = 1_000_000e18;

    constructor() ERC20("haj", "HAJ") {
        _mint(msg.sender, SUPPLY); // the only mint, ever
    }
}   // no owner · no mint() · no pause() · no upgrade
```

**Locks** · [`script/Deploy.s.sol`](script/Deploy.s.sol) · [`src/HajLPLock.sol`](src/HajLPLock.sol)

```solidity
// OpenZeppelin VestingWallet, unmodified
new VestingWallet(founder, launch + 365 days, 365 days); // nothing before Nov 20, 2027
new VestingWallet(seasons, launch + 365 days, 0);        // released Nov 20, 2027

// HajLPLock: every pool position, the launch one and each later top-up, 365 days from its deposit
function withdraw(uint256 tokenId, address to) external onlyOwner {
    if (block.timestamp < unlockAt[tokenId]) revert Locked(unlockAt[tokenId]);
    IERC721(address(positions)).safeTransferFrom(address(this), to, tokenId);
}
function collect(uint256 tokenId) external onlyOwner {  // trading fees to the owner, liquidity stays
    actions   = [DECREASE_LIQUIDITY, TAKE_PAIR];
    params[0] = abi.encode(tokenId, 0, 0, 0, "");        // decrease by zero: how v4 pays out fees
    params[1] = abi.encode(currency0, currency1, owner);
    positions.modifyLiquidities(abi.encode(actions, params), block.timestamp);
}
// never removes liquidity · never approves anyone · never sets a subscriber: nothing else can move a position
```

**Sniper protection** · [`src/HajLaunchHook.sol`](src/HajLaunchHook.sol) · [`script/Pool.s.sol`](script/Pool.s.sol)

<p align="center"><img src="assets/fee-curve.svg" alt="Launch fee: 80% at second 0, falling to 1% at 90 seconds" width="100%"></p>

```
fee(t) = 1% + 79% × ((90 − t) / 90)²     the first 90 seconds after the pool's liquidity lands, then 1% forever

   0 s  80.0%     15 s  55.9%     30 s  36.1%     60 s  9.8%     90 s  1.0%     120 s  1.0%
```

The pool's LP fee starts at 80% and falls to 1%, so a bot buying in the launch block keeps a fifth of what it
puts in (on a fork of Base with a 1 ETH pool, $100 at second 0 buys 21% of what $100 buys at second 120). Pool, position and lock
happen in one Ledger broadcast, and the clock starts when the liquidity lands. Only the founder can open the pool,
nobody can trade or add liquidity before that, and only the founder can add liquidity during the 90 seconds. The
hook has no owner, no admin and no setters.

**Fees paid during the first 90 seconds go to the locked launch position, which pays out to the founder.**

**Claims** · [`src/HajClaim.sol`](src/HajClaim.sol)

```solidity
function setRoot(bytes32 root_) external {
    if (msg.sender != rootSetter) revert NotRootSetter();
    if (root != bytes32(0)) revert RootAlreadySet();    // once, at the end of Season 1
    root = root_;
    opensAt = uint64(block.timestamp);
}
// claimed HAJ unlocks evenly over 90 days from opensAt
// unclaimed after 180 days → sweep() to the seasons lock, never the founder
```

**Earning, Season 1**

```
bar        5 paper trades + 7 active days    (an active day = a trade that UTC day)
sign-up    15 HAJ                            (counts once the bar is cleared)
usage      20 HAJ
week two   15 HAJ                            (14 active days)
ranks      share of 50,000 HAJ
           first 1,000 accounts to clear the bar
```

**Run it**

```sh
forge test                      # unit tests + a full launch on forks of Base and Base Sepolia

# launch, every transaction signed on a Ledger (Deploy also deploys the hook; Pool opens the pool, fills it, locks it)
FOUNDER=0x… SEASONS=0x… forge script script/Deploy.s.sol --rpc-url base --ledger --sender $FOUNDER --broadcast --verify
FOUNDER=0x… POOL_ETH=<wei> forge script script/Pool.s.sol --rpc-url base --ledger --sender $FOUNDER --broadcast
```

Can't: mint more · pause transfers · pull liquidity · founder sells before Nov 2027. No presale, no insider allocations.

<sub>A utility token for use within haj; nothing here is an offer to sell or investment advice. MIT.</sub>
