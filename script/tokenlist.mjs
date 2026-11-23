// Writes assets/token/haj.tokenlist.json (the tokenlists.org format) from the mainnet deployment, so wallets and
// apps that take token lists show haj with its logo from the first block. Run it once Deploy.s.sol has written
// deployments/base.json, then commit and push: the logo is served from this repo on GitHub.
//
//   node script/tokenlist.mjs
import { readFileSync, writeFileSync } from "node:fs";

const repo = new URL("..", import.meta.url).pathname;
const d = JSON.parse(readFileSync(repo + "deployments/base.json", "utf8"));
if (d.chainId !== 8453) throw new Error(`deployments/base.json is chain ${d.chainId}, not Base mainnet (8453)`);
const LOGO = "https://raw.githubusercontent.com/stackedlol/haj-token/main/assets/token/haj-256.png";
const list = {
  name: "haj",
  timestamp: new Date().toISOString(),
  version: { major: 1, minor: 0, patch: 0 },
  logoURI: LOGO,
  keywords: ["haj"],
  tokens: [{ chainId: 8453, address: d.token, name: "haj", symbol: "HAJ", decimals: 18, logoURI: LOGO }],
};
writeFileSync(repo + "assets/token/haj.tokenlist.json", JSON.stringify(list, null, 2) + "\n");
console.log("wrote assets/token/haj.tokenlist.json for", d.token);
