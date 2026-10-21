'use strict';
/* Run: npx hardhat run test/rewardvault.test.cjs */

const hre = require('hardhat');
const { ethers } = require('ethers');

let pass = 0, fail = 0;
const results = [];

function ok(name, cond, detail) {
  if (cond) { pass++; results.push(['ok', name, '']); }
  else { fail++; results.push(['XX', name, detail || '']); console.log(`  XX  ${name}  ${detail || ''}`); }
}
const eq = (name, a, b) => ok(name, String(a) === String(b), `got ${a}, want ${b}`);

/** eth_call with an explicit sender, then decode the custom error by name. */
async function rv(name, c, signer, fn, args, expected, ifaces = []) {
  const from = await signer.getAddress();
  const to = await c.getAddress();
  const data = c.interface.encodeFunctionData(fn, args);
  try {
    await hre.network.provider.send('eth_call', [{ from, to, data }, 'latest']);
    ok(name, false, 'did not revert');
  } catch (e) {
    const raw = e.data ?? e.error?.data ?? null;
    let named = '';
    for (const i of [c.interface, ...ifaces]) {
      if (named || !raw) break;
      try { named = i.parseError(raw)?.name ?? ''; } catch (_) {}
    }
    ok(name, !expected || named === expected, `got ${named || (e.message || '').slice(0, 70)}, want ${expected}`);
  }
}
async function reverts(name, p, needle, iface) {
  try { await p; ok(name, false, 'did not revert'); }
  catch (e) {
    const data = e.data ?? e.info?.error?.data ?? e.error?.data ?? null;
    let named = '';
    if (data && iface) { try { named = iface.parseError(data)?.name ?? ''; } catch (_) {} }
    const hay = named || e.message;
    ok(name, !needle || hay.includes(needle), `wrong revert: ${hay.slice(0, 110)}`);
  }
}

const E = (n) => ethers.parseEther(String(n));
const D = (v) => Number(ethers.formatEther(v));
const DAY = 86_400;

async function deploy(name, signer, args = []) {
  const art = await hre.artifacts.readArtifact(name);
  const c = await new ethers.ContractFactory(art.abi, art.bytecode, signer).deploy(...args);
  await c.waitForDeployment();
  return c;
}

