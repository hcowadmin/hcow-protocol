'use strict';
// Builds the Settler Safe batch for one weekly settlement. Read-only.
//
//   GROSS=12.5 DIRECT=0.5 OPEX=2 DEDUCT_PPM=0 \
//   npx hardhat run scripts/mainnet-settle-batch.cjs --network bsc
//
// Amounts are USDT in plain decimals. DEDUCT_PPM is parts per million of the
// bonded pool (0 to 20000; 0 means no HCOW is consumed this epoch).
//
// Writes out/mainnet/safe/settle_epoch_<n>.json with two transactions:
//   USDT.approve(HCOWProfitShare, profit)   only if profit > 0
//   HCOWProfitShare.settleEpoch(n, gross, direct, opex, deductPpm)
// and refuses, before writing anything, every condition the contract would
// revert on that can be read from the chain now.

const { fs, path, ethers, ROOT, ERC20, loadConfig, provider, readRecord, addr, hre } = require('./_mainnet.cjs');

async function main() {
  const cfg = loadConfig();
  const p = provider();
  const rec = readRecord();
  if (!rec) throw new Error('no deployment record');
  const settler = addr('roles.settler', cfg.roles.settler);
  const usdtA = addr('USDT', cfg.tokens.USDT);
  const P = new ethers.Contract(rec.addresses.HCOWProfitShare, (await hre.artifacts.readArtifact('HCOWProfitShare')).abi, p);
  const U = new ethers.Contract(usdtA, ERC20.concat(['function approve(address,uint256) returns (bool)']), p);

  const u = (k) => ethers.parseUnits(process.env[k] || '0', 18);
  const gross = u('GROSS'), direct = u('DIRECT'), opex = u('OPEX');
  const ppm = Number(process.env.DEDUCT_PPM || '0');
  const bad = [];
  if (direct > gross) bad.push('DIRECT exceeds GROSS');
  const net = gross - direct;
  const cap = await P.opexCapFor(gross, direct);
  if (opex > cap) bad.push(`OPEX ${ethers.formatUnits(opex, 18)} exceeds the cap ${ethers.formatUnits(cap, 18)}`);
  const profit = net > opex ? net - opex : 0n;
  if (ppm < 0 || ppm > 20000) bad.push('DEDUCT_PPM must be 0..20000');

  const [epoch, opensAt, totalShares, bal, block] = await Promise.all([
    P.nextEpoch(), P.epochOpensAt(), P.totalShares(), U.balanceOf(settler), p.getBlock('latest')]);
  if (block.timestamp < Number(opensAt)) bad.push(`epoch ${epoch} opens at ${new Date(Number(opensAt) * 1000).toISOString()}`);
  if (profit > 0n && totalShares === 0n) bad.push('profit > 0 but nobody has bonded HCOW (NoParticipantsToCarryFor)');
  if (bal < profit) bad.push(`Settler Safe holds ${ethers.formatUnits(bal, 18)} USDT, needs ${ethers.formatUnits(profit, 18)}`);

  console.log(`epoch ${epoch}  gross ${ethers.formatUnits(gross, 18)}  direct ${ethers.formatUnits(direct, 18)}  ` +
              `opex ${ethers.formatUnits(opex, 18)} (cap ${ethers.formatUnits(cap, 18)})  profit ${ethers.formatUnits(profit, 18)} USDT  deductPpm ${ppm}`);
  if (bad.length) { console.error('refused:\n  ' + bad.join('\n  ')); process.exitCode = 1; return; }

  const txs = [];
  if (profit > 0n) txs.push({ to: usdtA, data: U.interface.encodeFunctionData('approve', [rec.addresses.HCOWProfitShare, profit]) });
  txs.push({ to: rec.addresses.HCOWProfitShare,
             data: P.interface.encodeFunctionData('settleEpoch', [epoch, gross, direct, opex, ppm]) });
  if (profit === 0n) {
    try { await p.call({ from: settler, to: txs[0].to, data: txs[0].data }); console.log('simulated from the Settler Safe: ok'); }
    catch (e) { console.error(`simulation reverts: ${e.shortMessage || e.message}`); process.exitCode = 1; return; }
  } else {
    console.log('not simulated: settleEpoch needs the approve in the same batch to have executed first');
  }

  // Reuse the Transaction Builder writer from postdeploy.
  const { batchFile } = require('./_safebatch.cjs');
  const f = batchFile(settler, `HCOW profit share: settle epoch ${epoch}`,
    `profit ${ethers.formatUnits(profit, 18)} USDT, deductPpm ${ppm}`, txs);
  const dir = path.join(ROOT, 'out', 'mainnet', 'safe');
  fs.mkdirSync(dir, { recursive: true });
  const file = path.join(dir, `settle_epoch_${epoch}.json`);
  fs.writeFileSync(file, JSON.stringify(f, null, 2) + '\n');
  console.log(`written ${file}`);
}

main().catch((e) => { console.error(e.shortMessage || e.message); process.exitCode = 1; });
