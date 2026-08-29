// End to end: fake DB -> worker -> local chain -> receipt -> browser verify
const hre = require('hardhat');
const { ethers } = require('ethers');
const { runOnce, EPOCH_SECONDS, buildReceipt } = require('../lib/anchor');

const mk = (i, ts) => { const s = `seed-${i}`; return {
  gameId:'tint', roundId:`r-${String(i).padStart(6,'0')}`, playerRef:`u_${i%7}`,
  serverSeedHash: ethers.keccak256(ethers.toUtf8Bytes(s)), serverSeed:s,
  clientSeed:`c-${i}`, nonce:i, outcome:`solved:${i%9}moves`, timestamp:ts }; };

const toSkill = (r) => ({ gameId:r.gameId, roundId:r.roundId, playerRef:r.playerRef,
  mode:'campaign', level:(r.nonce%50)+1, score:r.nonce*7, durationMs:1000+r.nonce,
  outcome:'cleared', endedAt:r.timestamp });

(async () => {
  const provider = new ethers.BrowserProvider(hre.network.provider);
  const signer = await provider.getSigner(0);
  const owner = await signer.getAddress();
  // Deploy at a real wall clock time. The contract takes its origin from
  // block.timestamp, so the epoch numbers below are the ones a production
  // deployment would actually use. The earlier version of this test rebased
  // every timestamp to keep epochs at 0, 1, 2, which is precisely why it never
  // noticed that a real deployment started its cursor at zero.
  const now0 = (await provider.getBlock('latest')).timestamp;
  const base = now0 - (now0 % EPOCH_SECONDS) + EPOCH_SECONDS;
  await provider.send('evm_setNextBlockTimestamp', [base + 10]);
  await provider.send('evm_mine', []);

  const art = await hre.artifacts.readArtifact('HCOWLedger');
  const c = await new ethers.ContractFactory(art.abi, art.bytecode, signer).deploy(owner, owner);
  await c.waitForDeployment();
  const addr = await c.getAddress();

  const e0 = Number(await c.genesisEpoch());
  if (e0 !== Math.floor(base / EPOCH_SECONDS)) {
    console.log('genesisEpoch is not the deployment period', e0);
    process.exit(1);
  }

  // three epochs: 40 records, none, 7 records
  const db = [
    ...Array.from({length:40},(_,i)=>mk(i, base + 5 + i)),
    ...Array.from({length:7},(_,i)=>mk(100+i, base + 2*EPOCH_SECONDS + i)),
  ];
  const fetch2 = async (from,to) => db.filter(r=>r.timestamp>=from && r.timestamp<to)
                                      .sort((a,b)=>a.timestamp-b.timestamp || a.roundId.localeCompare(b.roundId));

  /** An epoch may only be anchored once its period has ended. */
  const finish = async (epoch) => {
    const endsAt = (epoch + 1) * EPOCH_SECONDS;
    const now = (await provider.getBlock('latest')).timestamp;
    if (now < endsAt) {
      await provider.send('evm_setNextBlockTimestamp', [endsAt + 1]);
      await provider.send('evm_mine', []);
    }
  };

  // The pure pieces are exercised directly against the deployed contract here.
  // runOnce's own control flow is driven separately, at the end of this file,
  // through the injectable `ledger` parameter. It used to build its own
  // JsonRpcProvider and be structurally unreachable from this harness, and the
  // comment that stood here claimed it was "covered by the same code paths",
  // which was false: the cursor guards, the catch-up cap, the empty and
  // all-quarantined paths, the ordering of the receipt record against the
  // confirmation, the error classification and the stall alarm were reached by
  // nothing.
  const { leafHash } = require('../lib/canonical');
  const { buildTree, getProof, EMPTY_PERIOD } = require('../lib/merkle');
  let fails = 0;

  for (let epoch = e0; epoch < e0 + 3; epoch++) {
    await finish(epoch);
    const recs = await fetch2(epoch*EPOCH_SECONDS, (epoch+1)*EPOCH_SECONDS);
    if (recs.length === 0) { await (await c.anchorEpoch(epoch, EMPTY_PERIOD, 0)).wait(); continue; }
    const leaves = recs.map((r,i)=> i%2 ? leafHash(r,'seeded') : leafHash(toSkill(r),'skill'));
    const t = buildTree(leaves);
    await (await c.anchorEpoch(epoch, t.root, leaves.length)).wait();

    for (let i = 0; i < recs.length; i++) {
      const kind = i%2 ? 'seeded' : 'skill';
      const rec  = i%2 ? recs[i] : toSkill(recs[i]);
      const receipt = buildReceipt(rec, kind, epoch, getProof(t.levels, i));
      const okChain = await c.verifyEpochRecord(receipt.epoch, leafHash(receipt.record, receipt.kind), receipt.proof);
      if (!okChain) { fails++; console.log('chain rejected a valid receipt', epoch, i); }
    }
    // a tampered outcome must fail
    const bad = { ...toSkill(recs[0]), outcome: 'tampered' };
    if (await c.verifyEpochRecord(epoch, leafHash(bad, 'skill'), getProof(t.levels, 0))) {
      fails++; console.log('chain accepted a tampered record', epoch);
    }
  }

  // ---- prepare(): quarantine must not shift the receipts ----
  // roundId does not identify a round; (game_id, round_id) does. Filtering the
  // receipts by roundId alone dropped a valid round in another game, shifted
  // every index after it, and handed players a proof belonging to somebody
  // else's record. The page then told them their receipt had been tampered
  // with. Nothing else in this suite reaches prepare().
  {
    const { prepare } = require('../lib/anchor');
    const { keccakUtf8 } = require('../lib/keccak');
    const seeded = (gameId, roundId, seed) => ({
      kind: 'seeded',
      record: {
        gameId, roundId, playerRef: 'p1',
        serverSeedHash: keccakUtf8(seed), serverSeed: seed,
        clientSeed: 'c', nonce: 1, outcome: 'win', timestamp: 1700000000,
      },
    });
    const broken = seeded('chroma', 'r-shared', 's1');
    broken.record.serverSeedHash = keccakUtf8('not-the-seed');
    const entries = [
      seeded('moon', 'a1', 'sa'),
      broken,                              // fails its own commitment
      seeded('chroma', 'r-shared', 'sb'),  // same roundId, different game, VALID
      seeded('moon', 'a2', 'sc'),
    ];

    let threw = false;
    try { prepare(entries); } catch (_) { threw = true; }
    if (!threw) { fails++; console.log('prepare did not refuse a broken commitment by default'); }

    const { leaves, quarantined, kept } = prepare(entries, { skipInvalid: true });
    if (leaves.length !== 3 || kept.length !== 3) {
      fails++; console.log('prepare kept the wrong number of entries', leaves.length, kept.length);
    }
    if (quarantined.length !== 1 || quarantined[0].gameId !== 'chroma') {
      fails++; console.log('quarantine list does not identify the round by game and id');
    }
    const t2 = buildTree(leaves);
    for (let i = 0; i < kept.length; i++) {
      if (leafHash(kept[i].record, kept[i].kind) !== leaves[i]) {
        fails++; console.log('kept[' + i + '] does not produce leaves[' + i + ']');
      }
    }
    // the valid round that shares a roundId with the quarantined one must be here
    if (!kept.some((e) => e.record.gameId === 'chroma' && e.record.roundId === 'r-shared')) {
      fails++; console.log('a valid round was dropped because another game reused its roundId');
    }
  }

  // an epoch whose period has not ended yet must be refused
  try {
    await (await c.anchorEpoch(e0 + 3, EMPTY_PERIOD, 0)).wait();
    fails++; console.log('chain anchored a period that has not finished');
  } catch (_) { /* expected: EpochNotFinished */ }

  // ---- assertLanded, the worker's only defence against a format disagreement
  //
  // It is reachable only through runOnce, which builds its own JsonRpcProvider
  // and cannot run in this harness, so it shipped once with no coverage at all.
  // Exported and driven directly here against the real deployed contract.
  //
  // The first version of it compared getEpoch().root against the value this
  // library computed, which is the same value on both sides and therefore says
  // nothing about the case it was written for. These four assertions are what
  // that version would have failed.
  {
    const { assertLanded } = require('../lib/anchor');
    const { buildTree: bt, getProof: gp, commit } = require('../lib/merkle');
    const leafOf = (x) => ethers.keccak256(ethers.toUtf8Bytes('landed-' + x));
    const good = bt([leafOf('a'), leafOf('b'), leafOf('c')]);
    const ep = Number(await c.nextEpoch());
    await finish(ep);
    await (await c.anchorEpoch(ep, good.root, 3)).wait();
    const sample = { leaf: good.levels[0][0], proof: gp(good.levels, 0) };

    let threw = false;
    try { await assertLanded(c, ep, good.root, 3, sample); } catch (e) { threw = true; }
    if (threw) { fails++; console.log('FAIL  assertLanded rejected a correct anchor'); }

    threw = false;
    try { await assertLanded(c, ep, good.root, 4, sample); } catch (_) { threw = true; }
    if (!threw) { fails++; console.log('FAIL  assertLanded accepted a wrong record count'); }

    threw = false;
    try { await assertLanded(c, ep, good.merkleRoot, 3, sample); } catch (_) { threw = true; }
    if (!threw) { fails++; console.log('FAIL  assertLanded accepted a wrong anchored value'); }

    // The one that matters: a worker running an older builder anchors the BARE
    // Merkle root, agrees with itself about it, and issues receipts the chain
    // rejects. Only the on-chain verification catches this.
    const ep2 = Number(await c.nextEpoch());
    await finish(ep2);
    await (await c.anchorEpoch(ep2, good.merkleRoot, 3)).wait();
    threw = false;
    try { await assertLanded(c, ep2, good.merkleRoot, 3, sample); } catch (_) { threw = true; }
    if (!threw) {
      fails++;
      console.log('FAIL  assertLanded accepted an anchor whose receipts the chain rejects');
    }
    if (commit(good.merkleRoot, 3) !== good.root) {
      fails++; console.log('FAIL  the anchored value is not the committed merkle root');
    }
  }

  // ---- runOnce itself ----
  {
    const { keccakUtf8 } = require('../lib/keccak');
    const { EMPTY_PERIOD: EP } = require('../lib/merkle');
    const seeded = (gameId, roundId, seed, ts) => ({
      kind: 'seeded',
      record: {
        gameId, roundId, playerRef: 'p1',
        serverSeedHash: keccakUtf8(seed), serverSeed: seed,
        clientSeed: 'c', nonce: 1, outcome: 'win', timestamp: ts,
      },
    });

    // ethers caches `latest` for its polling interval, and these scenarios move
    // the clock by hours between calls. A cached block reads as several hours
    // in the past and the next warp is rejected for going backwards, so ask the
    // node directly.
    const chainNow = async () => Number(
      (await hre.network.provider.send('eth_getBlockByNumber', ['latest', false])).timestamp);

    const fresh = async () => {
      const t = await chainNow();
      const b = t - (t % EPOCH_SECONDS) + EPOCH_SECONDS;
      await provider.send('evm_setNextBlockTimestamp', [b + 10]);
      await provider.send('evm_mine', []);
      const lg = await new ethers.ContractFactory(art.abi, art.bytecode, signer).deploy(owner, owner);
      await lg.waitForDeployment();
      return { lg, g: Number(await lg.genesisEpoch()) };
    };
    // The worker derives the period from the wall clock, so the clock it is
    // given has to be the chain's, not the host's.
    // Never warps backwards: hardhat refuses a timestamp below the previous
    // block's, and the scenarios below each move the clock several hours.
    const clockAfter = async (epoch) => {
      const nowTs = await chainNow();
      const target = Math.max((epoch + 1) * EPOCH_SECONDS + 5, nowTs + 1);
      await provider.send('evm_setNextBlockTimestamp', [target]);
      await provider.send('evm_mine', []);
      return target * 1000;
    };

    // 1. a normal run: one epoch with records, one empty
    {
      const { lg, g } = await fresh();
      const rows = { [g]: [seeded('tint', 'r1', 's1', g * EPOCH_SECONDS + 1),
                           seeded('tint', 'r2', 's2', g * EPOCH_SECONDS + 2)] };
      const nowMs = await clockAfter(g + 2);   // grace: E is closed once the clock is in E+2
      const r = await runOnce({
        ledger: lg, contract: await lg.getAddress(), confirmations: 1,
        now: () => nowMs, log: () => {},
        fetch: async (from) => rows[Math.floor(from / EPOCH_SECONDS)] || [],
      });
      if (!r.ok) { fails++; console.log('FAIL  runOnce did not report ok on a clean run', JSON.stringify(r.failed)); }
      if (r.epochs.length !== 2) { fails++; console.log('FAIL  runOnce anchored', r.epochs.length, 'epochs, expected 2'); }
      if (r.epochs.some((e) => e.status !== 'confirmed')) {
        fails++; console.log('FAIL  runOnce left an epoch unconfirmed on a clean run');
      }
      if (r.epochs[1].root.toLowerCase() !== EP.toLowerCase()) {
        fails++; console.log('FAIL  runOnce did not anchor the empty period as EMPTY_PERIOD');
      }
      const rec = r.epochs[0].receipts[0];
      if (!(await lg.verifyEpochRecord(rec.epoch, rec.leaf, rec.proof))) {
        fails++; console.log('FAIL  a receipt runOnce issued does not verify on chain');
      }
    }

    // 2. a wait that fails on an anchor that DID land must keep the receipts.
    //
    // This is the case the ordering inside runOnce exists for. The transaction
    // mines; the confirmation read throws. Before the fix the epoch was simply
    // omitted, and because the cursor comes from the chain the next run started
    // past it and those proofs were gone for good.
    {
      const { lg, g } = await fresh();
      const rows = { [g]: [seeded('tint', 'r1', 's1', g * EPOCH_SECONDS + 1)] };
      const nowMs = await clockAfter(g + 1);
      const liar = new Proxy(lg, {
        get(t, k) {
          if (k === 'anchorEpoch') {
            return async (...a) => {
              const tx = await t.anchorEpoch(...a);
              await tx.wait();                       // it really does land
              return { hash: tx.hash, wait: async () => { throw new Error('rpc timeout'); } };
            };
          }
          const v = t[k];
          return typeof v === 'function' ? v.bind(t) : v;
        },
      });
      const r = await runOnce({
        ledger: liar, contract: await lg.getAddress(), confirmations: 1,
        now: () => nowMs, log: () => {},
        fetch: async (from) => rows[Math.floor(from / EPOCH_SECONDS)] || [],
      });
      if (r.ok) { fails++; console.log('FAIL  runOnce reported ok despite a failed confirmation'); }
      if (r.epochs.length !== 1 || r.epochs[0].receipts.length !== 1) {
        fails++; console.log('FAIL  runOnce discarded the receipts of an anchor that landed');
      }
      if (r.unconfirmed.length !== 1) {
        fails++; console.log('FAIL  runOnce did not mark the epoch unconfirmed');
      }
      if (!r.failed) { fails++; console.log('FAIL  runOnce did not report which epoch it stopped on'); }
      // and the anchor really is on chain, which is why the receipts matter
      if (Number(await lg.nextEpoch()) !== g + 1) {
        fails++; console.log('FAIL  the harness did not actually land the anchor');
      }
    }

    // 3. a deterministic failure raises the stall alarm, in ONE process.
    //
    // The counter used to be the only signal and it lives in module scope,
    // while the runbook is a fresh process every hour, so it could never reach
    // two and the alarm was unreachable in production. The lag signal is
    // derived from chain state and does not care how many processes have run.
    {
      const { lg, g } = await fresh();
      const nowMs = await clockAfter(g + 4);
      const r = await runOnce({
        ledger: lg, contract: await lg.getAddress(), confirmations: 1,
        now: () => nowMs, log: () => {},
        fetch: async () => { throw new Error('database unreachable'); },
      });
      if (!r.stalled) {
        fails++; console.log('FAIL  runOnce did not raise the stall alarm on a cursor five periods behind');
      } else if (r.stalled.periodsOverdue < 2) {
        fails++; console.log('FAIL  the stall alarm reported the wrong lag', r.stalled.periodsOverdue);
      }
      if (r.ok) { fails++; console.log('FAIL  runOnce reported ok on a stalled run'); }
    }

    // 4. a single transient failure at the boundary is NOT a stall, or the one
    //    alarm that matters gets ignored.
    {
      const { lg, g } = await fresh();
      const nowMs = await clockAfter(g + 1);
      const r = await runOnce({
        ledger: lg, contract: await lg.getAddress() + '#transient', confirmations: 1,
        now: () => nowMs, log: () => {},
        fetch: async () => { throw new Error('rpc hiccup'); },
      });
      if (r.stalled) { fails++; console.log('FAIL  a first failure at the boundary was called a stall'); }
      if (!r.failed) { fails++; console.log('FAIL  a first failure was not reported at all'); }
    }

    // 6. the grace period: an epoch that has only just ended is NOT closed yet.
    //
    // A round is stamped with the epoch its request fell in and appears when
    // its insert commits, so one arriving at the very end of an epoch can land
    // after the worker has read that epoch. An anchored epoch can never be
    // reopened and the table is append only, so such a round would be
    // unanchorable forever.
    {
      const { lg, g } = await fresh();
      const nowMs = await clockAfter(g);        // the clock is in g+1, so g just ended
      let called = false;
      const r = await runOnce({
        ledger: lg, contract: await lg.getAddress(), confirmations: 1,
        now: () => nowMs, log: () => {},
        fetch: async () => { called = true; return []; },
      });
      if (r.epochs.length !== 0 || called) {
        fails++;
        console.log('FAIL  the worker closed an epoch that had only just ended, with no grace at all');
      }
      if (Number(await lg.nextEpoch()) !== g) {
        fails++; console.log('FAIL  the cursor moved during the grace period');
      }
    }

    // 5. quarantined rounds are surfaced with their epoch, so the caller can
    //    publish the exclusion list the no-holes claim depends on.
    {
      const { lg, g } = await fresh();
      const broken = seeded('tint', 'bad', 's1', g * EPOCH_SECONDS + 1);
      broken.record.serverSeedHash = keccakUtf8('not-the-seed');
      const rows = { [g]: [broken, seeded('tint', 'ok', 's2', g * EPOCH_SECONDS + 2)] };
      const nowMs = await clockAfter(g + 1);
      const r = await runOnce({
        ledger: lg, contract: await lg.getAddress(), confirmations: 1, skipInvalid: true,
        now: () => nowMs, log: () => {},
        fetch: async (from) => rows[Math.floor(from / EPOCH_SECONDS)] || [],
      });
      if (r.quarantined.length !== 1 || r.quarantined[0].roundId !== 'bad') {
        fails++; console.log('FAIL  runOnce did not surface the quarantined round');
      }
      if (r.quarantined[0] && r.quarantined[0].epoch !== g) {
        fails++; console.log('FAIL  the quarantined round does not name the epoch it was excluded from');
      }
      if (r.epochs[0].count !== 1) {
        fails++; console.log('FAIL  the quarantined round was anchored anyway');
      }
    }
  }

  // ---- makeSupabaseFetch: a short page is not the end of the data ----
  //
  // The loop stopped on `rows.length < pageSize`, which assumes the server
  // honours the requested limit. PostgREST enforces its own db-max-rows
  // independently, so with that set below pageSize every page comes back short,
  // the loop stops on the first one, and the hour is anchored over a truncated
  // record set with no error anywhere. Nothing in this repository controls that
  // setting. Both halves are asserted: the paging has to keep going, and the
  // Content-Range total has to catch a page that drops rows without shortening.
  {
    const { makeSupabaseFetch } = require('../lib/anchor');
    const { keccakUtf8 } = require('../lib/keccak');
    const row = (id) => ({
      id, kind: 'seeded', game_id: 'tint', round_id: `r-${id}`, player_ref: 'p1',
      server_seed_hash: keccakUtf8(`s${id}`), server_seed: `s${id}`,
      client_seed: 'c', nonce: 1, outcome: 'win', ended_at: 1700000000 + id,
    });
    const ALL = Array.from({ length: 25 }, (_, i) => row(i + 1));
    const realFetch = global.fetch;

    // a server that caps every page at 4 rows while the client asked for 10.
    // `total` of null models a deployment that does not return Content-Range,
    // which is the case where the paging loop is the ONLY thing standing
    // between a capped page and a permanently truncated hour.
    const capped = (cap, total) => async (url) => {
      const u = new URL(url);
      const after = Number((u.searchParams.get('id') || 'gt.0').slice(3));
      const page = ALL.filter((r) => r.id > after).slice(0, cap);
      return {
        ok: true,
        headers: { get: (h) => (total !== null && h.toLowerCase() === 'content-range' ? `0-0/${total}` : null) },
        json: async () => page,
      };
    };

    global.fetch = capped(4, null);
    try {
      const f = makeSupabaseFetch({ url: 'https://x.invalid', serviceKey: 'k', pageSize: 10 });
      const got = await f(0, 9_999_999_999);
      if (got.length !== ALL.length) {
        fails++;
        console.log(`FAIL  a server that caps pages below the requested limit truncated the hour: ${got.length} of ${ALL.length}`);
      }
    } finally { global.fetch = realFetch; }

    // and a page that silently drops rows without shortening is caught by the
    // count the database itself reports
    global.fetch = capped(4, ALL.length + 3);
    try {
      const f = makeSupabaseFetch({ url: 'https://x.invalid', serviceKey: 'k', pageSize: 10 });
      let threw = false;
      try { await f(0, 9_999_999_999); } catch (_) { threw = true; }
      if (!threw) {
        fails++;
        console.log('FAIL  a read that assembled fewer rows than the database reports was accepted');
      }
    } finally { global.fetch = realFetch; }
  }

  console.log('epochs anchored:', Number(await c.nextEpoch()) - e0, 'from genesis', e0);
  console.log('records on chain:', String(await c.totalRecords()));
  console.log(fails === 0 ? 'end to end OK: 47 receipts verified, tampering rejected' : `FAILURES: ${fails}`);
  process.exit(fails ? 1 : 0);
})();
