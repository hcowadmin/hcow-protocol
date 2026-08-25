'use strict';
/* Run: npx hardhat run test/ledger.test.cjs */

const hre = require('hardhat');
const { ethers } = require('ethers');
const { leafHash, canonicalize, seedCommitmentValid, RecordError, KINDS } = require('../lib/canonical');
const { buildTree, getProof, verifyProof } = require('../lib/merkle');

let pass = 0, fail = 0;
const results = [];

function ok(name, cond, detail) {
  if (cond) { pass++; results.push(['PASS', name, '']); }
  else { fail++; results.push(['FAIL', name, detail || '']); }
}
function eq(name, a, b) { ok(name, String(a) === String(b), `got ${a}, want ${b}`); }
let IFACE = null;
async function reverts(name, p, needle) {
  try { await p; ok(name, false, 'did not revert'); }
  catch (e) {
    // ethers reports custom errors raised during estimateGas as raw data,
    // so decode it against the ABI instead of matching on the message.
    const data = e.data ?? e.info?.error?.data ?? e.error?.data ?? null;
    let named = '';
    if (data && IFACE) { try { named = IFACE.parseError(data)?.name ?? ''; } catch (_) {} }
    const hay = named || e.message;
    ok(name, !needle || hay.includes(needle), `wrong revert: ${hay.slice(0, 120)}`);
  }
}

function record(over = {}) {
  const serverSeed = over.serverSeed || 'seed-abc-123';
  return {
    gameId: 'tint',
    roundId: 'r-000001',
    playerRef: 'u_8f21c4',
    serverSeedHash: ethers.keccak256(ethers.toUtf8Bytes(serverSeed)),
    serverSeed,
    clientSeed: 'c-99',
    nonce: 1,
    outcome: 'solved:3moves',
    timestamp: 1755000000,
    ...over,
  };
}

function skill(o = {}) {
  return {
    gameId: 'tint', roundId: 'r-000001', playerRef: 'p_8f21c4',
    mode: 'campaign', level: 12, score: 8400, durationMs: 64210,
    outcome: 'cleared', endedAt: 1755000000, ...o,
  };
}

