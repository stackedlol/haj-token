# Listing pack

Everything the logo listings ask for. Minted on Base on Nov 23, 2026.

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
| Symbol | HAJ (written $HAJ) |
| Chain | Base (8453) |
| Decimals | 18 |
| Contract | `0x1F6dCE8488Db35650480b210D6C5498bEeAa4bee` |
| Total and max supply | 1,000,000 (fixed: no mint function) |
| Pool | Uniswap v4, ETH/HAJ, pool id `0xd34def1f9f4fb1fce90052e9e547490bd996df57f6dabe12c54b1c6395a4550c` ([Uniswap](https://app.uniswap.org/explore/tokens/base/0x1F6dCE8488Db35650480b210D6C5498bEeAa4bee)) |
| Liquidity lock | HajLPLock `0x6B0DfB5cebDB1D56fE261F41e854ba48a31a10e8`, both positions locked until Nov 23, 2027 |
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

> haj ($HAJ) on Base: `0x1F6dCE8488Db35650480b210D6C5498bEeAa4bee`. We're submitting it to CoinGecko. The only contract is the one above.
