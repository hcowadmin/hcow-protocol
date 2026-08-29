'use strict';
/* Run: npx hardhat run test/ledger.test.cjs */

const hre = require('hardhat');
const { ethers } = require('ethers');
const { leafHash, canonicalize, seedCommitmentValid, RecordError, KINDS,
        escape, unescape, decanonicalize } = require('../lib/canonical');
const { buildTree, getProof, verifyProof, commit, EMPTY_PERIOD, EMPTY_LEAF } = require('../lib/merkle');

let pass = 0, fail = 0;
const results = [];

function ok(name, cond, detail) {
  if (cond) { pass++; results.push(['PASS', name, '']); }
  else {
    fail++;
    results.push(['FAIL', name, detail || '']);
    // Printed as it happens, not only in the report at the end. A suite with
    // sequential dependencies dies on the first unexpected revert, and when it
    // does the report never prints and every failure before it is invisible.
    console.log(`  FAIL  ${name}  ${detail || ''}`);
  }
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
      // The in-process node has been observed handing back a stale `latest`,
      // so a timestamp that this read says is in the future can already be in
      // the past by the time it is set. That is not a failure: the period has
      // finished either way, which is all this helper is for.
      try { await provider.send('evm_setNextBlockTimestamp', [endsAt + 1]); }
      catch (e) { if (!/lower than the previous block/.test(e.message || '')) throw e; }
      await provider.send('evm_mine', []);
    }
  };

  /**
   * An explicit gas limit, used where ethers would otherwise estimate.
   *
   * The in-process node's eth_estimateGas has been observed evaluating against
   * state the chain has already moved past: a call that eth_call accepts is
   * refused by the estimator with the error the previous state would have
   * produced. The estimate is therefore not a usable oracle here. Where a call
   * is expected to succeed, the gas is supplied and the outcome is read from
   * the mined receipt; where it is expected to revert, `reverts` uses eth_call,
   * which is correct.
   */
  const GAS = { gasLimit: 400_000 };
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

  // ---------------- the escaping is invertible ----------------
  //
  // The leaf preimage joins nine fields with tabs, and abi.encodePacked over
  // adjacent variable-length operands is ambiguous unless the boundary is
  // recoverable. The argument that it is recoverable here has two halves: no
  // escaped field can contain a raw tab or newline, so the delimiters are
  // exactly the field boundaries; and the escaping is injective. The second
  // half is only credible with an explicit decoder, so lib/canonical.js ships
  // one and these assertions are it being exercised rather than asserted.
  {
    const fixed = ['', 'a', '\\', '\\t', '\t', '\n', 'a\\tb', 'a\tb\nc\\d',
                   '\\'.repeat(9), 'e\u0301 \u4e2d \ud83d\ude42', '\u0000x', 'tn\\\\tn'];
    let bad = 0;
    for (const x of fixed) if (unescape(escape(x)) !== x) { bad++; console.log('  fixed:', JSON.stringify(x)); }
    // and over random strings drawn from the alphabet that matters: the escape
    // character, the two delimiters, their escape letters, ordinary text,
    // multibyte text, a surrogate pair and the codepoints that break naive
    // line handling.
    //
    // The previous version of this loop ran 20,000 iterations over 97 DISTINCT
    // inputs. The string was `alphabet[(i * 7 + j * 3) % 8]` for `j < i % 13`,
    // so it was a function of `i mod 104` and nothing else: 97 strings of at
    // most twelve characters, repeated two hundred times each, described in
    // the comment as "random byte strings". Any defect needing a length above
    // twelve or a character outside that alphabet was invisible, and the
    // iteration count was quoted in SECURITY.md as evidence of coverage it did
    // not provide. A seeded generator now produces genuinely distinct inputs
    // and the test asserts how many, so the number cannot drift back.
    const alphabet = ['\\', '\t', '\n', 't', 'n', 'A', 'z', ' ', '\u00e9', '\u4e2d',
                      '\u{1f42e}', '\u007f', '\u00a0', '\u2028', '\u0301'];
    // xorshift32, so the sequence is reproducible and a failure is replayable
    let seed = 0x9e3779b9;
    const rnd = () => {
      seed ^= seed << 13; seed >>>= 0;
      seed ^= seed >>> 17;
      seed ^= seed << 5;  seed >>>= 0;
      return seed;
    };
    const seen = new Set();
    for (let i = 0; i < 20_000; i++) {
      const n = rnd() % 40;
      let x = '';
      for (let j = 0; j < n; j++) x += alphabet[rnd() % alphabet.length];
      seen.add(x);
      if (unescape(escape(x)) !== x) { bad++; console.log('  random:', JSON.stringify(x)); break; }
    }
    ok('the escaping is invertible on every input tried', bad === 0, `${bad} failures`);
    // Not 20,000: n is uniform on [0, 40), so about one draw in forty is the
    // empty string and the very short ones collide by birthday. Measured
    // 18,724. The threshold is there to catch the old shape, where the count
    // was 97, not to demand perfect uniqueness.
    ok('and the inputs tried are actually distinct, not one hundred strings repeated',
       seen.size > 18_000, `${seen.size} distinct of 20,000`);
    ok('and the canonical form splits back into its nine fields',
       decanonicalize(canonicalize(record({ outcome: 'a\tb\nc\\d' }), 'seeded')).length === 9);
    eq('with the original value recovered',
       decanonicalize(canonicalize(record({ outcome: 'a\tb\nc\\d' }), 'seeded'))[7],
       'a\tb\nc\\d');
    // an escape the encoder never emits must not decode silently
    let threw = false;
    try { unescape('a\\q'); } catch (_) { threw = true; }
    ok('an impossible escape sequence is refused rather than guessed', threw);
  }

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
  eq('single leaf merkle root equals leaf', one.merkleRoot, leafHash(r1,'seeded').toLowerCase());
  eq('and the anchored value binds the count to it', one.root, commit(one.merkleRoot, 1));
  eq('the js empty period constant matches the contract', EMPTY_PERIOD, await c.EMPTY_PERIOD());

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
    if (!verifyProof(leaves[i], getProof(tree.levels, i), tree.root, N)) { allJs = false; break; }
  }
  ok(`js verifies all ${N} proofs`, allJs);
  ok('proof depth is logarithmic', getProof(tree.levels, 0).length <= 11,
     `depth ${getProof(tree.levels, 0).length}`);

  // ---------------- the hashing rule is readable off the chain ----------------
  // Publishing only the domain tags was half the rule. A verifier that knows
  // the tag but not the field order, the separator or the escaping cannot
  // reproduce a leaf, so it had to trust our JavaScript, which is the one
  // thing a proof exists to make unnecessary. These assertions are what stop
  // the published rule and the implementation drifting apart.
  eq('seeded domain on chain matches the library', await c.LEAF_DOMAIN_SEEDED(), KINDS.seeded.domain);
  eq('skill domain on chain matches the library', await c.LEAF_DOMAIN_SKILL(), KINDS.skill.domain);
  eq('seeded field order on chain matches the library',
     await c.FIELDS_SEEDED(), KINDS.seeded.fields.join(','));
  eq('skill field order on chain matches the library',
     await c.FIELDS_SKILL(), KINDS.skill.fields.join(','));
  ok('the rule names the separator, the terminator and the escaping',
     /0x09/.test(await c.LEAF_RULE()) && /0x0a/.test(await c.LEAF_RULE())
       && /escape/.test(await c.LEAF_RULE()));
  ok('the tree rule names the padding, the node rule and the count fold',
     /EMPTY_LEAF/.test(await c.TREE_RULE()) && /0x01/.test(await c.TREE_RULE())
       && /0x02/.test(await c.TREE_RULE()));
  eq('the js filler leaf matches the contract', EMPTY_LEAF, await c.EMPTY_LEAF());

  // The rule as executable code, not as prose. A verifier that knows the domain
  // tag but not the field order, the separator or the escaping still has to
  // take the rest from a document or from our JavaScript, which is the one
  // thing a proof exists to make unnecessary. These compare the chain's own
  // answer against lib/canonical.js on the awkward inputs.
  {
    const asFields = (rec, kind) =>
      KINDS[kind].fields.map((f) => String(rec[f]));
    const cases = [
      ['plain', record({}), 'seeded'],
      ['a tab inside a value', record({ outcome: 'win\t2x' }), 'seeded'],
      ['a newline inside a value', record({ outcome: 'a\nb' }), 'seeded'],
      ['a backslash inside a value', record({ outcome: 'a\\b' }), 'seeded'],
      ['all three at once', record({ outcome: 'a\\b\tc\nd' }), 'seeded'],
      ['a value that is only escapes', record({ clientSeed: '\\\\\\t\\n' }), 'seeded'],
    ];
    let bad = 0;
    for (const [name, rec, kind] of cases) {
      const onChain = await c.leafSeeded(asFields(rec, kind));
      if (onChain.toLowerCase() !== leafHash(rec, kind).toLowerCase()) {
        bad++; console.log('  leaf mismatch:', name, onChain, leafHash(rec, kind));
      }
    }
    ok('the chain computes the same seeded leaf as the library, escaping included',
       bad === 0, `${bad} mismatches`);

    const sk = skill({ roundId: 'r-esc', score: 4242, endedAt: 1755000123 });
    eq('and the same skill leaf',
       (await c.leafSkill(asFields(sk, 'skill'))).toLowerCase(),
       leafHash(sk, 'skill').toLowerCase());

    // and the escaping is genuinely applied on chain rather than skipped.
    // Built here is what the leaf would be if a tab in a value were written
    // straight through: the chain must not produce it, or a value could carry a
    // delimiter into the canonical form.
    {
      const rec = record({ outcome: 'win\t2x' });
      const raw = ethers.keccak256(ethers.toUtf8Bytes(
        KINDS.seeded.domain + KINDS.seeded.fields.map((f) => String(rec[f])).join('\t') + '\n'));
      const onChain = await c.leafSeeded(asFields(rec, 'seeded'));
      ok('a tab inside a value is escaped on chain, not written through',
         onChain.toLowerCase() !== raw.toLowerCase());
      eq('and the escaped form is the one the library produces',
         onChain.toLowerCase(), leafHash(rec, 'seeded').toLowerCase());
    }
  }

  // ---------------- anchoring rules ----------------
  await reverts('stranger cannot anchor', asStranger.anchorEpoch(G, tree.root, N), 'NotAnchorer');
  await reverts('epoch must be sequential', asAnchor.anchorEpoch(G + 5n, tree.root, N), 'WrongEpoch');
  await reverts('root without records rejected', asAnchor.anchorEpoch(G, tree.root, 0), 'RootWithoutRecords');
  await reverts('records without root rejected',
    asAnchor.anchorEpoch(G, ethers.ZeroHash, 5), 'RecordsWithoutRoot');
  // A zero root is what an unanchored epoch reads as, so it is no longer
  // accepted as an attestation of anything, empty periods included.
  await reverts('a zero root is not an empty period attestation',
    asAnchor.anchorEpoch(G, ethers.ZeroHash, 0), 'RecordsWithoutRoot');
  await reverts('an empty period cannot claim records',
    asAnchor.anchorEpoch(G, EMPTY_PERIOD, 3), 'EmptyPeriodWithRecords');

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

  await reverts('cannot rewrite an anchored epoch', asAnchor.anchorEpoch(G, EMPTY_PERIOD, 0), 'WrongEpoch');

  // empty period still occupies its slot, so the chain has no hole
  await finish(G + 1n);
  await asAnchor.anchorEpoch(G + 1n, EMPTY_PERIOD, 0);
  eq('empty epoch anchored', await c.nextEpoch(), G + 2n);
  eq('empty epoch adds no records', await c.totalLiveRecords(), N);
  ok('an empty period reads as attested, not as absent', await c.isEmptyPeriod(G + 1n));
  ok('a period with records is not an empty period', !(await c.isEmptyPeriod(G)));
  ok('an epoch that was never anchored is not an empty period', !(await c.isEmptyPeriod(G + 50n)));

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
  // The filler sits at leaf depth, so its proof has exactly the right length
  // and it would otherwise verify in every tree whose leaf count is not a power
  // of two. Nothing is exploitable through it, because no record preimage can
  // hash to it, but a caller reading `true` as "these 32 bytes are a committed
  // record" would be wrong. N is 1001, so index N is the first padding slot.
  eq('the js filler is what the tree pads with', tree.levels[0][N], EMPTY_LEAF);
  ok('the padding filler cannot be presented as a record',
    !(await c.verifyEpochRecord(G, EMPTY_LEAF, getProof(tree.levels, N))));
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

  {
    // A backfill covers time before this contract existed, by definition. Left
    // bounded at "now" instead, a backfill could claim hours the live path has
    // already anchored and the same records counted twice across the two
    // totals. It is also what stops one anchorer transaction pushing the
    // backfill horizon to the present and locking out every genuine archive.
    const genesisStart = Number(await c.genesisEpoch()) * 3600;
    await reverts('a backfill cannot reach into time the live path covers',
      asAnchor.anchorHistorical(hist.root, 300, genesisStart - 10, genesisStart),
      'BackfillCoversLiveTime');
    await reverts('nor into the present',
      asAnchor.anchorHistorical(hist.root, 300, genesisStart - 10, genesisStart + 100000),
      'BackfillCoversLiveTime');
  }
  await asAnchor.anchorHistorical(hist.root, 300, 1700000000, 1754000000);
  eq('historical batch recorded', await c.historicalBatchCount(), 1);
  eq('historical records counted', await c.totalHistoricalRecords(), 300);
  eq('totalRecords sums both', await c.totalRecords(), N + 300);
  ok('historical verify works',
    await c.verifyHistoricalRecord(0, leaves[10], getProof(hist.levels, 10)));
  ok('historical verify rejects out of batch record',
    !(await c.verifyHistoricalRecord(0, leaves[999], getProof(tree.levels, 999))));
  // The trigger the finding names is an ordinary retry after a dropped
  // connection, which resubmits the identical batch. The identical batch has
  // the identical root. Measured on the previous code: one 300 record batch
  // submitted ten times reported 3,000 records.
  await reverts('the same backfill cannot be anchored twice',
    asAnchor.anchorHistorical(hist.root, 300, 1700000000, 1754000000), 'RootAlreadyAnchored');
  await reverts('nor under a different range',
    asAnchor.anchorHistorical(hist.root, 300, 1600000000, 1610000000), 'RootAlreadyAnchored');
  eq('and none of the refused attempts moved the total',
    await c.totalHistoricalRecords(), 300);

  {
    // Out of order and overlapping ranges are both accepted, deliberately. An
    // older archive is routinely discovered after a newer one, and two games'
    // histories genuinely overlap in calendar time while containing entirely
    // different records. An earlier version forbade both. That made them
    // impossible forever, handed a stolen anchorer key a one transaction
    // irreversible denial of all future backfill, and the owner-only escape
    // hatch added to relieve it re-opened the very double count the rule
    // existed to prevent: measured, the same 50,000 records published as
    // 100,000 by an owner that had granted itself the anchorer role.
    const older = buildTree(leaves.slice(340, 380));
    await (await asAnchor.anchorHistorical(older.root, 40, 1650000000, 1660000000)).wait();
    eq('an older archive discovered later still anchors', await c.historicalBatchCount(), 2);
    const overlapping = buildTree(leaves.slice(380, 420));
    await (await asAnchor.anchorHistorical(overlapping.root, 40, 1690000000, 1740000000)).wait();
    eq('and a second source whose range overlaps the first does too',
      await c.historicalBatchCount(), 3);
    eq('each counted once', await c.totalHistoricalRecords(), 380);
  }

  {
    // WHAT IS NOT PREVENTED, asserted rather than left to be discovered. A tree
    // rebuilt over the same rounds is a different root over the same period and
    // the contract accepts it, because it has no independent view of the record
    // set. totalHistoricalRecords is a figure the anchorer asserts, exactly as
    // a single batch's declared recordCount is, and it must be published as
    // such rather than as something the chain proves.
    const rebuilt = buildTree(leaves.slice(0, 301));
    const before = await c.totalHistoricalRecords();
    await (await asAnchor.anchorHistorical(rebuilt.root, 301, 1700000000, 1754000000)).wait();
    eq('a rebuilt tree over a covered period is accepted, and the total is a claim',
      await c.totalHistoricalRecords(), Number(before) + 301);
  }

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
  await reverts('owner cannot rewrite either', c.anchorEpoch(G, EMPTY_PERIOD, 0), 'WrongEpoch');
  eq('root unchanged after admin activity', (await c.getEpoch(G)).root, before);

  // Renouncing with nobody left who can anchor is unrecoverable: epochs are
  // strictly sequential and there is no cursor override, so the ledger would
  // stop for good. Two ordinary admin calls in the wrong order.
  {
    const dead = await factory.deploy(owner, ethers.ZeroAddress);
    await dead.waitForDeployment();
    eq('a ledger deployed with no anchorer starts at zero', Number(await dead.anchorerCount()), 0);
    await reverts('renouncing with no anchorer left is refused',
      dead.renounceOwnership(), 'NotEnoughProvenAnchorers');
    await dead.setAnchorer(owner, true);
    eq('adding one counts it', Number(await dead.anchorerCount()), 1);
    await dead.setAnchorer(owner, true);
    eq('adding the same one twice does not double count', Number(await dead.anchorerCount()), 1);
    await dead.setAnchorer(owner, false);
    eq('removing it counts down', Number(await dead.anchorerCount()), 0);
    await reverts('and renouncing is refused again', dead.renounceOwnership(), 'NotEnoughProvenAnchorers');
  }

  // The old guard counted configured anchorers. Any address the owner typed in
  // satisfied it, including one nobody holds the key to, so the guard could be
  // passed while leaving exactly the dead ledger it exists to prevent. An
  // anchorer now counts only once it has actually written to the contract.
  {
    const unheld = await factory.deploy(owner, '0x' + 'ab'.repeat(20));
    await unheld.waitForDeployment();
    eq('an unheld address is configured as an anchorer', Number(await unheld.anchorerCount()), 1);
    eq('but it has proven nothing', Number(await unheld.provenAnchorerCount()), 0);
    await reverts('renouncing to an address that never anchored is refused',
      unheld.renounceOwnership(), 'NotEnoughProvenAnchorers');
  }

  // and once a key holder has anchored, renouncing is allowed. A separate
  // deployment on purpose: if the guard above were ever weakened, the contract
  // in that block is left ownerless and every call after it reverts, which
  // would kill the process before the report is printed.
  {
    const proven = await factory.deploy(owner, '0x' + 'ab'.repeat(20));
    await proven.waitForDeployment();
    await proven.setAnchorer(await anchorS.getAddress(), true);
    const gen = await proven.genesisEpoch();
    await finish(gen);
    await (await proven.connect(anchorS).anchorEpoch(gen, EMPTY_PERIOD, 0)).wait();
    eq('anchoring proves control', Number(await proven.provenAnchorerCount()), 1);

    // ONE proven anchorer is not enough. After renouncement setAnchorer is
    // gone forever, so a single key is a single point of permanent failure in
    // both directions: lose it and the ledger can never advance again, with no
    // owner to grant a replacement; have it stolen and the thief anchors a
    // false root for every future epoch with nobody able to revoke it. A log
    // that still looks authoritative while an attacker writes it is worse than
    // one that has stopped.
    eq('the permanent minimum is two', Number(await proven.MIN_ANCHORERS_TO_RENOUNCE()), 2);
    await reverts('one proven anchorer is not enough to renounce',
      proven.renounceOwnership(), 'NotEnoughProvenAnchorers');

    await proven.setAnchorer(await strangerS.getAddress(), true);
    await reverts('and merely configuring a second does not help',
      proven.renounceOwnership(), 'NotEnoughProvenAnchorers');
    await finish(gen + 1n);
    await (await proven.connect(strangerS).anchorEpoch(gen + 1n, EMPTY_PERIOD, 0)).wait();
    eq('the second one proving control does', Number(await proven.provenAnchorerCount()), 2);
    await (await proven.renounceOwnership(GAS)).wait();
    eq('and renouncing is then allowed', await proven.owner(), ethers.ZeroAddress);

    // An anchorer can burn its own key after renouncement. This is the only
    // path left once setAnchorer is gone, and only the key holder can walk it:
    // an attacker holding the key gains nothing by burning it, and the
    // legitimate holder who knows it is compromised can stop it writing.
    await reverts('a stranger cannot revoke an anchorer it does not hold',
      proven.connect(ownerS).revokeSelf(), 'NotAnchorer');
    await (await proven.connect(strangerS).revokeSelf(GAS)).wait();
    ok('an anchorer can revoke itself after renouncement',
       !(await proven.isAnchorer(await strangerS.getAddress())));
    eq('and the proven count falls', Number(await proven.provenAnchorerCount()), 1);

    // but it cannot be turned into the denial it exists to prevent
    await reverts('the last proven anchorer cannot revoke itself',
      proven.connect(anchorS).revokeSelf(), 'NoAnchorerLeft');
    await finish(gen + 2n);
    await (await proven.connect(anchorS).anchorEpoch(gen + 2n, EMPTY_PERIOD, 0)).wait();
    eq('so an ownerless ledger always keeps a live writer', await proven.nextEpoch(), gen + 3n);
  }

  // Proof of control must not survive removal. Left set, re-adding an address
  // that anchored once in the past would restore the proven count without
  // anyone proving anything, and the renounce guard would pass on a key that
  // was rotated out months earlier. The guard is meant to evidence a live key.
  {
    const stale = await factory.deploy(owner, await anchorS.getAddress());
    await stale.waitForDeployment();
    const gen = await stale.genesisEpoch();
    await finish(gen);
    await (await stale.connect(anchorS).anchorEpoch(gen, EMPTY_PERIOD, 0)).wait();
    eq('the anchorer proved control', Number(await stale.provenAnchorerCount()), 1);

    await (await stale.setAnchorer(await anchorS.getAddress(), false)).wait();
    eq('removing it drops the proof', Number(await stale.provenAnchorerCount()), 0);
    ok('and clears the flag', !(await stale.hasAnchored(await anchorS.getAddress())));

    await (await stale.setAnchorer(await anchorS.getAddress(), true)).wait();
    eq('re-adding it does not resurrect the proof',
       Number(await stale.provenAnchorerCount()), 0);
    await reverts('so renouncing is still refused until it anchors again',
      stale.renounceOwnership(), 'NotEnoughProvenAnchorers');

    await finish(gen + 1n);
    await (await stale.connect(anchorS).anchorEpoch(gen + 1n, EMPTY_PERIOD, 0)).wait();
    eq('anchoring again re-proves it', Number(await stale.provenAnchorerCount()), 1);
    await stale.setAnchorer(await strangerS.getAddress(), true);
    await finish(gen + 2n);
    await (await stale.connect(strangerS).anchorEpoch(gen + 2n, EMPTY_PERIOD, 0)).wait();
    let renounced = true;
    try { await (await stale.renounceOwnership(GAS)).wait(); } catch { renounced = false; }
    ok('and renouncing is allowed once two are proven', renounced);
  }

  // Ownership moves in two steps. A single step wrote the address
  // immediately, so a mistyped or unreachable one ended administration for
  // good, with no way to add or remove an anchorer ever again.
  {
    const two = await factory.deploy(owner, await anchorS.getAddress());
    await two.waitForDeployment();
    const stranger = await strangerS.getAddress();
    await reverts('a stranger cannot start a transfer',
      two.connect(strangerS).transferOwnership(stranger), 'NotOwner');
    await (await two.transferOwnership(stranger)).wait();
    eq('the owner does not change on the first step', await two.owner(), owner);
    eq('the nominee is recorded', await two.pendingOwner(), stranger);
    await reverts('only the nominee can accept',
      two.connect(anchorS).acceptOwnership(), 'NotPendingOwner');
    await (await two.connect(strangerS).acceptOwnership()).wait();
    eq('the nominee becomes the owner on the second step', await two.owner(), stranger);
    eq('and the nomination is cleared', await two.pendingOwner(), ethers.ZeroAddress);
    await reverts('the old owner has no powers left',
      two.setAnchorer(stranger, true), 'NotOwner');
    // a nomination that is never accepted leaves the owner in place
    await (await two.connect(strangerS).transferOwnership(owner)).wait();
    eq('an unaccepted nomination does not move the owner', await two.owner(), stranger);
  }

  // The main deployment needs a second proven anchorer before it can renounce.
  //
  // Proven through a BACKFILL rather than a live epoch, so this does not
  // consume a cursor position the assertions below depend on. Any successful
  // anchor proves the key, live or historical.
  await c.setAnchorer(await strangerS.getAddress(), true);
  {
    const second = buildTree(leaves.slice(420, 460));
    await (await c.connect(strangerS)
      .anchorHistorical(second.root, 40, 1600000000, 1605000000)).wait();
  }
  eq('two anchorers have proven control', Number(await c.provenAnchorerCount()), 2);
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
  await asAnchor.anchorHistorical(backfill.root, 32, 1690000000, 1695000000);
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
