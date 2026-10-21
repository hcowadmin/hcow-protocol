'use strict';
/**
 * Testnet check of the 70 / 20 / 10 split, end to end, on a live deployment.
 *
 *   SETTLER_KEY=0x... FUNDER_KEY=0x... \
 *     npx hardhat run scripts/splitcheck.cjs --network bscTestnet
 *
 * smoke.cjs cannot see the split: its only settlement is the first one, where
 * every bond is still new, so nothing is eligible and nothing is deducted. A
 * deducting settlement needs an eligible pool, which needs a previous
 * settlement at least MIN_EPOCH_INTERVAL (seven days) earlier. This script is
 * the second half: run it once the next epoch is open.
 *
 * Step 1, as the settler: settle the next epoch at the maximum rate, with just
 * enough profit for the deduction gate, and check that the consumed HCOW
 * reached the reward vault, the burn address and the team address at exactly
 * the contract's own split, and nowhere else.
 *
 * Step 2, as the keeper: once the running reward period has ended, stream the
 * vault's whole balance into staking over MIN_DURATION, and check that the
 * vault emptied into the stream.
 *
 * Either step that cannot run yet is reported as SKIPPED with the time it can.
 * Nothing here runs on mainnet.
 */
const hre = require('hardhat');
const fs = require('fs');
const path = require('path');
const { connect, at, ethers } = require('./_connect.cjs');

const DEAD = '0x000000000000000000000000000000000000dEaD';
const fmt = (v) => ethers.formatUnits(v, 18);
const when = (s) => new Date(Number(s) * 1000).toISOString().replace('.000Z', 'Z');

let pass = 0, fail = 0, skipped = 0;
function ok(name, cond, detail) {
  if (cond) { pass++; console.log(`  ok    ${name}`); }
  else { fail++; console.log(`  FAIL  ${name}${detail ? '  ' + detail : ''}`); }
}
function skip(section, why) { skipped++; console.log(`  SKIPPED  ${section}: ${why}`); }

