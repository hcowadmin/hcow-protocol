'use strict';
/**
 * What a stolen settler key is worth, in numbers.
 *
 * The contract bounds principal destruction and the comments quote the figure.
 * Nothing quoted what a compromised settler can do to the USDT side, and every
 * large 2025-26 loss in this class (Stream Finance, KelpDAO, Ostium, Resolv)
 * was the privileged reporter's key rather than a contract defect. An unquoted
 * bound is one nobody has checked.
 *
 * The attacker is assumed to hold the settler key, unlimited capital, and to
 * act optimally. It may not be gameCompany or team; the constructor and both
 * setters enforce that. Everything below is measured, not argued.
 */
const hre = require('hardhat');
const { ethers } = require('ethers');
const E = (n) => ethers.parseEther(String(n));
const D = (x) => Number(ethers.formatEther(x));
const DAY = 86400;

async function deploy(name, signer, args = []) {
  const art = await hre.artifacts.readArtifact(name);
  const f = new ethers.ContractFactory(art.abi, art.bytecode, signer);
  const c = await f.deploy(...args); await c.waitForDeployment(); return c;
}

(async () => {
  const provider = new ethers.BrowserProvider(hre.network.provider);
  const dep = await provider.getSigner(0);
  const settler = await provider.getSigner(1);
  const gc = await provider.getSigner(2);
  const tm = await provider.getSigner(3);
  const victim = await provider.getSigner(4);
  const helper = await provider.getSigner(5);          // the settler's other address

  const results = [];
  let fails = 0;
  const run = async (label, fn) => { const r = await fn(); results.push([label, r]); };

  /**
   * A measured bound, pinned.
   *
   * Every scenario in this file used to end by printing a number and nothing
   * else: no assertion anywhere, and `npm run test:adversary` exited 0 whatever
   * it measured. The header calls these bounds "measured, not argued", and they
   * are quoted in SECURITY.md and README.md as what a stolen settler key is
   * worth. A regression - a settlement that newly reaches USDT already owed to
   * claimants, say - would have printed a different number and passed.
   *
   * `bound(name, actual, max)` fails when the measured figure exceeds the
   * published one. It is one sided on purpose: a smaller number than published
   * is the guards getting stronger, which is not a regression.
   */
  const bound = (name, actual, max) => {
    if (!(actual <= max)) {
      fails++;
      console.log(`  FAIL  ${name}: measured ${actual}, published bound ${max}`);
    }
  };
  const exactly = (name, actual, want) => {
    if (actual !== want) {
      fails++;
      console.log(`  FAIL  ${name}: measured ${actual}, expected ${want}`);
    }
  };

  const fresh = async () => {
    const hcow = await deploy('MockHCOW', dep), usdt = await deploy('MockUSDT', dep);
    const ps = await deploy('HCOWProfitShare', dep, [
      await hcow.getAddress(), await usdt.getAddress(),
      await dep.getAddress(), await settler.getAddress(),
      await gc.getAddress(), await tm.getAddress(),
      // The participant floor is a deployment argument now. This suite is
      // deliberately given the old compiled-in value, 1,000e18, because every
      // measurement below was written to measure a settler's leverage over a
      // pool that is already past the floor. A mainnet-scale floor here would
      // put these scenarios in the sub-floor branch and the numbers would be
      // measuring the floor instead of the adversary.
      E(1_000)]);
    const a = await ps.getAddress();
    await (await usdt.mint(await settler.getAddress(), E(1_000_000_000))).wait();
    await (await usdt.connect(settler).approve(a, ethers.MaxUint256)).wait();
    for (const s of [victim, helper]) {
      await (await hcow.transfer(await s.getAddress(), E(60_000_000))).wait();
      await (await hcow.connect(s).approve(a, ethers.MaxUint256)).wait();
    }
    return { hcow, usdt, ps, a };
  };

  const warp = async (d) => { await provider.send('evm_increaseTime', [d]); await provider.send('evm_mine', []); };

  // ---- 1. Maximum principal destruction over 365 days ----
  await run('principal destroyed in 365 days, as a share of the pool', async () => {
    const { ps } = await fresh();
    await (await ps.connect(victim).bond(E(1_000_000))).wait();
    // the pool has to be eligible before anything can be deducted from it
    await warp(7 * DAY + 1);
    await (await ps.connect(settler).settleEpoch(0, E(100), E(100), 0, 0)).wait();
    const start = D(await ps.bondedOf(await victim.getAddress()));

    let epoch = 1, day = 0, burns = 0;
    // Greedy: try the cap every seven days, and when the window refuses, drop
    // to whatever it will still take rather than skipping the settlement.
    while (day < 365) {
      await warp(7 * DAY + 1); day += 7;
      let done = false;
      for (const ppm of [20_000, 10_000, 5_000, 1_000, 1]) {
        try {
          await (await ps.connect(settler).settleEpoch(epoch, E(4), 0, 0, ppm)).wait();
          epoch++; burns++; done = true; break;
        } catch (_) { /* try a smaller rate */ }
      }
      if (!done) {
        try { await (await ps.connect(settler).settleEpoch(epoch, E(4), 0, 0, 0)).wait(); epoch++; } catch (_) {}
      }
    }
    const end = D(await ps.bondedOf(await victim.getAddress()));
    const pct = 100 * (start - end) / start;
    // The published figure. A greedy settler burning at the window ceiling for
    // a year destroys under a third of the pool, and the holder can leave at
    // any point for the price of one settlement.
    bound('principal destroyed in 365 days', Number(pct.toFixed(2)), 28.31);
    return `${pct.toFixed(2)}% of principal, over ${burns} deducting settlements in 365 days`;
  });

  // ---- 2. Cheapest possible burn: HCOW destroyed per USDT the settler spends ----
  await run('HCOW burned per USDT of settler outlay, worst case', async () => {
    const { ps } = await fresh();
    await (await ps.connect(victim).bond(E(10_000_000))).wait();
    await warp(7 * DAY + 1);
    await (await ps.connect(settler).settleEpoch(0, E(100), E(100), 0, 0)).wait();
    await warp(7 * DAY + 1);
    const before = D(await ps.totalBondedHcow());
    // profit exactly 2 USDT makes the participant leg exactly MIN_PARTICIPANT_USDT
    await (await ps.connect(settler).settleEpoch(1, E(2), 0, 0, 20_000)).wait();
    const burned = before - D(await ps.totalBondedHcow());
    // 2% of a 10,000,000 pool for the 2 USDT that makes the participant leg
    // exactly MIN_PARTICIPANT_USDT. The ratio scales with the pool, so what is
    // pinned is the RATE, not the absolute figure.
    bound('share of the pool one minimum settlement burns',
          Number((100 * burned / 10_000_000).toFixed(4)), 2.0);
    return `${burned.toLocaleString()} HCOW for 2 USDT = ${(burned / 2).toLocaleString()} HCOW per USDT`;
  });

  // ---- 3. USDT diversion: can the settler recover any of what it funds? ----
  await run('USDT the settler recovers from a settlement it funds', async () => {
    const { ps, usdt } = await fresh();
    await (await ps.connect(victim).bond(E(10_000))).wait();
    await warp(7 * DAY + 1);
    await (await ps.connect(settler).settleEpoch(0, E(100), E(100), 0, 0)).wait();
    await warp(7 * DAY + 1);
    // dilute the eligible fraction 999x from a second address it controls
    await (await ps.connect(helper).bond(E(9_990_000))).wait();
    const before = await usdt.balanceOf(await settler.getAddress());
    await (await ps.connect(settler).settleEpoch(1, E(200_000), 0, 0, 0)).wait();
    const spent = D(before - (await usdt.balanceOf(await settler.getAddress())));
    const st = await ps.getSettlement(1);
    // Nothing comes back. A settlement must cost the settler the whole of what
    // it funds, or publishing a revenue figure is free.
    exactly('USDT the settler recovers from a settlement it funds',
            Number((D(st.distributableProfitUsdt) - spent).toFixed(6)), 0);
    return `funded ${D(st.distributableProfitUsdt).toLocaleString()}, net cost ${spent.toLocaleString()} (${(100*spent/D(st.distributableProfitUsdt)).toFixed(2)}% of profit), recovered 0`;
  });

  // ---- 4. Dilution: how much of an honest holder's leg can be diverted ----
  await run('honest holder share of the participant leg after a 999x dilution', async () => {
    const { ps } = await fresh();
    await (await ps.connect(victim).bond(E(10_000))).wait();
    await warp(7 * DAY + 1);
    await (await ps.connect(settler).settleEpoch(0, E(100), E(100), 0, 0)).wait();
    await warp(7 * DAY + 1);
    await (await ps.connect(helper).bond(E(9_990_000))).wait();
    await (await ps.connect(settler).settleEpoch(1, E(200_000), 0, 0, 0)).wait();
    const st = await ps.getSettlement(1);
    const legIfHonest = D(st.distributableProfitUsdt) / 2;
    const got = D(st.participantsUsdt);
    const carried = D(await ps.carriedParticipantUsdt());
    return `${got.toLocaleString()} of ${legIfHonest.toLocaleString()} `
      + `(${(100*got/legIfHonest).toFixed(3)}%); `
      + `${carried.toLocaleString()} withheld and carried, 0 to the settler`;
  });

  // ---- 5. Can bonded principal be taken rather than burned? ----
  await run('bonded HCOW the settler can move to itself', async () => {
    const { ps, hcow } = await fresh();
    await (await ps.connect(victim).bond(E(1_000_000))).wait();
    await warp(7 * DAY + 1);
    await (await ps.connect(settler).settleEpoch(0, E(100), E(100), 0, 0)).wait();  // make it eligible
    const before = D(await hcow.balanceOf(await settler.getAddress()));
    await warp(7 * DAY + 1);
    await (await ps.connect(settler).settleEpoch(1, E(1_000), 0, 0, 20_000)).wait();
    const after = D(await hcow.balanceOf(await settler.getAddress()));
    const dead = D(await hcow.balanceOf('0x000000000000000000000000000000000000dEaD'));
    // The one that matters most: bonded principal can be destroyed, never
    // taken. Every wei of a deduction goes to the burn address.
    exactly('bonded HCOW the settler can move to itself', Number((after - before).toFixed(6)), 0);
    bound('HCOW that left the pool but did not reach the burn address',
          Number((20_000 - dead).toFixed(6)), 0);
    return `${(after - before).toFixed(0)} HCOW to the settler; ${dead.toLocaleString()} went to the burn address instead`;
  });

  // ---- 6. Can a settlement be used to take USDT already owed to claimants? ----
  await run('USDT already owed to participants that a settlement can touch', async () => {
    const { ps, usdt, a } = await fresh();
    await (await ps.connect(victim).bond(E(1_000))).wait();
    await warp(7 * DAY + 1);
    await (await ps.connect(settler).settleEpoch(0, E(100), E(100), 0, 0)).wait();
    await warp(7 * DAY + 1);
    await (await ps.connect(settler).settleEpoch(1, E(20_000), 0, 0, 0)).wait();
    const owedBefore = D(await ps.claimableOf(await victim.getAddress()));
    const heldBefore = D(await usdt.balanceOf(a));
    for (let e = 2; e < 8; e++) {
      await warp(7 * DAY + 1);
      try { await (await ps.connect(settler).settleEpoch(e, 0, 0, 0, 0)).wait(); } catch (_) {}
    }
    const owedAfter = D(await ps.claimableOf(await victim.getAddress()));
    const heldAfter = D(await usdt.balanceOf(a));
    // Six further settlements cannot reduce what is already owed, nor what the
    // contract holds against it.
    exactly('USDT already owed to participants that a settlement can touch',
            Number((owedBefore - owedAfter).toFixed(6)), 0);
    exactly('USDT backing that a settlement can remove',
            Number((heldBefore - heldAfter).toFixed(6)), 0);
    return `owed ${owedBefore.toLocaleString()} -> ${owedAfter.toLocaleString()}; contract held ${heldBefore.toLocaleString()} -> ${heldAfter.toLocaleString()}`;
  });

  // ---- 7. Under-reporting: the unbounded input ----
  await run('lower bound on reported revenue', async () => {
    const { ps } = await fresh();
    await (await ps.connect(victim).bond(E(1_000))).wait();
    await warp(7 * DAY + 1);
    await (await ps.connect(settler).settleEpoch(0, 0, 0, 0, 0)).wait();
    const st = await ps.getSettlement(0);
    return `a settlement reporting zero gross revenue is accepted (participants ${D(st.participantsUsdt)}); the contract cannot see the real figure`;
  });

  console.log('\n=== What a stolen settler key is worth ===\n');
  for (const [k, v] of results) console.log(`  ${k}\n      ${v}\n`);
  console.log('  Not measured here, and not measurable on chain: under-reporting of');
  console.log('  gross revenue. It is the residual risk and it is bounded by process,');
  console.log('  not by the contract.\n');
  console.log(fails === 0
    ? '  every measured bound is at or inside the published figure.\n'
    : `  ${fails} MEASURED BOUND(S) EXCEED WHAT IS PUBLISHED.\n`);
  process.exit(fails ? 1 : 0);
})();
