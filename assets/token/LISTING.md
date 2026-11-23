# Listing pack

Everything the logo listings ask for, ready before mint. The contract address is filled in at mint.

## Logo

White fins on black, centred so they sit well inside the circle that wallets and Uniswap crop to.

| File | For |
|---|---|
| `haj-1024.png` | master |
| `haj-256.png` | the token list (`logoURI`) |
| `haj-200.png` | CoinGecko (asks for 200×200 PNG) |
| `haj-32.png` | Basescan token info (32×32) |

## The token

| | |
|---|---|
| Name | haj |
| Symbol | HAJ |
| Chain | Base (8453) |
| Decimals | 18 |
| Contract | *at mint* |
| Total and max supply | 1,000,000 (fixed: no mint function) |
| Pool | Uniswap v4, ETH/HAJ, *pool link at mint* |
| Liquidity lock | HajLPLock, *address at mint*, unlocks a year after launch |
| Website | https://www.haj.trading |
| Telegram | https://t.me/think0rswim |
| Source | https://github.com/stackedlol/haj-token |

One line: *haj is a fixed-supply utility token for haj. 1,000,000 made once; 60% in a Uniswap pool locked for a
year.*

## Order of work

1. **At mint:** Basescan verifies the source code in the same `forge script` run (`--verify`, Etherscan API key).
2. **Token list:** `node script/tokenlist.mjs`, then push. The logo is live for anything that reads token lists.
3. **Basescan token info:** verify address ownership (a message signed on the Ledger), then submit the token
   update form with `haj-32.png` and the links above.
4. **CoinGecko** (coingecko.com/en/coins/new), the source Uniswap takes its logos from:
   - Post the verification note on Telegram first.
   - Submit with `haj-200.png`, the table above, the pool link and the lock.
   - Uniswap shows the logo about 48 hours after CoinGecko has it.

Telegram verification post (post it, then link it in the CoinGecko form):

> haj (HAJ) on Base: `<contract>`. We're submitting it to CoinGecko. The only contract is the one above.