async function main() {
  const provider = new ethers.BrowserProvider(hre.network.provider);
  const S = await Promise.all([0, 1, 2, 3, 4, 5, 6, 7].map((i) => provider.getSigner(i)));
  const [ownerS, keeperS, strangerS, stakerS, settlerS, gameCoS, teamS, newKeeperS] = S;
  const [owner, keeper, stranger, staker, settler, gameCo, team, newKeeper] =
    await Promise.all(S.map((s) => s.getAddress()));
  const warp = async (t) => { await provider.send('evm_increaseTime', [t]); await provider.send('evm_mine', []); };
  const now = async () => (await provider.getBlock('latest')).timestamp;

  const hcow = await deploy('MockHCOW', ownerS);
  const usdt = await deploy('MockUSDT', ownerS);
  const H = await hcow.getAddress();
  const st = await deploy('HCOWStaking', ownerS, [H, owner, owner]);
  const ST = await st.getAddress();

  // ---------------- construction ----------------
  const vf = (args) => deploy('HCOWRewardVault', ownerS, args);
  const probe = await vf([H, ST, owner, keeper]);
  const VI = probe.interface;
  await reverts('refuses a zero token', vf([ethers.ZeroAddress, ST, owner, keeper]), 'ZeroAddress', VI);
  await reverts('refuses a zero staking contract', vf([H, ethers.ZeroAddress, owner, keeper]), 'ZeroAddress', VI);
  await reverts('refuses a zero owner', vf([H, ST, ethers.ZeroAddress, keeper]), 'ZeroAddress', VI);
  await reverts('refuses a zero keeper', vf([H, ST, owner, ethers.ZeroAddress]), 'ZeroAddress', VI);
  {
    const other = await deploy('MockHCOW', ownerS);
    const stO = await deploy('HCOWStaking', ownerS, [await other.getAddress(), owner, owner]);
    await reverts('refuses a staking contract for another token',
      vf([H, await stO.getAddress(), owner, keeper]), 'WrongToken', VI);
  }
  await reverts('refuses a staking address that is not a staking contract',
    vf([H, await usdt.getAddress(), owner, keeper]));

  const vault = probe;
  const V = await vault.getAddress();
  eq('hcow is fixed', await vault.hcow(), H);
  eq('staking is fixed', await vault.staking(), ST);
  eq('owner is set', await vault.owner(), owner);
  eq('keeper is set', await vault.keeper(), keeper);
  eq('the minimum stream is a week', await vault.MIN_DURATION(), 7 * DAY);
  eq('the maximum stream is thirty days', await vault.MAX_DURATION(), 30 * DAY);

  // ---------------- the only exit ----------------
  // Every state changing function, by name. If one is added this fails and
  // the person adding it has to say here why it is not a second exit.
  {
    const mut = vault.interface.fragments
      .filter((f) => f.type === 'function' && f.stateMutability !== 'view' && f.stateMutability !== 'pure')
      .map((f) => f.name).sort();
    eq('the state changing functions are exactly these five', mut.join(','),
      ['acceptOwnership', 'cancelOwnershipTransfer', 'fund', 'setKeeper', 'transferOwnership'].sort().join(','));
  }

  // ---------------- before the vault is the funder ----------------
  await (await hcow.transfer(V, E(1_000))).wait();
  eq('anyone can top it up by transfer', D(await vault.balance()), 1_000);
  eq('it is not live until staking names it the funder', await vault.isLive(), false);
  await rv('fund reaches staking and staking refuses it', vault, keeperS, 'fund', [E(100), 30 * DAY], 'NotFunder', [st.interface]);

  await (await st.connect(ownerS).setRewardFunder(V)).wait();
  eq('live once named', await vault.isLive(), true);

  // ---------------- who and how long ----------------
  await rv('the owner cannot fund', vault, ownerS, 'fund', [E(100), 30 * DAY], 'NotKeeper');
  await rv('a stranger cannot fund', vault, strangerS, 'fund', [E(100), 30 * DAY], 'NotKeeper');
  await rv('a stream shorter than a week is refused', vault, keeperS, 'fund', [E(100), 7 * DAY - 1], 'BadDuration');
  await rv('a stream longer than thirty days is refused', vault, keeperS, 'fund', [E(100), 30 * DAY + 1], 'BadDuration');
  await rv('more than the vault holds is refused', vault, keeperS, 'fund', [E(1_000) + 1n, 30 * DAY], 'InsufficientBalance');

  // ---------------- a stream ----------------
  const ownerBefore = await hcow.balanceOf(owner);
  const rc = await (await vault.connect(keeperS).fund(E(300), 30 * DAY)).wait();
  const t0 = await now();
  eq('the stream left the vault', D(await vault.balance()), 700);
  eq('and arrived in staking', D(await hcow.balanceOf(ST)), 300);
  eq('staking recorded the funding', D(await st.totalRewardsFunded()), 300);
  eq('the period runs the requested duration', Number(await st.periodFinish()), t0 + 30 * DAY);
  eq('no allowance is left behind', await hcow.allowance(V, ST), 0n);
  eq('the vault counts it', D(await vault.totalStreamed()), 300);
  eq('no HCOW reached the owner', (await hcow.balanceOf(owner)) - ownerBefore, 0n);
  ok('it emits Streamed', rc.logs.some((l) => { try { return vault.interface.parseLog(l)?.name === 'Streamed'; } catch { return false; } }));

  // staking's own floor still applies: no shortening a live stream
  await rv('staking refuses a stream that ends before the running one', vault, keeperS,
    'fund', [E(10), 7 * DAY], 'BadDuration', [st.interface]);
  eq('and the refused call moved nothing', D(await vault.balance()), 700);

  // ---------------- administration ----------------
  await rv('a stranger cannot replace the keeper', vault, strangerS, 'setKeeper', [stranger], 'NotOwner');
  await rv('the keeper cannot replace itself', vault, keeperS, 'setKeeper', [stranger], 'NotOwner');
  await rv('the keeper cannot be zero', vault, ownerS, 'setKeeper', [ethers.ZeroAddress], 'ZeroAddress');
  await (await vault.connect(ownerS).setKeeper(newKeeper)).wait();
  await rv('the old keeper is out', vault, keeperS, 'fund', [E(10), 30 * DAY], 'NotKeeper');
  // Enough to keep the running rate, which staking requires of a live period.
  await (await vault.connect(newKeeperS).fund(E(700), 30 * DAY)).wait();
  eq('the new keeper streams', D(await vault.totalStreamed()), 1_000);

  await rv('a stranger cannot nominate an owner', vault, strangerS, 'transferOwnership', [stranger], 'NotOwner');
  await (await vault.connect(ownerS).transferOwnership(stranger)).wait();
  eq('a nomination is not ownership', await vault.owner(), owner);
  await rv('only the nominee can accept', vault, keeperS, 'acceptOwnership', [], 'NotPendingOwner');
  await (await vault.connect(ownerS).cancelOwnershipTransfer()).wait();
  await rv('a cancelled nomination cannot be accepted', vault, strangerS, 'acceptOwnership', [], 'NotPendingOwner');
  await (await vault.connect(ownerS).transferOwnership(stranger)).wait();
  await (await vault.connect(strangerS).acceptOwnership()).wait();
  eq('the nominee becomes owner', await vault.owner(), stranger);
  await rv('the old owner has nothing left', vault, ownerS, 'setKeeper', [owner], 'NotOwner');

  // ---------------- end to end: settlement -> vault -> stakers ----------------
  {
    const hcow2 = await deploy('MockHCOW', ownerS);
    const H2 = await hcow2.getAddress();
    const st2 = await deploy('HCOWStaking', ownerS, [H2, owner, owner]);
    const v2 = await deploy('HCOWRewardVault', ownerS, [H2, await st2.getAddress(), owner, keeper]);
    const V2 = await v2.getAddress();
    await (await st2.connect(ownerS).setRewardFunder(V2)).wait();
    const ps = await deploy('HCOWProfitShare', ownerS, [
      H2, await usdt.getAddress(), owner, settler, gameCo, team, E(100), V2,
    ]);
    const PS = await ps.getAddress();

    // a staker delegates
    const REP = ethers.id('rep-a');
    await (await st2.connect(ownerS).registerRepresentative(REP, 'Rep A', owner, 0, false)).wait();
    await (await hcow2.transfer(staker, E(10_000))).wait();
    await (await hcow2.connect(stakerS).approve(await st2.getAddress(), ethers.MaxUint256)).wait();
    await (await st2.connect(stakerS).stake(E(10_000), REP)).wait();

    // a participant bonds and two epochs settle, the second with the full 2%
    await (await hcow2.transfer(stranger, E(100_000))).wait();
    await (await hcow2.connect(strangerS).approve(PS, ethers.MaxUint256)).wait();
    await (await ps.connect(strangerS).bond(E(100_000))).wait();
    await (await usdt.transfer(settler, E(10_000))).wait();
    await (await usdt.connect(settlerS).approve(PS, ethers.MaxUint256)).wait();
    await (await ps.connect(settlerS).settleEpoch(0, E(1_000), 0, 0, 0)).wait();
    await warp(7 * DAY + 1);
    await (await ps.connect(settlerS).settleEpoch(1, E(1_000), 0, 0, 20_000)).wait();
    eq('the settlement put 70% of 2,000 in the vault', D(await v2.balance()), 1_400);

    await (await v2.connect(keeperS).fund(E(1_400), 7 * DAY)).wait();
    await warp(7 * DAY + 1);
    const pending = D(await st2.pendingRewardOf(staker));
    ok('the staker earned the stream', Math.abs(pending - 1_400) < 1e-6, `pending ${pending}`);
    const b0 = await hcow2.balanceOf(staker);
    await (await st2.connect(stakerS).claimHcow()).wait();
    ok('and can claim it', D((await hcow2.balanceOf(staker)) - b0) > 1_399.999);
  }

  // ---------------- report ----------------
  const w = Math.max(...results.map((r) => r[1].length));
  for (const [s, n, d] of results) console.log(`  ${s}  ${n.padEnd(w)}  ${d}`);
  console.log(`\n${pass} passed, ${fail} failed`);
  if (fail) process.exit(1);
}

main().catch((e) => { console.error('after:', results.length ? results[results.length - 1][1] : '(none)'); console.error(e.shortMessage || e.message, e.data ?? e.info?.error?.data ?? ''); process.exit(1); });
