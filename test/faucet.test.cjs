'use strict';
/* Run: npx hardhat run test/faucet.test.cjs */

const hre = require('hardhat');
const { ethers } = require('ethers');

let pass = 0, fail = 0;
const results = [];
let IFACE = null;
let STEP = '';

function ok(name, cond, detail) {
  if (cond) { pass++; results.push(['ok', name, '']); }
  else { fail++; results.push(['XX', name, detail || '']); }
}
const eq = (name, a, b) => ok(name, String(a) === String(b), `got ${a}, want ${b}`);
const near = (name, a, b, tol = 1e-9) =>
  ok(name, Math.abs(a - b) <= tol, `got ${a}, want ${b}`);
const step = (s) => { STEP = s; };

/**
 * Revert assertion with an explicit sender. ethers omits `from` when estimating
 * gas through BrowserProvider, which makes msg.sender the zero address and can
 * surface a completely different error than a real user would hit.
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
const D = (v) => Number(ethers.formatEther(v));

async function deploy(name, signer, args = []) {
  const art = await hre.artifacts.readArtifact(name);
  const c = await new ethers.ContractFactory(art.abi, art.bytecode, signer).deploy(...args);
  await c.waitForDeployment();
  return c;
}

async function timeTravel(seconds) {
  await hre.network.provider.send('evm_increaseTime', [seconds]);
  await hre.network.provider.send('evm_mine', []);
}

async function main() {
  const provider = new ethers.BrowserProvider(hre.network.provider);
  const S = await Promise.all([0, 1, 2, 3].map((i) => provider.getSigner(i)));
  const [ownerS, aliceS, bobS, carolS] = S;
  const [owner, alice, bob, carol] = await Promise.all(S.map((s) => s.getAddress()));

  const hcow = await deploy('MockHCOW', ownerS);
  const usdt = await deploy('MockUSDT', ownerS);
  const faucet = await deploy('HCOWFaucet', ownerS, [
    await hcow.getAddress(), await usdt.getAddress(), owner,
  ]);
  const addr = await faucet.getAddress();
  IFACE = faucet.interface;

  step('empty faucet'); // ----------------
  await rv('claiming an unfunded faucet reverts', faucet, aliceS, 'claim', [], 'FaucetEmpty');
  let st = await faucet.status(alice);
  eq('no claims available when empty', st[5], 0n);

  step('funding'); // ----------------
  // Enough HCOW for three claims, enough USDT for ten, so the reported
  // "claims left" must follow the scarcer of the two.
  await (await hcow.transfer(addr, E(150_000))).wait();
  await (await usdt.transfer(addr, E(10_000))).wait();

  st = await faucet.status(alice);
  near('hcow per claim', D(st[0]), 50_000);
  near('usdt per claim', D(st[1]), 1_000);
  near('hcow remaining', D(st[2]), 150_000);
  near('usdt remaining', D(st[3]), 10_000);
  eq('ready immediately for a new address', st[4], 0n);
  // A claim spends the cooldown whether or not both sides paid, so the honest
  // figure is how many FULL allowances remain.
  eq('claims left is bound by the scarcer token', st[5], 3n);

  step('first claim'); // ----------------
  const hcowBefore = await hcow.balanceOf(alice);
  const usdtBefore = await usdt.balanceOf(alice);
  await (await faucet.connect(aliceS).claim()).wait();

  near('alice received hcow', D((await hcow.balanceOf(alice)) - hcowBefore), 50_000);
  near('alice received usdt', D((await usdt.balanceOf(alice)) - usdtBefore), 1_000);
  eq('claimer counted', await faucet.claimerCount(), 1n);
  eq('claim counted', await faucet.totalClaims(), 1n);
  ok('cooldown is now set', (await faucet.claimableAt(alice)) > 0n);

  step('cooldown'); // ----------------
  await rv('a second claim inside the window reverts', faucet, aliceS, 'claim', [], 'CooldownActive');
  eq('a different address is unaffected', await faucet.claimableAt(bob), 0n);

  await (await faucet.connect(bobS).claim()).wait();
  eq('two distinct claimers', await faucet.claimerCount(), 2n);
  eq('two claims total', await faucet.totalClaims(), 2n);

  await timeTravel(24 * 60 * 60 + 1);
  eq('cooldown clears after a day', await faucet.claimableAt(alice), 0n);
  await (await faucet.connect(aliceS).claim()).wait();
  eq('a repeat claim does not double count the claimer', await faucet.claimerCount(), 2n);
  eq('but does count the claim', await faucet.totalClaims(), 3n);

  step('running dry'); // ----------------
  // Three claims of 50,000 have drained the HCOW side exactly.
  near('hcow drained', D(await hcow.balanceOf(addr)), 0);
  ok('usdt still held', (await usdt.balanceOf(addr)) > 0n);
  // One empty side must not kill the other. USDT drains fifty times faster
  // than HCOW at these amounts, so "both or nothing" would be the normal
  // state of the faucet, not an edge case.
  const carolHcowBefore = await hcow.balanceOf(carol);
  const carolUsdtBefore = await usdt.balanceOf(carol);
  await (await faucet.connect(carolS).claim()).wait();
  near('the drained side pays nothing', D((await hcow.balanceOf(carol)) - carolHcowBefore), 0);
  ok('the funded side still pays', (await usdt.balanceOf(carol)) - carolUsdtBefore > 0n);
  // and the cooldown is spent anyway, so a partial claim cannot be repeated.
  // Leaving it unset turns the faucet's steady state into a free drain.
  ok('a partial claim still spends the cooldown', (await faucet.claimableAt(carol)) > 0n);
  await rv('so it cannot be repeated in the same window',
    faucet, carolS, 'claim', [], 'CooldownActive');
  st = await faucet.status(carol);
  eq('claims left is zero once a side is dry', st[5], 0n);

  // both sides empty is still a refusal, and does not burn the cooldown
  const drained = await usdt.balanceOf(addr);
  await (await faucet.withdraw(await usdt.getAddress(), owner, drained)).wait();
  await rv('claiming a fully empty faucet reverts',
    faucet, bobS, 'claim', [], 'FaucetEmpty');
  await rv('zero amounts are refused', faucet, ownerS, 'setAmounts', [0, E(1)], 'ZeroAmounts');
  await (await usdt.transfer(addr, drained)).wait();

  step('administration'); // ----------------
  await rv('stranger cannot change amounts', faucet, aliceS, 'setAmounts', [E(1), E(1)], 'NotOwner');
  await (await faucet.setAmounts(E(10_000), E(500))).wait();
  st = await faucet.status(carol);
  near('amounts updated', D(st[0]), 10_000);

  await (await hcow.transfer(addr, E(30_000))).wait();
  st = await faucet.status(carol);
  eq('claims left recomputed against the new amounts', st[5], 3n);

  await rv('stranger cannot withdraw', faucet, aliceS, 'withdraw',
    [await hcow.getAddress(), alice, E(1)], 'NotOwner');
  await rv('cannot withdraw to zero', faucet, ownerS, 'withdraw',
    [await hcow.getAddress(), ethers.ZeroAddress, E(1)], 'ZeroAddress');

  const ownerBefore = await hcow.balanceOf(owner);
  await (await faucet.withdraw(await hcow.getAddress(), owner, E(30_000))).wait();
  near('owner recovered the balance', D((await hcow.balanceOf(owner)) - ownerBefore), 30_000);

  await rv('stranger cannot take ownership', faucet, aliceS, 'transferOwnership', [alice], 'NotOwner');
  await (await faucet.transferOwnership(bob)).wait();
  eq('ownership moved', await faucet.owner(), bob);

  step('supply safety'); // ----------------
  // The faucet must never be able to create tokens. Total supply is fixed at
  // deployment and nothing here may change it.
  eq('hcow supply untouched by the faucet', D(await hcow.totalSupply()), 200_000_000);

  step('report'); // ----------------
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
  process.exit(1);
});
