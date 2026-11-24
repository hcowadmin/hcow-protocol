'use strict';
// After the four Safe batches: real users stake and bond, a week passes, the
// Settler Safe settles a real (small) epoch built by mainnet-settle-batch.cjs,
// and every leg lands where the contracts say it should.
//   STEP=before-settle | after-settle
const hre = require('hardhat');
const fs = require('fs');
const path = require('path');
const { ethers } = require('ethers');
const { loadConfig, readRecord } = require('../../scripts/_mainnet.cjs');
let fails = 0;
const ok = (c, m) => { console.log(`  ${c ? 'ok ' : 'BAD'}  ${m}`); if (!c) fails++; };
async function main() {
  if (hre.network.name !== 'localhost') throw new Error('local node only');
  const p = new ethers.JsonRpcProvider(hre.network.config.url, undefined, { staticNetwork: true });
  const cfg = loadConfig();
  const A = readRecord().addresses;
  const abi = async (n) => (await hre.artifacts.readArtifact(n)).abi;
  const accts = (await p.listAccounts()).map((x) => x.address);
  const holder = await p.getSigner(accts[1]);
  const alice = await p.getSigner(accts[2]);
  const bob = await p.getSigner(accts[3]);
  const E = ['function transfer(address,uint256) returns (bool)', 'function approve(address,uint256) returns (bool)', 'function balanceOf(address) view returns (uint256)'];
  const H = new ethers.Contract(cfg.tokens.HCOW, E, holder);
  const U = new ethers.Contract(cfg.tokens.USDT, E, p);
  const S = new ethers.Contract(A.HCOWStaking, await abi('HCOWStaking'), p);
  const V = new ethers.Contract(A.HCOWRewardVault, await abi('HCOWRewardVault'), p);
  const P = new ethers.Contract(A.HCOWProfitShare, await abi('HCOWProfitShare'), p);
  const u = (x) => ethers.parseUnits(String(x), 18);
  const rep = ethers.encodeBytes32String(cfg.representatives[0].id);

  if (process.env.STEP === 'before-settle') {
    // state after batches 01..04
    const r = await S.representativeOf(rep);
    ok(r.exists !== false, `representative "${cfg.representatives[0].name}" registered and active`);
    ok((await S.totalRewardsFunded()) === u(cfg.rewards.firstAmountHcow), `staking funded ${cfg.rewards.firstAmountHcow} HCOW through the vault`);
    ok((await V.totalStreamed()) === u(cfg.rewards.firstAmountHcow), 'vault totalStreamed matches');
    ok((await H.balanceOf(A.HCOWRewardVault)) === 0n, 'vault holds nothing after streaming');
    const pf = Number(await S.periodFinish()); const now = (await p.getBlock('latest')).timestamp;
    ok(Math.abs(pf - now - cfg.rewards.durationSeconds) < 120, `reward period ends in ${((pf - now) / 86400).toFixed(2)} days`);
    ok((await P.nextEpoch()) === 1n, 'zero settlement of epoch 0 by the Settler Safe advanced nextEpoch to 1');
    // users
    await (await H.transfer(accts[2], u(50_000))).wait();
    await (await H.transfer(accts[3], u(1_500_000))).wait();
    await (await new ethers.Contract(cfg.tokens.HCOW, E, alice).approve(A.HCOWStaking, u(50_000))).wait();
    await (await S.connect(alice).stake(u(50_000), rep)).wait();
    ok((await S.totalStaked()) === u(50_000), 'alice staked 50,000 HCOW with the foundation representative');
    await (await new ethers.Contract(cfg.tokens.HCOW, E, bob).approve(A.HCOWProfitShare, u(1_500_000))).wait();
    await (await P.connect(bob).bond(u(1_500_000))).wait();
    ok((await P.totalShares()) > 0n, 'bob bonded 1,500,000 HCOW in profit share');
    await p.send('evm_increaseTime', [7 * 86400 + 60]); await p.send('evm_mine', []);
  } else {
    const before = JSON.parse(fs.readFileSync(path.join(__dirname, '.balances.json'), 'utf8'));
    const gc = await U.balanceOf(cfg.roles.gameCompany), tm = await U.balanceOf(cfg.roles.team);
    const settled = await P.getSettlement(1);
    console.log(`  epoch 1 settled: ${JSON.stringify(settled, (k, v) => typeof v === 'bigint' ? v.toString() : v).slice(0, 300)}`);
    ok(gc - BigInt(before.gc) === u('2.5'), `game company received ${ethers.formatUnits(gc - BigInt(before.gc), 18)} USDT (25% of 10)`);
    ok(tm - BigInt(before.tm) === u('2.5'), `team received ${ethers.formatUnits(tm - BigInt(before.tm), 18)} USDT (25% of 10)`);
    const claim = await P.claimableOf(accts[3]);
    console.log(`  bob claimable ${ethers.formatUnits(claim, 18)} USDT (participant leg, scaled by the 1,000,000 HCOW floor, may be carried)`);
    ok((await P.nextEpoch()) === 2n, 'nextEpoch 2');
    const pend = await S.pendingRewardOf(accts[2]);
    ok(pend > 0n, `alice has ${ethers.formatUnits(pend, 18)} HCOW staking reward pending after 7 days`);
  }
  if (process.env.STEP === 'before-settle') {
    fs.writeFileSync(path.join(__dirname, '.balances.json'), JSON.stringify({
      gc: (await U.balanceOf(cfg.roles.gameCompany)).toString(), tm: (await U.balanceOf(cfg.roles.team)).toString() }));
  }
  if (fails) process.exitCode = 1;
}
main().catch((e) => { console.error(e.shortMessage || e.message); process.exitCode = 1; });
