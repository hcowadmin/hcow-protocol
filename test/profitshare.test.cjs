'use strict';
/* Run: npx hardhat run test/profitshare.test.cjs */

const hre = require('hardhat');
const { ethers } = require('ethers');

let pass = 0, fail = 0;
const results = [];
let IFACE = null;

function ok(name, cond, detail) {
  if (cond) { pass++; results.push(['ok', name, '']); }
  else { fail++; results.push(['XX', name, detail || '']); }
}
const eq = (name, a, b) => ok(name, String(a) === String(b), `got ${a}, want ${b}`);
/** Float comparison for values that pass through 18 decimal accumulators. */
const near = (name, a, b, tol = 1e-9) =>
  ok(name, Math.abs(a - b) <= tol, `got ${a}, want ${b}`);
async function reverts(name, p, needle) {
  try { await p; ok(name, false, 'did not revert'); }
  catch (e) {
    const data = e.data ?? e.info?.error?.data ?? e.error?.data ?? null;
    let named = '';
    if (data && IFACE) { try { named = IFACE.parseError(data)?.name ?? ''; } catch (_) {} }
    const hay = named || e.message;
    ok(name, !needle || hay.includes(needle), `wrong revert: ${hay.slice(0, 110)}`);
  }
}
/**
 * Assert a revert with an explicit sender.
 * ethers omits `from` when estimating gas through BrowserProvider, which makes
 * msg.sender the zero address and can surface the wrong error. For a contract
 * that moves money the sender must never be ambiguous, so call it directly.
 */
async function rv(name, c, signer, fn, args, expected) {
  const from = await signer.getAddress();
  const to = await c.getAddress();
  const data = c.interface.encodeFunctionData(fn, args);
  try {
    await hre.network.provider.send('eth_call', [{ from, to, data }, 'latest']);
    ok(name, false, 'did not revert');
  } catch (e) {
    const raw = e.data ?? e.error?.data ?? null;
    let named = '';
    if (raw) { try { named = c.interface.parseError(raw)?.name ?? ''; } catch (_) {} }
    ok(name, !expected || named === expected,
       `got ${named || (e.message || '').slice(0, 70)}, want ${expected}`);
  }
}

const E = (n) => ethers.parseEther(String(n));
/** Epochs have a minimum length. Move the clock past it before settling. */
// Long enough to clear both MIN_EPOCH_INTERVAL and DECAY_WINDOW, so the
// scenarios below can use the maximum rate every time without running into the
// cumulative ceiling, which is exercised on its own further down.
let DAY = 30 * 86_400 + 1;
const D = (v) => Number(ethers.formatEther(v));

async function deploy(name, signer, args = []) {
  const art = await hre.artifacts.readArtifact(name);
  const c = await new ethers.ContractFactory(art.abi, art.bytecode, signer).deploy(...args);
  await c.waitForDeployment();
  return c;
}

process.on('unhandledRejection', (e) => {
  console.error('UNHANDLED REJECTION at step:', STEP, e?.shortMessage || e?.message || e);
  process.exit(1);
});
let STEP = 'start';
const step = (s) => { STEP = s; };

