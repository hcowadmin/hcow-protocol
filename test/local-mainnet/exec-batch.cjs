'use strict';
// Executes a Safe Transaction Builder batch on the LOCAL node by impersonating
// the Safe, transaction by transaction, exactly as the batch file states them.
// This is what proves the generated calldata does what its name says.
//   BATCH=out/mainnet/safe/01_....json npx hardhat run test/local-mainnet/exec-batch.cjs --network localhost
const hre = require('hardhat');
const fs = require('fs');
const { ethers } = require('ethers');
async function main() {
  if (hre.network.name !== 'localhost') throw new Error('local node only');
  const p = new ethers.JsonRpcProvider(hre.network.config.url, undefined, { staticNetwork: true });
  const b = JSON.parse(fs.readFileSync(process.env.BATCH, 'utf8'));
  const safe = b.meta.createdFromSafeAddress;
  if (b.chainId !== '56') throw new Error('batch is not for chain 56');
  await p.send('hardhat_impersonateAccount', [safe]);
  const s = new ethers.JsonRpcSigner(p, safe);
  for (const t of b.transactions) {
    const r = await (await s.sendTransaction({ to: t.to, data: t.data, value: 0 })).wait();
    console.log(`  ${b.meta.name}: tx to ${t.to} status ${r.status} gas ${r.gasUsed}`);
  }
  await p.send('hardhat_stopImpersonatingAccount', [safe]);
}
main().catch((e) => { console.error(e.shortMessage || e.message); process.exitCode = 1; });