async function main() {
  const { provider } = connect();
  const net = await provider.getNetwork();
  if (net.chainId === 56n) throw new Error('refusing to run on BSC mainnet');

  const file = path.join(__dirname, '..', 'deployments', `${hre.network.name}.json`);
  if (!fs.existsSync(file)) throw new Error(`no deployment record at ${file}`);
  const d = JSON.parse(fs.readFileSync(file, 'utf8'));
  const a = d.addresses;
  if (!a.HCOWRewardVault) throw new Error('this deployment has no HCOWRewardVault; it predates the split');

  // Role keys must belong to the addresses the deployment recorded.
  const signerFor = async (role, envKey) => {
    const key = process.env[envKey];
    if (!key) return { why: `${envKey} not set` };
    const w = new ethers.NonceManager(new ethers.Wallet(key, provider));
    const got = await w.getAddress();
    const want = d.roles[role];
    if (got.toLowerCase() !== String(want).toLowerCase()) {
      throw new Error(`${envKey} is ${got} but the deployment records ${role} as ${want}`);
    }
    return { signer: w, address: got };
  };

  const ps = await at('HCOWProfitShare', a.HCOWProfitShare, provider);
  const st = await at('HCOWStaking', a.HCOWStaking, provider);
  const vault = await at('HCOWRewardVault', a.HCOWRewardVault, provider);
  const hcow = await at('MockHCOW', a.HCOW, provider);
  const usdt = await at('MockUSDT', a.USDT, provider);
  const team = await ps.team();

  console.log(`network ${hre.network.name}`);
  console.log(`profit share ${a.HCOWProfitShare}`);
  console.log(`reward vault ${a.HCOWRewardVault}`);
  console.log(`team         ${team}\n`);

  // ---- step 1: a deducting settlement ----
  console.log('Step 1, deducting settlement');
  const settler = await signerFor('settler', 'SETTLER_KEY');
  const opensAt = await ps.epochOpensAt();
  const totalShares = await ps.totalShares();
  const eligible = totalShares - (await ps.totalNewShares());
  if (!settler.signer) {
    skip('settlement', settler.why);
  } else if (opensAt !== 0n) {
    skip('settlement', `the next epoch opens at ${when(opensAt)}`);
  } else if (eligible === 0n) {
    skip('settlement', 'nothing is eligible yet; bond, settle once, wait seven days, then run this');
  } else {
    const epoch = await ps.nextEpoch();
    const deductPpm = await ps.MAX_DEDUCT_PPM();
    const floor = await ps.minPoolShares();
    const denom = eligible < floor ? floor : eligible;
    // The gate needs this epoch's own participant credit to reach one USDT:
    // credit = profit / 2 * eligible / max(eligible, floor). Half again for margin.
    const minProfit = (2n * (10n ** 18n) * denom) / eligible + 1n;
    const profit = (minProfit * 3n) / 2n;
    const held = await usdt.balanceOf(settler.address);
    const expectConsumed = await ps.deductionFor(deductPpm);
    console.log(`  epoch ${epoch}, eligible ${fmt(eligible)} HCOW, profit ${fmt(profit)} USDT, ` +
                `rate ${deductPpm} ppm, expected to consume ${fmt(expectConsumed)} HCOW`);
    if (held < profit) {
      skip('settlement', `settler holds ${fmt(held)} USDT, needs ${fmt(profit)}`);
    } else if (expectConsumed === 0n) {
      skip('settlement', 'deductionFor reports zero; nothing would be consumed');
    } else {
      const before = {
        vault: await hcow.balanceOf(a.HCOWRewardVault),
        dead: await hcow.balanceOf(DEAD),
        team: await hcow.balanceOf(team),
        settler: await hcow.balanceOf(settler.address),
        toR: await ps.totalHcowToRewards(),
        toB: await ps.totalHcowBurned(),
        toT: await ps.totalHcowToTeam(),
      };
      const usdtS = await at('MockUSDT', a.USDT, settler.signer);
      await (await usdtS.approve(a.HCOWProfitShare, profit)).wait();
      const psS = await at('HCOWProfitShare', a.HCOWProfitShare, settler.signer);
      const rc = await (await psS.settleEpoch(epoch, profit, 0, 0, deductPpm)).wait();
      console.log(`  settled epoch ${epoch}  tx ${rc.hash}`);

      const s = await ps.getSettlement(epoch);
      const consumed = s.hcowDeducted;
      const [r, b, t] = await ps.consumedSplit(consumed);
      const dv = (await hcow.balanceOf(a.HCOWRewardVault)) - before.vault;
      const dd = (await hcow.balanceOf(DEAD)) - before.dead;
      const dt = (await hcow.balanceOf(team)) - before.team;
      const ev = rc.logs
        .map((l) => { try { return ps.interface.parseLog(l); } catch { return null; } })
        .find((p) => p && p.name === 'ConsumedHcowRouted');

      ok('the settlement consumed HCOW', consumed > 0n, fmt(consumed));
      ok('it consumed what deductionFor previewed', consumed === expectConsumed,
         `${fmt(consumed)} vs ${fmt(expectConsumed)}`);
      ok('70% reached the reward vault', dv === r, `${fmt(dv)} vs ${fmt(r)}`);
      ok('20% reached the burn address', dd === b, `${fmt(dd)} vs ${fmt(b)}`);
      ok('10% reached the team address', dt === t, `${fmt(dt)} vs ${fmt(t)}`);
      ok('the three legs are the whole consumed amount', r + b + t === consumed);
      ok('the team leg is at most a tenth', t * 10n <= consumed);
      ok('no HCOW reached the settler', (await hcow.balanceOf(settler.address)) === before.settler);
      ok('the routing event states the same three legs',
         !!ev && ev.args.account === ethers.ZeroAddress &&
         ev.args.toRewards === r && ev.args.burned === b && ev.args.toTeam === t);
      ok('the running totals moved by the same three legs',
         (await ps.totalHcowToRewards()) - before.toR === r &&
         (await ps.totalHcowBurned()) - before.toB === b &&
         (await ps.totalHcowToTeam()) - before.toT === t);
      console.log(`  split: ${fmt(r)} to the vault, ${fmt(b)} burned, ${fmt(t)} to team`);
    }
  }

  // ---- step 2: the keeper streams the vault ----
  console.log('\nStep 2, vault to staking');
  const keeper = await signerFor('vaultKeeper', 'FUNDER_KEY');
  const bal = await vault.balance();
  const finish = await st.periodFinish();
  const now = BigInt((await provider.getBlock('latest')).timestamp);
  if (!keeper.signer) {
    skip('stream', keeper.why);
  } else if (bal === 0n) {
    skip('stream', 'the vault holds nothing to stream');
  } else if (!(await vault.isLive())) {
    skip('stream', 'staking does not name the vault as its reward funder');
  } else if (now < finish) {
    // Inside a live period a smaller deposit than the last one is refused by
    // staking's rate floor. The keeper waits for the period to end.
    skip('stream', `the running reward period ends at ${when(finish)}`);
  } else {
    const dur = await vault.MIN_DURATION();
    const funded0 = await st.totalRewardsFunded();
    const vk = await at('HCOWRewardVault', a.HCOWRewardVault, keeper.signer);
    const rc = await (await vk.fund(bal, dur)).wait();
    console.log(`  streamed ${fmt(bal)} HCOW over ${dur}s  tx ${rc.hash}`);
    ok('the vault is empty', (await vault.balance()) === 0n);
    ok('staking recorded exactly that funding', (await st.totalRewardsFunded()) - funded0 === bal);
    ok('the new period runs MIN_DURATION', (await st.periodFinish()) > now);
    ok('no allowance is left behind', (await hcow.allowance(a.HCOWRewardVault, a.HCOWStaking)) === 0n);
  }

  console.log(`\n${pass} passed, ${fail} failed, ${skipped} section(s) skipped`);
  if (fail) process.exitCode = 1;
}

main().catch((e) => { console.error(e.shortMessage || e.message || e); process.exitCode = 1; });