async function main() {
  const provider = new ethers.BrowserProvider(hre.network.provider);
  const S = await Promise.all([0, 1, 2, 3, 4, 5].map((i) => provider.getSigner(i)));
  const [deployerS, settlerS, aliceS, bobS, gameCoS, teamS] = S;
  const [deployer, settler, alice, bob, gameCo, teamAddr] =
    await Promise.all(S.map((s) => s.getAddress()));

  const hcow = await deploy('MockHCOW', deployerS);
  const usdt = await deploy('MockUSDT', deployerS);

  const ps = await deploy('HCOWProfitShare', deployerS, [
    await hcow.getAddress(), await usdt.getAddress(),
    deployer, settler, gameCo, teamAddr,
  ]);
  IFACE = ps.interface;
  const psAddr = await ps.getAddress();

  // fund participants and the settler
  await (await hcow.transfer(alice, E(10_000))).wait();
  await (await hcow.transfer(bob, E(30_000))).wait();
  await (await usdt.transfer(settler, E(1_000_000))).wait();
  await (await hcow.connect(aliceS).approve(psAddr, ethers.MaxUint256)).wait();
  await (await hcow.connect(bobS).approve(psAddr, ethers.MaxUint256)).wait();
  await (await usdt.connect(settlerS).approve(psAddr, ethers.MaxUint256)).wait();

  // ---------------- deployment ----------------
  eq('owner set', await ps.owner(), deployer);
  eq('settler set', await ps.settler(), settler);
  eq('gameCompany set', await ps.gameCompany(), gameCo);
  eq('team set', await ps.team(), teamAddr);
  eq('opex cap is 40%', await ps.OPEX_CAP_BPS(), 4000);
  eq('split is 50/25/25',
    `${await ps.PARTICIPANT_BPS()}/${await ps.GAME_COMPANY_BPS()}/${await ps.TEAM_BPS()}`,
    '5000/2500/2500');
  eq('nextEpoch starts at 0', await ps.nextEpoch(), 0);

  await reverts('zero address rejected in constructor',
    deploy('HCOWProfitShare', deployerS, [
      await hcow.getAddress(), await usdt.getAddress(),
      ethers.ZeroAddress, settler, gameCo, teamAddr]), 'ZeroAddress');

  // ---------------- bonding ----------------
  await rv('cannot bond zero', ps, aliceS, 'bond', [0], 'ZeroAmount');

  await (await ps.connect(aliceS).bond(E(1_000))).wait();
  eq('alice bonded 1000', D(await ps.bondedOf(alice)), 1000);
  eq('first bond mints 1:1 shares', D(await ps.totalShares()), 1000);

  await (await ps.connect(bobS).bond(E(3_000))).wait();
  eq('bob bonded 3000', D(await ps.bondedOf(bob)), 3000);
  eq('pool is 4000', D(await ps.totalBondedHcow()), 4000);

  // ---------------- opex cap ----------------
  // gross 100,000  direct 10,000  ->  net 90,000  ->  cap 36,000
  eq('cap helper matches', D(await ps.opexCapFor(E(100_000), E(10_000))), 36000);
  await rv('opex above the cap is rejected', ps, settlerS, 'settleEpoch', [0, E(100_000), E(10_000), E(36_001), 0], 'OpexAboveCap');
  await rv('direct costs above revenue rejected', ps, settlerS, 'settleEpoch', [0, E(100), E(101), 0, 0], 'CostsExceedRevenue');

  // ---------------- rule 4 ----------------
  // net 100 - opex 100 is above the cap, so build a zero-profit epoch legally:
  // gross 100, direct 100 -> net 0, cap 0, opex 0, profit 0
  // Everything bonded so far arrived this epoch, so nobody is eligible yet.
  // A rate is simply ignored in that state: there is nothing to charge and
  // nobody to charge it against. Refusing instead would let a single dominant
  // holder veto every settlement by front running it with an unbond request.
  eq('the rate helper reports nothing while nobody is eligible',
    D(await ps.deductionFor(20_000)), 0);

  await rv('non settler cannot settle', ps, aliceS, 'settleEpoch', [0, E(100), E(100), 0, 0], 'NotSettler');
  await rv('epoch must be sequential', ps, settlerS, 'settleEpoch', [3, E(100), E(100), 0, 0], 'WrongEpoch');

  // a genuinely empty epoch settles, and deducts nothing
  await provider.send('evm_increaseTime', [DAY]); await provider.send('evm_mine', []);
  await (await ps.connect(settlerS).settleEpoch(0, E(100), E(100), 0, 0)).wait();
  eq('empty epoch settled', await ps.nextEpoch(), 1);
  eq('pool untouched by empty epoch', D(await ps.totalBondedHcow()), 4000);
  await rv('a settled epoch cannot be re-settled', ps, settlerS, 'settleEpoch', [0, E(100), E(100), 0, 0], 'WrongEpoch');

  step('distribution'); // ---------------- a real distribution ----------------
  // gross 100,000  direct 10,000  opex 36,000  ->  profit 54,000
  // participants 27,000   gameCo 13,500   team 13,500
  const gcBefore = await usdt.balanceOf(gameCo);
  const tmBefore = await usdt.balanceOf(teamAddr);

  await provider.send('evm_increaseTime', [DAY]); await provider.send('evm_mine', []);
  await (await ps.connect(settlerS).settleEpoch(1, E(100_000), E(10_000), E(36_000), 20_000)).wait();

  eq('game company got 25%', D((await usdt.balanceOf(gameCo)) - gcBefore), 13500);
  eq('team got 25%', D((await usdt.balanceOf(teamAddr)) - tmBefore), 13500);
  eq('participants pool got 50%', D(await ps.totalUsdtDistributed()), 27000);

  eq('alice claimable is her quarter', D(await ps.claimableOf(alice)), 6750);
  eq('bob claimable is his three quarters', D(await ps.claimableOf(bob)), 20250);

  // deduction shrinks everyone by the same proportion
  eq('pool shrank by the deduction', D(await ps.totalBondedHcow()), 3920);
  eq('alice principal shrank 2%', D(await ps.bondedOf(alice)), 980);
  eq('bob principal shrank 2%', D(await ps.bondedOf(bob)), 2940);
  eq('deducted hcow was burned',
    D(await hcow.balanceOf(psAddr)), 3920);
  eq('total deducted recorded', D(await ps.totalHcowDeducted()), 80);

  // ---------------- rule 5 and rule 6, the deduction limits ----------------
  eq('rate cap constant is 2%', Number(await ps.MAX_DEDUCT_PPM()), 20_000);
  eq('epochs have a minimum length of seven days',
    Number(await ps.MIN_EPOCH_INTERVAL()), 7 * 86400);
  ok('the next epoch is not open yet', Number(await ps.epochOpensAt()) > 0,
    'expected a future openAt');
  await rv('a settlement inside the minimum interval is rejected', ps, settlerS,
    'settleEpoch', [2, E(100_000), E(10_000), E(36_000), 0], 'EpochTooSoon');
  await provider.send('evm_increaseTime', [DAY]);
  await provider.send('evm_mine', []);
  eq('and open once the interval has passed', Number(await ps.epochOpensAt()), 0);
  eq('the rate helper matches what was applied', D(await ps.deductionFor(20_000)), 78.4);
  await rv('a rate above the cap is rejected', ps, settlerS, 'settleEpoch',
    [2, E(100_000), E(10_000), E(36_000), 20_001], 'DeductionRateAboveCap');
  await rv('the whole pool cannot be requested', ps, settlerS, 'settleEpoch',
    [2, E(100_000), E(10_000), E(36_000), 1_000_000], 'DeductionRateAboveCap');
  step('rule 6'); // -------- one wei of profit cannot buy a deduction --------
  await rv('a deduction needs a real participant payout', ps, settlerS, 'settleEpoch',
    [2, 1n, 0, 0, 20_000], 'DeductionWithoutDistribution');
  await rv('two wei does not buy one either', ps, settlerS, 'settleEpoch',
    [2, 2n, 0, 0, 20_000], 'DeductionWithoutDistribution');
  eq('pool untouched by the refused settlement', D(await ps.totalBondedHcow()), 3920);

  const st = await ps.getSettlement(1);
  eq('settlement stored gross', D(st.grossReceivedUsdt), 100000);
  eq('settlement stored profit', D(st.distributableProfitUsdt), 54000);
  eq('settlement stored snapshot', D(st.snapshotBondedHcow), 4000);

  step('claiming'); // ---------------- claiming ----------------
  const aliceUsdtBefore = await usdt.balanceOf(alice);
  await (await ps.connect(aliceS).claimUsdt()).wait();
  eq('alice received her usdt', D((await usdt.balanceOf(alice)) - aliceUsdtBefore), 6750);
  eq('alice claimable now zero', D(await ps.claimableOf(alice)), 0);
  await rv('claiming twice reverts', ps, aliceS, 'claimUsdt', [], 'NothingToClaim');

  step('late joiner'); // ---------------- late joiner ----------------
  const carolS = await provider.getSigner(6);
  const carol = await carolS.getAddress();
  await (await hcow.transfer(carol, E(3_920))).wait();
  await (await hcow.connect(carolS).approve(psAddr, ethers.MaxUint256)).wait();
  await (await ps.connect(carolS).bond(E(3_920))).wait();
  eq('carol bonded 3920', D(await ps.bondedOf(carol)), 3920);
  eq('carol has no retroactive claim', D(await ps.claimableOf(carol)), 0);
  eq('bob keeps his unclaimed balance', D(await ps.claimableOf(bob)), 20250);

  await provider.send('evm_increaseTime', [DAY]); await provider.send('evm_mine', []);
  await (await ps.connect(settlerS).settleEpoch(2, E(20_000), 0, E(8_000), 0)).wait();
  // profit 12,000 -> participant leg 6,000. Carol bonded during epoch 2, so
  // epoch 2 is not hers at all.
  //
  // The leg is measured against the pool the epoch BEGAN with, which was alice
  // 980 plus bob 2940. Carol's arrival does not shrink it: she was not part of
  // the participant base the revenue accrued against, and the epoch's leg
  // belongs entirely to those who were. Measuring it against the live share
  // count instead handed carol's notional half to the two fixed recipients,
  // and since bond() is permissionless that was a lever anyone could pull on
  // any epoch from any address, the settler included.
  eq('a new bonder earns nothing in the epoch it arrived in',
    D(await ps.claimableOf(carol)), 0);
  eq('and her arrival does not shrink the leg for those already here',
    D(await ps.claimableOf(alice)) + D(await ps.claimableOf(bob)) - 20250, 6000);
  {
    const st = await ps.getSettlement(2);
    eq('the two fixed recipients take their own half and nothing more',
      D(st.gameCompanyUsdt) + D(st.teamUsdt), 6000);
  }
  eq('alice earned her quarter of the leg', D(await ps.claimableOf(alice)), 1500);
  {
    const st = await ps.getSettlement(2);
    eq('and the waterfall reconciles exactly in the log',
      D(st.distributableProfitUsdt),
      D(st.participantsUsdt) + D(st.gameCompanyUsdt) + D(st.teamUsdt));
  }
  eq('bob earned his three quarters', D(await ps.claimableOf(bob)), 20250 + 4500);

  step('unbonding'); // ---------------- unbonding ----------------
  await rv('cannot cancel without a pending unbond', ps, aliceS, 'cancelUnbond', [], 'NoPendingUnbond');
  await rv('cannot withdraw without a pending unbond', ps, aliceS, 'withdrawUnbonded', [], 'NoPendingUnbond');
  await rv('cannot unbond more than owned', ps, aliceS, 'requestUnbond', [E(10_000)], 'InsufficientBonded');

  step('alice requestUnbond');
  await (await ps.connect(aliceS).requestUnbond(E(980))).wait();
  eq('alice principal left the pool', D(await ps.bondedOf(alice)), 0);
  eq('pending unbond recorded', D(await ps.totalPendingUnbond()), 980);
  await rv('only one unbond at a time', ps, aliceS, 'requestUnbond', [E(1)], 'UnbondAlreadyPending');
  await rv('cooldown blocks withdrawal', ps, aliceS, 'withdrawUnbonded', [], 'CooldownActive');

  // a deduction while alice is exiting must not touch her pending amount
  const poolBefore = await ps.totalBondedHcow();
  await provider.send('evm_increaseTime', [DAY]);
  await provider.send('evm_mine', []);
  await provider.send('evm_increaseTime', [DAY]); await provider.send('evm_mine', []);
  await (await ps.connect(settlerS).settleEpoch(3, E(10_000), 0, E(4_000), 20_000)).wait();
  eq('pool absorbed the deduction', D(await ps.totalBondedHcow()), D(poolBefore) * 0.98);
  eq('pending unbond untouched by deduction', D(await ps.totalPendingUnbond()), 980);
  eq('exiting alice earned nothing new', D(await ps.claimableOf(alice)), 1500);
  // Epoch 3 is the first one carol was present for the whole of. Alice
  // requested her unbond during it, so she is no longer eligible. What she
  // gave up goes to the holders who stayed, not to the two fixed recipients:
  // the leg is divided among the eligible pool, whatever size that pool is.
  //
  // Sending it to the recipients instead was measured moving an ordinary
  // 50/25/25 settlement to 25/37.5/37.5, triggered by a user simply leaving.
  near('a new bonder earns from the next epoch on',
    D(await ps.claimableOf(carol)), 3000 * (3920 / 6860), 1e-6);
  {
    const st = await ps.getSettlement(3);
    eq('and an exit does not enrich the two fixed recipients',
      D(st.gameCompanyUsdt) + D(st.teamUsdt), D(st.distributableProfitUsdt) / 2);
    eq('the three legs still sum exactly',
      D(st.distributableProfitUsdt),
      D(st.participantsUsdt) + D(st.gameCompanyUsdt) + D(st.teamUsdt));
  }

  step('time travel');
  await provider.send('evm_increaseTime', [7 * 24 * 3600 + 1]);
  await provider.send('evm_mine', []);

  console.log('  DBG now:', (await provider.getBlock('latest')).timestamp);
  console.log('  DBG accountOf(aliceS):', (await ps.accountOf(await aliceS.getAddress())).map(String).join(' | '));
  step('alice withdrawUnbonded');
  const aliceHcowBefore = await hcow.balanceOf(alice);
  // explicit gas limit for the same reason: estimation would run without a
  // sender and take the wrong branch. The transaction itself is fine.
  await (await ps.connect(aliceS).withdrawUnbonded({ gasLimit: 300_000 })).wait();
  step('after alice withdraw');
  // Exactly one settlement is charged, whichever door the position leaves by,
  // and only one. Charging none would make withdrawing strictly cheaper than
  // cancelling; charging all of them would bill a slow holder forever.
  near('exactly one settlement is charged on the way out',
    D((await hcow.balanceOf(alice)) - aliceHcowBefore), 980 * 0.98);
  eq('pending unbond cleared', D(await ps.totalPendingUnbond()), 0);

  // cancel path
  step('bob requestUnbond');
  await (await ps.connect(bobS).requestUnbond(E(1_000))).wait();
  const bobBondedDuring = D(await ps.bondedOf(bob));
  step('bob cancelUnbond');
  await (await ps.connect(bobS).cancelUnbond()).wait();
  ok('cancel restores the position',
    Math.abs(D(await ps.bondedOf(bob)) - (bobBondedDuring + 1000)) < 1e-9,
    `got ${D(await ps.bondedOf(bob))}`);
  eq('nothing left pending after cancel', D(await ps.totalPendingUnbond()), 0);

  step('no participants'); // ---------------- no participants ----------------
  const ps2 = await deploy('HCOWProfitShare', deployerS, [
    await hcow.getAddress(), await usdt.getAddress(),
    deployer, settler, gameCo, teamAddr,
  ]);
  await (await usdt.connect(settlerS).approve(await ps2.getAddress(), ethers.MaxUint256)).wait();
  const settlerBefore = await usdt.balanceOf(settler);
  await provider.send('evm_increaseTime', [DAY]); await provider.send('evm_mine', []);
  await (await ps2.connect(settlerS).settleEpoch(0, E(1_000), 0, E(400), 0)).wait();
  // profit 600. Nobody is bonded, so there is no participant to pay and the
  // whole 600 goes to the two fixed recipients: 300 + 300.
  //
  // It is deliberately NOT returned to the settler. The settler is the party
  // that authors the revenue figure and can also move the divisor by bonding
  // into the pool from any address in the settlement block, so a refund path
  // is a discount it can set for itself: measured, 49,950 of a 50,000 USDT
  // leg recovered at 999 times the pool, unbonded a week later at no cost.
  eq('the settler is never paid back, whatever the pool looks like',
    D(settlerBefore - (await usdt.balanceOf(settler))), 600);
  eq('empty pool records zero participants', D((await ps2.getSettlement(0)).participantsUsdt), 0);
  {
    const st = await ps2.getSettlement(0);
    eq('and the two fixed legs absorb the whole profit',
      D(st.gameCompanyUsdt) + D(st.teamUsdt), 600);
    eq('the three legs are exactly the distributable profit',
      D(st.distributableProfitUsdt),
      D(st.participantsUsdt) + D(st.gameCompanyUsdt) + D(st.teamUsdt));
  }

  step('funding required'); // ----------------
  const ps3 = await deploy('HCOWProfitShare', deployerS, [
    await hcow.getAddress(), await usdt.getAddress(),
    deployer, settler, gameCo, teamAddr,
  ]);
  await rv('unfunded settlement reverts', ps3, settlerS, 'settleEpoch', [0, E(1_000), 0, 0, 0], '');

  step('administration'); // ----------------
  await rv('stranger cannot set settler', ps, aliceS, 'setSettler', [alice], 'NotOwner');
  await (await ps.setRecipients(gameCo, gameCo)).wait();
  eq('recipients may be the same address', await ps.team(), gameCo);
  await (await ps.setRecipients(gameCo, teamAddr)).wait();
  await rv('recipients cannot be zero', ps, deployerS, 'setRecipients', [ethers.ZeroAddress, teamAddr], 'ZeroAddress');

  step('lifetime accounting and participant count'); // ----------------
  // A fresh pool so the numbers are exact rather than inherited from the
  // scenarios above. Two bonders, one settlement, one full exit.
  const ps4 = await deploy('HCOWProfitShare', deployerS, [
    await hcow.getAddress(), await usdt.getAddress(),
    deployer, settler, gameCo, teamAddr,
  ]);
  const ps4Addr = await ps4.getAddress();
  await (await usdt.connect(settlerS).approve(ps4Addr, ethers.MaxUint256)).wait();

  eq('empty pool has no participants', Number(await ps4.participantCount()), 0);

  await (await hcow.connect(aliceS).approve(ps4Addr, ethers.MaxUint256)).wait();
  await (await hcow.connect(bobS).approve(ps4Addr, ethers.MaxUint256)).wait();

  await (await ps4.connect(aliceS).bond(E(3_000))).wait();
  eq('first bond counts one participant', Number(await ps4.participantCount()), 1);
  await (await ps4.connect(aliceS).bond(E(1_000))).wait();
  eq('a top up does not double count', Number(await ps4.participantCount()), 1);
  await (await ps4.connect(bobS).bond(E(1_000))).wait();
  eq('second bonder counts', Number(await ps4.participantCount()), 2);

  // Shares bonded during an epoch do not earn that epoch, so close it first
  // with a settlement that distributes nothing.
  await provider.send('evm_increaseTime', [DAY]); await provider.send('evm_mine', []);
  await (await ps4.connect(settlerS).settleEpoch(0, E(100), E(100), 0, 0)).wait();
  eq('nothing is earning in the epoch it arrived in', D(await ps4.claimableOf(alice)), 0);
  eq('and the shares are promoted once it closes',
    D(await ps4.eligibleSharesOf(alice)), D(await ps4.bondedOf(alice)));

  // profit 800 on a 4000/1000 pool. 2% of 5000 is 100, and it splits 80/20.
  await provider.send('evm_increaseTime', [DAY]); await provider.send('evm_mine', []);
  await (await ps4.connect(settlerS).settleEpoch(1, E(1_000), 0, E(200), 20_000)).wait();

  const aLife = await ps4.lifetimeOf(alice);
  const bLife = await ps4.lifetimeOf(bob);
  near('deduction is attributed by share, alice', D(aLife[0]), 80);
  near('deduction is attributed by share, bob', D(bLife[0]), 20);
  eq('nothing claimed yet', D(aLife[1]), 0);
  near('attributed deduction sums to the pool total',
    D(aLife[0]) + D(bLife[0]), D(await ps4.totalHcowDeducted()));

  await (await ps4.connect(aliceS).claimUsdt()).wait();
  near('lifetime claimed usdt recorded', D((await ps4.lifetimeOf(alice))[1]), 320);
  near('claiming does not touch the deduction total', D((await ps4.lifetimeOf(alice))[0]), 80);

  // A second settlement must accumulate, not overwrite.
  // pool is 4900 now, so 2% is 98. alice holds four fifths of it.
  await provider.send('evm_increaseTime', [DAY]);
  await provider.send('evm_mine', []);
  await provider.send('evm_increaseTime', [DAY]); await provider.send('evm_mine', []);
  await (await ps4.connect(settlerS).settleEpoch(2, E(1_000), 0, E(200), 20_000)).wait();
  near('deduction accumulates across epochs', D((await ps4.lifetimeOf(alice))[0]), 80 + 78.4);

  // Full exit clears the participant slot but keeps the history.
  const bobOwned = await ps4.bondedOf(bob);
  await (await ps4.connect(bobS).requestUnbond(bobOwned)).wait();
  eq('a full unbond removes the participant', Number(await ps4.participantCount()), 1);
  ok('history survives the exit', D((await ps4.lifetimeOf(bob))[0]) > 0,
    `got ${D((await ps4.lifetimeOf(bob))[0])}`);
  await (await ps4.connect(bobS).cancelUnbond()).wait();
  eq('cancelling restores the participant', Number(await ps4.participantCount()), 2);

  await provider.send('evm_increaseTime', [DAY]);
  await provider.send('evm_mine', []);
  await rv('deduction still cannot run without distribution', ps4, settlerS,
    'settleEpoch', [3, E(1_000), E(1_000), 0, 1], 'DeductionWithoutDistribution');

  step('flash bond'); // ---- bonding into a settlement earns nothing ----
  const ps6 = await deploy('HCOWProfitShare', deployerS, [
    await hcow.getAddress(), await usdt.getAddress(),
    deployer, settler, gameCo, teamAddr,
  ]);
  const ps6Addr = await ps6.getAddress();
  await (await usdt.connect(settlerS).approve(ps6Addr, ethers.MaxUint256)).wait();
  await (await hcow.connect(aliceS).approve(ps6Addr, ethers.MaxUint256)).wait();
  await (await hcow.connect(bobS).approve(ps6Addr, ethers.MaxUint256)).wait();

  // alice holds for the whole period; bob arrives in the settlement block with
  // nine times the stake, which used to take nine tenths of the distribution.
  await (await ps6.connect(aliceS).bond(E(1_000))).wait();
  await provider.send('evm_increaseTime', [DAY]); await provider.send('evm_mine', []);
  await (await ps6.connect(settlerS).settleEpoch(0, E(100), E(100), 0, 0)).wait();
  await (await ps6.connect(bobS).bond(E(9_000))).wait();
  // A nil settlement in the next block used to release the arrival from
  // quarantine for free, which handed the whole of the real epoch straight
  // back to it. Epochs now have a minimum length, so there is no free close.
  await rv('a nil epoch cannot be closed in the next block to release an arrival',
    ps6, settlerS, 'settleEpoch', [1, E(100), E(100), 0, 0], 'EpochTooSoon');

  await provider.send('evm_increaseTime', [DAY]); await provider.send('evm_mine', []);
  await (await ps6.connect(settlerS).settleEpoch(1, E(10_000), 0, E(4_000), 0)).wait();

  // Alice was the entire participant base for epoch 1. Bob's 9,000 arrived
  // during it and is quarantined, so it neither earns nor dilutes: the whole
  // leg is hers. That is the quarantine rule doing what it says.
  //
  // The absurd version of this, one wei taking the distribution from a ten
  // million HCOW cohort, is stopped by MIN_POOL_SHARES rather than by diluting
  // every honest holder. See the launch window test further down.
  eq('the holder takes the whole leg, because she was the whole participant base',
    D(await ps6.claimableOf(alice)), 3000);
  eq('the arrival takes none of it', D(await ps6.claimableOf(bob)), 0);
  {
    const st = await ps6.getSettlement(1);
    eq('the two fixed recipients take their own half and nothing more',
      D(st.gameCompanyUsdt) + D(st.teamUsdt), 3000);
    eq('and the three legs are exactly the distributable profit',
      D(st.distributableProfitUsdt),
      D(st.participantsUsdt) + D(st.gameCompanyUsdt) + D(st.teamUsdt));
  }
  eq('but the arrival is principal immediately', D(await ps6.bondedOf(bob)), 9000);
  eq('and it is earning from the next epoch',
    D(await ps6.eligibleSharesOf(bob)), D(await ps6.bondedOf(bob)));

  // the next epoch is shared normally
  await provider.send('evm_increaseTime', [DAY]); await provider.send('evm_mine', []);
  await (await ps6.connect(settlerS).settleEpoch(2, E(10_000), 0, E(4_000), 0)).wait();
  eq('the next epoch splits by weight', D(await ps6.claimableOf(bob)), 2700);
  eq('and the holder takes the rest', D(await ps6.claimableOf(alice)), 3000 + 300);
  {
    const st = await ps6.getSettlement(2);
    eq('with everyone eligible the two legs are the plain quarters',
      D(st.gameCompanyUsdt) + D(st.teamUsdt), D(st.distributableProfitUsdt) / 2);
  }

  // an untouched account is still credited for every epoch after it joined
  await provider.send('evm_increaseTime', [DAY]); await provider.send('evm_mine', []);
  await (await ps6.connect(settlerS).settleEpoch(3, E(10_000), 0, E(4_000), 0)).wait();
  eq('promotion is not lost by never touching the account',
    D(await ps6.claimableOf(bob)), 2700 * 2);

  step('deduction dodge'); // ---- stepping out around a settlement costs ----
  // A participant who requests an unbond before a settlement and cancels it
  // afterwards used to pay nothing while everyone else absorbed the whole
  // deduction. Rejoining is now priced at the pool decay that happened while
  // the position sat pending.
  const ps5 = await deploy('HCOWProfitShare', deployerS, [
    await hcow.getAddress(), await usdt.getAddress(),
    deployer, settler, gameCo, teamAddr,
  ]);
  const ps5Addr = await ps5.getAddress();
  await (await usdt.connect(settlerS).approve(ps5Addr, ethers.MaxUint256)).wait();
  await (await hcow.connect(aliceS).approve(ps5Addr, ethers.MaxUint256)).wait();
  await (await hcow.connect(bobS).approve(ps5Addr, ethers.MaxUint256)).wait();
  await (await ps5.connect(aliceS).bond(E(1_000))).wait();
  await (await ps5.connect(bobS).bond(E(1_000))).wait();
  await provider.send('evm_increaseTime', [DAY]); await provider.send('evm_mine', []);
  await (await ps5.connect(settlerS).settleEpoch(0, E(100), E(100), 0, 0)).wait();

  await (await ps5.connect(aliceS).requestUnbond(E(1_000))).wait();   // step out
  await provider.send('evm_increaseTime', [DAY]); await provider.send('evm_mine', []);
  await (await ps5.connect(settlerS).settleEpoch(1, E(1_000), 0, E(200), 20_000)).wait();
  const burnedThisEpoch = D(await ps5.totalHcowDeducted());
  await (await ps5.connect(aliceS).cancelUnbond()).wait();            // step back

  near('the dodger pays the deduction anyway', D(await ps5.bondedOf(alice)), 980);
  near('the honest participant pays the same', D(await ps5.bondedOf(bob)), 980);
  near('the forfeit is counted apart from settlement deductions',
    D(await ps5.totalHcowDeducted()), burnedThisEpoch);
  near('the forfeit was burned', D(await ps5.totalHcowForfeited()), 20);
  eq('hcow held still matches the books', D(await hcow.balanceOf(ps5Addr)),
    D((await ps5.totalBondedHcow()) + (await ps5.totalPendingUnbond())));

  // an honest exit is not penalised: no settlement happens while pending
  await (await ps5.connect(bobS).requestUnbond(E(500))).wait();
  await (await ps5.connect(bobS).cancelUnbond()).wait();
  near('cancelling without a settlement in between is free',
    D(await ps5.bondedOf(bob)), 980);

  // the same dodge through the withdraw door, which is the cheaper one to try
  // Leave part of bob bonded and eligible. A cancelled unbond rejoins as an
  // arrival, so alice is quarantined again, and an epoch with nobody eligible
  // is refused outright.
  await (await ps5.connect(bobS).requestUnbond(E(480))).wait();
  near('the pending view reports the amount as requested',
    D(await ps5.pendingUnbondOf(bob)), 480);
  await provider.send('evm_increaseTime', [DAY]);
  await provider.send('evm_mine', []);
  await provider.send('evm_increaseTime', [DAY]); await provider.send('evm_mine', []);
  await (await ps5.connect(settlerS).settleEpoch(2, E(1_000), 0, E(200), 20_000)).wait();
  near('the pending view reports that one charge',
    D(await ps5.pendingUnbondOf(bob)), 470.4);
  await provider.send('evm_increaseTime', [7 * 24 * 3600 + 1]);
  await provider.send('evm_mine', []);
  const bobHcowBefore = await hcow.balanceOf(bob);
  await (await ps5.connect(bobS).withdrawUnbonded({ gasLimit: 400_000 })).wait();
  near('and waiting out the cooldown does not dodge it',
    D((await hcow.balanceOf(bob)) - bobHcowBefore), 470.4);
  eq('books still balance after a forfeited withdrawal',
    D(await hcow.balanceOf(ps5Addr)),
    D((await ps5.totalBondedHcow()) + (await ps5.totalPendingUnbond())));

  step('charge window'); // ---- a settlement inside the cooldown does bite ----
  const ps7 = await deploy('HCOWProfitShare', deployerS, [
    await hcow.getAddress(), await usdt.getAddress(),
    deployer, settler, gameCo, teamAddr,
  ]);
  await (await usdt.connect(settlerS).approve(await ps7.getAddress(), ethers.MaxUint256)).wait();
  await (await hcow.connect(aliceS).approve(await ps7.getAddress(), ethers.MaxUint256)).wait();
  await (await hcow.connect(bobS).approve(await ps7.getAddress(), ethers.MaxUint256)).wait();
  await (await ps7.connect(aliceS).bond(E(1_000))).wait();
  await (await ps7.connect(bobS).bond(E(1_000))).wait();
  await provider.send('evm_increaseTime', [DAY]); await provider.send('evm_mine', []);
  await (await ps7.connect(settlerS).settleEpoch(0, E(100), E(100), 0, 0)).wait();

  // Request two days after the last settlement, so the next one, which can
  // come no sooner than seven days after that settlement, lands five days into
  // her cooldown.
  await provider.send('evm_increaseTime', [2 * 86_400]); await provider.send('evm_mine', []);
  await (await ps7.connect(aliceS).requestUnbond(E(1_000))).wait();
  await provider.send('evm_increaseTime', [5 * 86_400 + 1]); await provider.send('evm_mine', []);
  await (await ps7.connect(settlerS).settleEpoch(1, E(1_000), 0, E(200), 20_000)).wait();
  near('a settlement inside the cooldown is charged',
    D(await ps7.pendingUnbondOf(alice)), 980);
  eq('and the bonded side pays the same', D(await ps7.bondedOf(bob)), 980);

  step('decay window'); // ---- the cumulative ceiling holds ----
  const ps8 = await deploy('HCOWProfitShare', deployerS, [
    await hcow.getAddress(), await usdt.getAddress(),
    deployer, settler, gameCo, teamAddr,
  ]);
  await (await usdt.connect(settlerS).approve(await ps8.getAddress(), ethers.MaxUint256)).wait();
  await (await hcow.connect(aliceS).approve(await ps8.getAddress(), ethers.MaxUint256)).wait();
  await (await hcow.connect(bobS).approve(await ps8.getAddress(), ethers.MaxUint256)).wait();
  eq('window ceiling is 3% per window', Number(await ps8.MAX_DECAY_PER_WINDOW_PPM()), 30_000);
  eq('window is thirty days', Number(await ps8.DECAY_WINDOW()), 30 * 86_400);

  await (await ps8.connect(aliceS).bond(E(1_000))).wait();
  await (await ps8.connect(bobS).bond(E(1_000))).wait();
  await provider.send('evm_increaseTime', [7 * 86_400 + 1]); await provider.send('evm_mine', []);
  await (await ps8.connect(settlerS).settleEpoch(0, E(100), E(100), 0, 0)).wait();

  // The ceiling is a rate, not a token figure. Three percent per thirty days
  // means 30,000 ppm of allowance, whatever the pool is doing.
  await provider.send('evm_increaseTime', [7 * 86_400 + 1]); await provider.send('evm_mine', []);
  await (await ps8.connect(settlerS).settleEpoch(1, E(10_000), 0, E(4_000), 20_000)).wait();
  eq('the window is metered in ppm of rate', Number(await ps8.decayWindowPpm()), 20_000);
  await provider.send('evm_increaseTime', [7 * 86_400 + 1]); await provider.send('evm_mine', []);
  await rv('a campaign cannot outrun the window ceiling', ps8, settlerS, 'settleEpoch',
    [2, E(10_000), 0, E(4_000), 20_000], 'DecayWindowExhausted');
  // the honest rate is far below it and still goes through
  await (await ps8.connect(settlerS).settleEpoch(2, E(10_000), 0, E(4_000), 5_000)).wait();
  eq('an honest rate is unaffected', Number(await ps8.decayWindowPpm()), 25_000);
  near('and it lands on the pool', D(await ps8.bondedOf(bob)), 980 * 0.995);

  // Capital parked in the pool and pulled out again must not buy the settler
  // extra room. With no base in the ceiling there is nothing for it to move.
  const bondedNow = D(await ps8.totalBondedHcow());
  await (await ps8.connect(aliceS).bond(E(1_500))).wait();
  near('parking capital moves the pool', D(await ps8.totalBondedHcow()), bondedNow + 1_500);
  await provider.send('evm_increaseTime', [7 * 86_400 + 1]); await provider.send('evm_mine', []);
  await rv('but it does not widen the window', ps8, settlerS, 'settleEpoch',
    [3, E(10_000), 0, E(4_000), 20_000], 'DecayWindowExhausted');

  // And the mirror attack. A dominant holder must not be able to shrink the
  // ceiling in front of a settlement and veto it for free. Under a ceiling
  // measured against the live bonded pool this reverted, and the holder then
  // cancelled at no cost.
  await (await ps8.connect(aliceS).requestUnbond(E(1_500))).wait();
  await (await ps8.connect(settlerS).settleEpoch(3, E(10_000), 0, E(4_000), 5_000)).wait();
  eq('a whale cannot veto a settlement by requesting an unbond in front of it',
    Number(await ps8.decayWindowPpm()), 30_000);
  await provider.send('evm_increaseTime', [7 * 86_400 + 1]); await provider.send('evm_mine', []);
  await rv('and the ceiling still binds at exactly 30,000 ppm', ps8, settlerS, 'settleEpoch',
    [4, E(10_000), 0, E(4_000), 1], 'DecayWindowExhausted');

  // Thirty days on, the allowance is fresh.
  await provider.send('evm_increaseTime', [30 * 86_400 + 1]); await provider.send('evm_mine', []);
  await (await ps8.connect(settlerS).settleEpoch(4, E(10_000), 0, E(4_000), 20_000)).wait();
  eq('a new window starts the allowance again', Number(await ps8.decayWindowPpm()), 20_000);

  // ---- the settler cannot buy itself a discount by moving the divisor ----
  // The eligible fraction is eligibleShares/totalShares and totalShares moves
  // with any bond, from any address, in the settlement block. If the part the
  // eligible pool cannot take went back to the settler, that is a discount the
  // settler sets for itself at no HCOW cost, cycling on exactly the cadence it
  // already controls. Measured before the fix: 999x the pool recovered 49,950
  // of a 50,000 USDT leg.
  {
    const psD = await deploy('HCOWProfitShare', deployerS, [
      await hcow.getAddress(), await usdt.getAddress(),
      deployer, settler, gameCo, teamAddr,
    ]);
    const aD = await psD.getAddress();
    await (await usdt.connect(settlerS).approve(aD, ethers.MaxUint256)).wait();
    await (await hcow.transfer(carol, E(10_000))).wait();
    await (await hcow.connect(carolS).approve(aD, ethers.MaxUint256)).wait();
    // the settler's accomplice is a different address; blocking the settler
    // address itself would not close anything
    await (await hcow.transfer(bob, E(9_990_000))).wait();
    await (await hcow.connect(bobS).approve(aD, ethers.MaxUint256)).wait();

    await (await psD.connect(carolS).bond(E(10_000))).wait();
    await provider.send('evm_increaseTime', [7 * 86_400 + 1]); await provider.send('evm_mine', []);
    await (await psD.connect(settlerS).settleEpoch(0, E(100), E(100), 0, 0)).wait();

    await provider.send('evm_increaseTime', [7 * 86_400 + 1]); await provider.send('evm_mine', []);
    const before = await usdt.balanceOf(settler);
    await (await psD.connect(bobS).bond(E(9_990_000))).wait();   // 999x the pool
    await (await psD.connect(settlerS).settleEpoch(1, E(200_000), 0, 0, 0)).wait();
    const spent = D(before - (await usdt.balanceOf(settler)));
    // profit 200,000, so the settler funds the full 200,000 whatever it does.
    // The 100,000 participant leg is scaled to 10,000 / 10,000,000 of itself.
    eq('diluting the pool does not reduce what the settler pays', spent, 200_000);
    const st = await psD.getSettlement(1);
    // The leg is measured against the pool epoch 1 began with, which the
    // in-block bond is not part of, so the honest holder keeps all of it.
    // Against the live share count this was 100 instead of 100,000.
    eq('and the honest holder keeps the whole leg', D(st.participantsUsdt), 100_000);
    eq('the accomplice takes nothing', D(await psD.claimableOf(bob)), 0);
    eq('and the three legs still sum exactly', D(st.distributableProfitUsdt),
      D(st.participantsUsdt) + D(st.gameCompanyUsdt) + D(st.teamUsdt));
  }

  step('solvency'); // ----------------
  const owedUsdt = (await ps.claimableOf(bob)) + (await ps.claimableOf(carol))
    + (await ps.claimableOf(alice));
  const heldUsdt = await usdt.balanceOf(psAddr);
  ok('contract holds at least what it owes in usdt', heldUsdt >= owedUsdt,
    `holds ${D(heldUsdt)}, owes ${D(owedUsdt)}`);

  const heldHcow = await hcow.balanceOf(psAddr);
  const accountedHcow = (await ps.totalBondedHcow()) + (await ps.totalPendingUnbond());
  eq('hcow held equals bonded plus pending', D(heldHcow), D(accountedHcow));

  // ---- Rule 6 is tested on what is credited, not on what was computed ----
  // A pool whose eligible part is a rounding error computes a large leg and
  // credits nothing. Testing the computed figure let that burn the whole
  // pool's principal for one USDT, which is the original Critical returning.
  {
    const ps9 = await deploy('HCOWProfitShare', deployerS, [
      await hcow.getAddress(), await usdt.getAddress(),
      deployer, settler, gameCo, teamAddr,
    ]);
    const a9 = await ps9.getAddress();
    await (await usdt.connect(settlerS).approve(a9, ethers.MaxUint256)).wait();
    await (await hcow.connect(aliceS).approve(a9, ethers.MaxUint256)).wait();
    await (await hcow.connect(bobS).approve(a9, ethers.MaxUint256)).wait();

    await (await ps9.connect(aliceS).bond(1n)).wait();          // one wei, eligible
    await provider.send('evm_increaseTime', [7 * 86_400 + 1]); await provider.send('evm_mine', []);
    await (await ps9.connect(settlerS).settleEpoch(0, E(100), E(100), 0, 0)).wait();
    await (await ps9.connect(bobS).bond(E(1_000))).wait();  // the real pool, not eligible yet

    await provider.send('evm_increaseTime', [7 * 86_400 + 1]); await provider.send('evm_mine', []);
    await rv('a deduction cannot run when the credited leg rounds to nothing',
      ps9, settlerS, 'settleEpoch', [1, E(4), 0, 0, 20_000], 'DeductionWithoutDistribution');
    eq('so the pool is untouched', D(await ps9.bondedOf(bob)), 1_000);
    // and with no deduction the settlement still goes through and the leg is
    // returned rather than being concentrated on the one wei holder
    await (await ps9.connect(settlerS).settleEpoch(1, E(4), 0, 0, 0)).wait();
    {
      const st = await ps9.getSettlement(1);
      near('the two fixed recipients absorb the whole profit',
        D(st.gameCompanyUsdt) + D(st.teamUsdt), 4, 1e-6);
      near('and nothing was returned to the settler',
        D(st.distributableProfitUsdt) - D(st.participantsUsdt)
          - D(st.gameCompanyUsdt) - D(st.teamUsdt), 0, 1e-12);
    }
    eq('and none of it went to the one wei holder', D(await ps9.claimableOf(alice)), 0);
  }

  // ---- Rule 4 ----
  // An epoch with no distributable profit cannot consume principal, whatever
  // else is true. Testing the credited participant figure alone let a carried
  // balance satisfy the gate in an epoch that brought no money in at all.
  {
    const psR = await deploy('HCOWProfitShare', deployerS, [
      await hcow.getAddress(), await usdt.getAddress(),
      deployer, settler, gameCo, teamAddr,
    ]);
    const aR = await psR.getAddress();
    await (await usdt.connect(settlerS).approve(aR, ethers.MaxUint256)).wait();
    await (await hcow.connect(aliceS).approve(aR, ethers.MaxUint256)).wait();
    await (await hcow.transfer(alice, E(1_000))).wait();
    await (await psR.connect(aliceS).bond(E(1_000))).wait();
    await provider.send('evm_increaseTime', [7 * 86_400 + 1]); await provider.send('evm_mine', []);
    await (await psR.connect(settlerS).settleEpoch(0, E(2_000), 0, E(800), 0)).wait();
    const bondedBefore = D(await psR.bondedOf(alice));
    await provider.send('evm_increaseTime', [7 * 86_400 + 1]); await provider.send('evm_mine', []);
    await rv('a zero profit epoch cannot deduct principal', psR, settlerS, 'settleEpoch',
      [1, 0, 0, 0, 20_000], 'DeductionWithoutDistribution');
    await (await psR.connect(settlerS).settleEpoch(1, 0, 0, 0, 0)).wait();
    eq('and the pool is untouched by it', D(await psR.bondedOf(alice)), bondedBefore);
    eq('and a zero profit epoch pays nobody anything',
      D((await psR.getSettlement(1)).gameCompanyUsdt)
        + D((await psR.getSettlement(1)).teamUsdt), 0);
  }

  // ---- the launch window: a dust holder cannot take a real distribution ----
  // One wei bonded before anybody else, then a 10,000,000 HCOW cohort arriving
  // during the epoch. The cohort is quarantined, so without a floor on the
  // pool the leg is measured against, the wei is the entire participant base
  // and takes all of it. Measured before MIN_POOL_SHARES existed: 300,000 USDT
  // to one wei.
  {
    const psL = await deploy('HCOWProfitShare', deployerS, [
      await hcow.getAddress(), await usdt.getAddress(),
      deployer, settler, gameCo, teamAddr,
    ]);
    const aL = await psL.getAddress();
    await (await usdt.mint(settler, E(2_000_000))).wait();
    await (await usdt.connect(settlerS).approve(aL, ethers.MaxUint256)).wait();
    await (await hcow.transfer(carol, E(10_000_000))).wait();
    await (await hcow.connect(carolS).approve(aL, ethers.MaxUint256)).wait();
    await (await hcow.connect(aliceS).approve(aL, ethers.MaxUint256)).wait();

    eq('the pool floor is 1,000 HCOW', D(await psL.MIN_POOL_SHARES()), 1_000);
    await (await psL.connect(aliceS).bond(1n)).wait();
    await provider.send('evm_increaseTime', [7 * 86_400 + 1]); await provider.send('evm_mine', []);
    await (await psL.connect(settlerS).settleEpoch(0, E(100), E(100), 0, 0)).wait();
    await (await psL.connect(carolS).bond(E(10_000_000))).wait();
    await provider.send('evm_increaseTime', [7 * 86_400 + 1]); await provider.send('evm_mine', []);
    await (await psL.connect(settlerS).settleEpoch(1, E(600_000), 0, 0, 0)).wait();

    const st = await psL.getSettlement(1);
    // 300 wei rather than exactly zero: one wei against the 1,000 HCOW floor.
    // Against the 300,000 USDT it would otherwise have taken, that is a
    // reduction of eighteen orders of magnitude.
    ok('a one wei participant base is credited dust, not a distribution',
      (await psL.claimableOf(alice)) < E(1),
      `credited ${(await psL.claimableOf(alice)).toString()} wei`);
    near('and essentially the whole profit goes to the two fixed recipients',
      D(st.gameCompanyUsdt) + D(st.teamUsdt), 600_000, 1e-9);
    eq('the arriving cohort is still quarantined', D(await psL.claimableOf(carol)), 0);

    // once the pool is real, the floor stops binding
    await provider.send('evm_increaseTime', [7 * 86_400 + 1]); await provider.send('evm_mine', []);
    await (await psL.connect(settlerS).settleEpoch(2, E(600_000), 0, 0, 0)).wait();
    near('and a real pool takes the whole leg the next epoch',
      D(await psL.claimableOf(carol)), 300_000, 1e-6);
  }

  // ---------------- report ----------------
  step('report');
  const w = Math.max(...results.map((r) => r[1].length));
  for (const [s, n, d] of results) console.log(`  ${s}  ${n.padEnd(w)}  ${d}`);
  console.log(`\n${pass} passed, ${fail} failed`);
  if (fail) process.exit(1);
}

main().catch((e) => {
  console.error('FAILED at step:', STEP);
  console.error(e.shortMessage || e.message);
  const d = e.data ?? e.info?.error?.data;
  if (d && IFACE) { try { console.error('error:', IFACE.parseError(d)?.name); } catch (_) {} }
  console.error(e.info?.error?.message || '');
  process.exit(1);
});