async function main() {
  const provider = new ethers.BrowserProvider(hre.network.provider);
  const [ownerS, anchorS, strangerS] = await Promise.all([
    provider.getSigner(0), provider.getSigner(1), provider.getSigner(2),
  ]);
  const owner = await ownerS.getAddress();
  const anchorer = await anchorS.getAddress();

  const art = await hre.artifacts.readArtifact('HCOWLedger');
  const factory = new ethers.ContractFactory(art.abi, art.bytecode, ownerS);
  const c = await factory.deploy(owner, anchorer);
  await c.waitForDeployment();
  IFACE = c.interface;
  const asAnchor = c.connect(anchorS);
  const asStranger = c.connect(strangerS);

  // ---------------- deployment ----------------
  eq('owner set', await c.owner(), owner);
  ok('anchorer set', await c.isAnchorer(anchorer));
  ok('stranger is not anchorer', !(await c.isAnchorer(await strangerS.getAddress())));
  // The cursor starts at the period the contract was deployed in, not at
  // zero. A ledger starting at zero would need one catch up transaction for
  // every hour since 1970 before it could anchor the current one.
  const G = await c.genesisEpoch();
  const nowTs = BigInt((await provider.getBlock('latest')).timestamp);
  eq('genesisEpoch is the deployment period', G, nowTs / 3600n);
  eq('nextEpoch starts at genesisEpoch', await c.nextEpoch(), G);
  /** Move the chain past the end of `epoch` so it may be anchored. */
  const finish = async (epoch) => {
    const endsAt = Number((BigInt(epoch) + 1n) * 3600n);
    const t = (await provider.getBlock('latest')).timestamp;
    if (t < endsAt) {
      await provider.send('evm_setNextBlockTimestamp', [endsAt + 1]);
      await provider.send('evm_mine', []);
    }
  };
  eq('historicalBatchCount starts at 0', await c.historicalBatchCount(), 0);
  eq('seeded domain published', await c.LEAF_DOMAIN_SEEDED(), 'HCOWv1|');
  eq('skill domain published', await c.LEAF_DOMAIN_SKILL(), 'HCOWs1|');
  eq('epoch length published', Number(await c.EPOCH_SECONDS()), 3600);

  // ---------------- canonical form ----------------
  const r1 = record();
  eq('same record, same leaf', leafHash(r1,'seeded'), leafHash(record(),'seeded'));
  ok('different nonce changes leaf', leafHash(r1,'seeded') !== leafHash(record({ nonce: 2 }),'seeded'));
  ok('canonical ends with newline', canonicalize(r1,'seeded').endsWith('\n'));
  eq('canonical field count', canonicalize(r1,'seeded').trim().split('\t').length, 9);

  try { leafHash({ ...r1, extra: 'x' },'seeded'); ok('extra field rejected', false); }
  catch (e) { ok('extra field rejected', e instanceof RecordError); }
  try { const bad = { ...r1 }; delete bad.outcome; leafHash(bad,'seeded'); ok('missing field rejected', false); }
  catch (e) { ok('missing field rejected', e instanceof RecordError); }
  try { leafHash({ ...r1, nonce: '1' },'seeded'); ok('string nonce rejected', false); }
  catch (e) { ok('string nonce rejected', e instanceof RecordError); }
  try { leafHash({ ...r1, nonce: -1 },'seeded'); ok('negative nonce rejected', false); }
  catch (e) { ok('negative nonce rejected', e instanceof RecordError); }

  // delimiter injection: a tab inside a value must not fake a field boundary
  const injA = record({ gameId: 'tint\tr-000001' });
  const injB = record({ gameId: 'tint', roundId: 'r-000001' });
  ok('tab injection cannot forge a record', leafHash(injA,'seeded') !== leafHash(injB,'seeded'));
  const injC = record({ outcome: 'a\nb' });
  ok('newline is escaped', canonicalize(injC,'seeded').split('\n').length === 2);

  // ---------------- seed commitment ----------------
  ok('valid seed commitment passes', seedCommitmentValid(r1));
  ok('tampered seed fails commitment', !seedCommitmentValid({ ...r1, serverSeed: 'other' }));

  // ---------------- two record kinds ----------------
  const sk = skill();
  eq('skill canonical field count', canonicalize(sk, 'skill').trim().split('\t').length, 9);
  ok('skill and seeded kinds differ', leafHash(sk, 'skill') !== leafHash(r1, 'seeded'));
  eq('skill domain tag', KINDS.skill.domain, 'HCOWs1|');
  eq('seeded domain tag', KINDS.seeded.domain, 'HCOWv1|');
  try { leafHash(sk, 'seeded'); ok('kind mismatch rejected', false); }
  catch (e) { ok('kind mismatch rejected', e instanceof RecordError); }
  try { leafHash(sk, 'nope'); ok('unknown kind rejected', false); }
  catch (e) { ok('unknown kind rejected', e instanceof RecordError); }
  try { leafHash({ ...sk, score: -1 }, 'skill'); ok('negative score rejected', false); }
  catch (e) { ok('negative score rejected', e instanceof RecordError); }

  // ---------------- merkle ----------------
  const one = buildTree([leafHash(r1,'seeded')]);
  eq('single leaf root equals leaf', one.root, leafHash(r1,'seeded').toLowerCase());

  try { buildTree([leafHash(r1,'seeded'), leafHash(r1,'seeded')]); ok('duplicate leaves rejected', false); }
  catch (e) { ok('duplicate leaves rejected', /duplicate/.test(e.message)); }
  try { buildTree(['0xdeadbeef']); ok('malformed leaf rejected', false); }
  catch (e) { ok('malformed leaf rejected', /bad leaf/.test(e.message)); }

  const N = 1001; // odd, forces promotion at several levels
  const recs = Array.from({ length: N }, (_, i) =>
    record({ roundId: `r-${String(i).padStart(6, '0')}`, nonce: i, serverSeed: `seed-${i}` }));
  // half seeded, half skill, in one tree. the contract never sees the kind.
  const leaves = recs.map((r, i) => i % 2
    ? leafHash(r, 'seeded')
    : leafHash(skill({ roundId: r.roundId, score: 1000 + i, endedAt: 1755000000 + i }), 'skill'));
  const tree = buildTree(leaves);
  ok('root is 32 bytes', /^0x[0-9a-f]{64}$/.test(tree.root));

  let allJs = true;
  for (let i = 0; i < N; i++) {
    if (!verifyProof(leaves[i], getProof(tree.levels, i), tree.root)) { allJs = false; break; }
  }
  ok(`js verifies all ${N} proofs`, allJs);
  ok('proof depth is logarithmic', getProof(tree.levels, 0).length <= 11,
     `depth ${getProof(tree.levels, 0).length}`);

  // ---------------- anchoring rules ----------------
  await reverts('stranger cannot anchor', asStranger.anchorEpoch(G, tree.root, N), 'NotAnchorer');
  await reverts('epoch must be sequential', asAnchor.anchorEpoch(G + 5n, tree.root, N), 'WrongEpoch');
  await reverts('root without records rejected', asAnchor.anchorEpoch(G, tree.root, 0), 'RootWithoutRecords');
  await reverts('records without root rejected',
    asAnchor.anchorEpoch(G, ethers.ZeroHash, 5), 'RecordsWithoutRoot');

  await finish(G);
  const tx = await asAnchor.anchorEpoch(G, tree.root, N);
  const rc = await tx.wait();
  eq('nextEpoch advanced', await c.nextEpoch(), G + 1n);
  ok('epoch anchored', await c.isEpochAnchored(G));
  ok('next epoch not anchored', !(await c.isEpochAnchored(G + 1n)));
  eq('totalLiveRecords', await c.totalLiveRecords(), N);

  const stored = await c.getEpoch(G);
  eq('stored root matches', stored.root, tree.root);
  eq('stored count matches', stored.recordCount, N);
  ok('anchoredAt set', Number(stored.anchoredAt) > 0);

  await reverts('cannot rewrite an anchored epoch', asAnchor.anchorEpoch(G, ethers.ZeroHash, 0), 'WrongEpoch');

  // empty period still occupies its slot, so the chain has no hole
  await finish(G + 1n);
  await asAnchor.anchorEpoch(G + 1n, ethers.ZeroHash, 0);
  eq('empty epoch anchored', await c.nextEpoch(), G + 2n);
  eq('empty epoch adds no records', await c.totalLiveRecords(), N);

  // ---------------- on chain verification ----------------
  const idx = 500;
  const proof = getProof(tree.levels, idx);
  ok('on chain verify accepts a real record', await c.verifyEpochRecord(G, leaves[idx], proof));
  ok('on chain verify rejects a tampered record',
    !(await c.verifyEpochRecord(G, leafHash({ ...recs[idx], outcome: 'solved:1move' }, 'seeded'), proof)));
  ok('on chain verify rejects a wrong proof',
    !(await c.verifyEpochRecord(G, leaves[idx], getProof(tree.levels, idx + 1))));
  ok('on chain verify rejects an empty epoch', !(await c.verifyEpochRecord(G + 1n, leaves[idx], proof)));

  // structural forgeries: the proof length is fixed by the record count, so
  // the root itself and any internal node are refused as records
  ok('the root cannot be presented as a record',
    !(await c.verifyEpochRecord(G, tree.root, [])));
  ok('an internal node cannot be presented as a record',
    !(await c.verifyEpochRecord(G, tree.levels[1][0], proof.slice(1))));
  ok('an over long proof is refused',
    !(await c.verifyEpochRecord(G, leaves[idx], [...proof, tree.root])));
  ok('on chain verify rejects a future epoch', !(await c.verifyEpochRecord(G + 99n, leaves[idx], proof)));

  let allChain = true;
  for (const i of [0, 1, 2, 499, 500, 998, 999, 1000]) {
    if (!(await c.verifyEpochRecord(G, leaves[i], getProof(tree.levels, i)))) { allChain = false; break; }
  }
  ok('chain and js agree on sampled indices', allChain);

  // ---------------- historical backfill ----------------
  const hist = buildTree(leaves.slice(0, 300));
  await reverts('historical needs a root', asAnchor.anchorHistorical(ethers.ZeroHash, 1, 1, 2), 'RecordsWithoutRoot');
  await reverts('historical range must be ordered',
    asAnchor.anchorHistorical(hist.root, 300, 200, 100), 'BadRange');

  await asAnchor.anchorHistorical(hist.root, 300, 1700000000, 1754000000);
  eq('historical batch recorded', await c.historicalBatchCount(), 1);
  eq('historical records counted', await c.totalHistoricalRecords(), 300);
  eq('totalRecords sums both', await c.totalRecords(), N + 300);
  ok('historical verify works',
    await c.verifyHistoricalRecord(0, leaves[10], getProof(hist.levels, 10)));
  ok('historical verify rejects out of batch record',
    !(await c.verifyHistoricalRecord(0, leaves[999], getProof(tree.levels, 999))));

  // ---------------- administration ----------------
  await reverts('stranger cannot set anchorer', asStranger.setAnchorer(owner, true), 'NotOwner');
  await c.setAnchorer(await strangerS.getAddress(), true);
  ok('owner can add anchorer', await c.isAnchorer(await strangerS.getAddress()));
  await c.setAnchorer(await strangerS.getAddress(), false);
  ok('owner can remove anchorer', !(await c.isAnchorer(await strangerS.getAddress())));
  await reverts('owner cannot be zero', c.transferOwnership(ethers.ZeroAddress), 'ZeroAddress');

  // no admin path can alter an anchored root
  const before = (await c.getEpoch(G)).root;
  await c.setAnchorer(owner, true);
  await reverts('owner cannot rewrite either', c.anchorEpoch(G, ethers.ZeroHash, 0), 'WrongEpoch');
  eq('root unchanged after admin activity', (await c.getEpoch(G)).root, before);

  // Renouncing with nobody left who can anchor is unrecoverable: epochs are
  // strictly sequential and there is no cursor override, so the ledger would
  // stop for good. Two ordinary admin calls in the wrong order.
  {
    const dead = await factory.deploy(owner, ethers.ZeroAddress);
    await dead.waitForDeployment();
    eq('a ledger deployed with no anchorer starts at zero', Number(await dead.anchorerCount()), 0);
    await reverts('renouncing with no anchorer left is refused',
      dead.renounceOwnership(), 'NoAnchorerLeft');
    await dead.setAnchorer(owner, true);
    eq('adding one counts it', Number(await dead.anchorerCount()), 1);
    await dead.setAnchorer(owner, true);
    eq('adding the same one twice does not double count', Number(await dead.anchorerCount()), 1);
    await dead.setAnchorer(owner, false);
    eq('removing it counts down', Number(await dead.anchorerCount()), 0);
    await reverts('and renouncing is refused again', dead.renounceOwnership(), 'NoAnchorerLeft');
  }

  await c.renounceOwnership();
  eq('ownership renounced', await c.owner(), ethers.ZeroAddress);
  await reverts('no admin after renounce', c.setAnchorer(owner, true), 'NotOwner');
  // a fresh root: a root already anchored anywhere cannot be reused, so a
  // receipt can never verify in two different periods
  const later = buildTree(leaves.slice(0, 64).map((l) => l));
  await finish(G + 2n);
  // A root already used by a live epoch cannot be reused by another, so a
  // receipt can never be made to verify in two different periods.
  await reverts('a live root cannot be anchored twice', asAnchor.anchorEpoch(G + 2n, tree.root, N),
    'RootAlreadyAnchored');
  // A historical backfill does NOT reserve the root. Backfilling an hour and
  // then anchoring it live is ordinary operations, and reserving it there
  // would stop the sequence for good with no way to move the cursor.
  const backfill = buildTree(leaves.slice(200, 232));
  await asAnchor.anchorHistorical(backfill.root, 32, 1700000000, 1754000000);
  await (await asAnchor.anchorEpoch(G + 2n, backfill.root, 32)).wait();
  ok('a historical root does not block the same root going live',
    await c.isEpochAnchored(G + 2n));
  await finish(G + 3n);
  const after = await asAnchor.anchorEpoch(G + 3n, later.root, 64);
  await after.wait();
  eq('anchoring still works after renounce', await c.nextEpoch(), G + 4n);

  // ---------------- cost ----------------
  await finish(G + 4n);
  const warm = await (await asAnchor.anchorEpoch(G + 4n, buildTree(leaves.slice(0, 128)).root, 128)).wait();
  const gas = rc.gasUsed;
  results.push(['INFO', 'gas, first anchor (cold)', `${gas}`]);
  results.push(['INFO', 'gas, steady state anchor', `${warm.gasUsed}`]);
  const perYearHourly = warm.gasUsed * 8760n;
  const usd = (gwei) => (Number(perYearHourly) * gwei * 1e-9 * 600).toFixed(2);
  results.push(['INFO', 'hourly anchoring, gas per year', `${perYearHourly}`]);
  results.push(['INFO', 'cost per year @ 0.1 gwei', `$${usd(0.1)} (BNB 600)`]);
  results.push(['INFO', 'cost per year @ 1 gwei', `$${usd(1)} (BNB 600)`]);
  results.push(['INFO', 'cost per year, daily anchoring @ 1 gwei', `$${(Number(warm.gasUsed * 365n) * 1e-9 * 600).toFixed(2)}`]);
  results.push(['INFO', 'proof size for 1001 records', `${getProof(tree.levels, 0).length} hashes, ${getProof(tree.levels, 0).length * 32} bytes`]);

  // ---------------- report ----------------
  const width = Math.max(...results.map((r) => r[1].length));
  for (const [s, n, d] of results) {
    if (s === 'INFO') console.log(`  ..   ${n.padEnd(width)}  ${d}`);
    else console.log(`${s === 'PASS' ? '  ok ' : '  XX '} ${n.padEnd(width)}  ${d}`);
  }
  console.log(`\n${pass} passed, ${fail} failed`);
  if (fail) process.exit(1);
}

main().catch((e) => { console.error(e); process.exit(1); });
