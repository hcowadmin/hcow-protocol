'use strict';
/**
 * Anchor worker.
 *
 * Runs on a schedule. For each period it has not yet anchored, it pulls the
 * rounds that settled in that period, hashes them, builds the tree, writes
 * the root on chain, and stores the proofs so a player can be handed a
 * receipt later.
 *
 * The canonical form and the tree shape are fixed by the spec. Changing
 * either invalidates every receipt ever issued.
 */

const { ethers } = require('ethers');
const { leafHash, seedCommitmentValid, recordTime, KINDS, RecordError } = require('./canonical');
const { buildTree, getProof, verifyProof, EMPTY_PERIOD } = require('./merkle');

const ABI = [
  'function nextEpoch() view returns (uint64)',
  'function genesisEpoch() view returns (uint64)',
  'function anchorEpoch(uint64 epoch, bytes32 root, uint64 recordCount)',
  'function getEpoch(uint64 epoch) view returns (tuple(bytes32 root, uint64 recordCount, uint64 anchoredAt))',
  'function verifyEpochRecord(uint64 epoch, bytes32 leaf, bytes32[] proof) view returns (bool)',
  'function anchorHistorical(bytes32 root, uint64 recordCount, uint64 coversFrom, uint64 coversTo) returns (uint64)',
];

const EPOCH_SECONDS = 3600; // one anchor per hour

const epochStart = (epoch) => epoch * EPOCH_SECONDS;
const epochEnd = (epoch) => (epoch + 1) * EPOCH_SECONDS;

/** Database column names to record field names. */
const COLUMNS = {
  skill: {
    game_id: 'gameId', round_id: 'roundId', player_ref: 'playerRef',
    mode: 'mode', level: 'level', score: 'score', duration_ms: 'durationMs',
    outcome: 'outcome', ended_at: 'endedAt',
  },
  seeded: {
    game_id: 'gameId', round_id: 'roundId', player_ref: 'playerRef',
    server_seed_hash: 'serverSeedHash', server_seed: 'serverSeed',
    client_seed: 'clientSeed', nonce: 'nonce',
    outcome: 'outcome', ended_at: 'timestamp',
  },
};

/**
 * Most periods a single run will attempt. A long outage is drained across
 * successive runs rather than refused: refusing would mean a system that has
 * been idle for a month can never start again.
 */
const MAX_CATCHUP_EPOCHS = 24 * 30;

/**
 * Consecutive failures of the same epoch before the run reports a stall.
 * One failure is a transient; the same epoch failing again is deterministic,
 * and because epochs are strictly sequential a deterministic failure stops the
 * ledger for good.
 */
const STALL_AFTER = 2;

/**
 * Confirmations to wait for before treating an anchor as landed.
 *
 * `tx.wait()` with no argument waits for ONE, and a one-confirmation reorg on
 * BSC would leave this worker reporting an anchor that is no longer on chain.
 * The next run re-anchors from the database, and if any row arrived for that
 * hour in the interim the new root does not match the receipts already handed
 * out. Three is cheap at an hourly cadence.
 */
const CONFIRMATIONS = 3;

/**
 * Periods of slack between a period ending and this worker closing it.
 *
 * See the comment at `closeable` in runOnce. In short: rounds are stamped by
 * the edge function's clock and appear when their insert commits, so a request
 * made in the last moments of an epoch can land after that epoch was read.
 * Anchored epochs can never be reopened and the table is append only, so such
 * a round is unanchorable forever. One period of grace is far wider than the
 * latency and skew involved, and costs a receipt at most one extra hour.
 */
const GRACE_EPOCHS = 1;

/**
 * "<contract>:<epoch>" -> consecutive failures, across runs inside one process.
 * Keyed on the contract as well, because epoch numbers come from the wall clock
 * and two ledgers driven from one process would otherwise share them, so a
 * single transient failure on each would read as one epoch failing twice.
 */
const failures = new Map();

/**
 * The value landed as written, and the chain agrees the receipts verify.
 *
 * Two checks, and only the second one is worth anything for the failure this
 * exists to catch.
 *
 * The first version compared `getEpoch(epoch).root` against `tree.root`. That
 * is a tautology for the case it was written for. The contract is handed 32
 * bytes and stores them, so a worker running an older lib/merkle.js anchors the
 * bare Merkle root, reads back the bare Merkle root, and agrees with itself.
 * Both sides of the comparison came out of the same library. Measured: a worker
 * patched back to the pre-count-binding builder anchored two epochs against the
 * current contract, reported them done, and issued four receipts that the chain
 * rejects, with `nextEpoch` advanced and no rewrite path. The check said
 * nothing.
 *
 * `verifyEpochRecord` is the answer, because it is the CONTRACT's arithmetic:
 * the COUNT_PREFIX fold and the proof-length rule, implemented on chain and
 * independent of this library. If the two disagree about the format, it returns
 * false. One eth_call per hour is a cheap price for the only detection there
 * is, and asking the chain rather than ourselves is the whole point.
 *
 * The equality check is kept as well. It catches a different thing: a dropped
 * or reorged transaction, or a wrong contract address.
 */
async function assertLanded(ledger, epoch, expectedRoot, expectedCount, sample) {
  const stored = await ledger.getEpoch(epoch);
  if (stored.root.toLowerCase() !== expectedRoot.toLowerCase() ||
      BigInt(stored.recordCount) !== BigInt(expectedCount)) {
    throw new Error(
      `epoch ${epoch}: anchored value does not match what was computed. ` +
      `chain holds ${stored.root} / ${stored.recordCount}, expected ` +
      `${expectedRoot} / ${expectedCount}. STOP: the anchor did not land as ` +
      `written.`);
  }
  // Empty periods carry no record to verify, so there is nothing to ask.
  if (!sample) return;
  if (!(await ledger.verifyEpochRecord(epoch, sample.leaf, sample.proof))) {
    throw new Error(
      `epoch ${epoch}: the contract rejects a receipt this worker just issued ` +
      `for it. STOP: the deployed contract and this worker disagree about the ` +
      `anchoring format, and every receipt for this epoch is unverifiable.`);
  }
}

function fromRow(row) {
  const kind = row.kind === 'seeded' ? 'seeded' : 'skill';
  const map = COLUMNS[kind];
  const rec = {};
  for (const [col, field] of Object.entries(map)) {
    const v = row[col];
    // String(null) is "null" and String(undefined) is "undefined", both of
    // which are valid-looking values that collide with a real row whose text
    // happens to be "null". Number(null) is 0, which makes a missing level
    // indistinguishable from level zero. Refuse instead of guessing.
    if (v === null || v === undefined) {
      throw new Error(`column ${col} is ${String(v)} for round ${row.round_id}`);
    }
    if (KINDS[kind].integers.includes(field)) {
      // Parse from the string form. Postgres bigint runs past 2^53, where
      // Number() silently rounds and two different values become one leaf.
      // Number("") is 0, Number("  ") is 0, Number([]) is 0 and Number("0x10")
      // is 16. None of those are the value the database holds, and each of
      // them quietly produces a leaf for a record that does not exist.
      const raw = String(v);
      if (!/^\d+$/.test(raw)) {
        throw new Error(`column ${col} is not a plain non negative integer: ${raw}`);
      }
      const n = Number(raw);
      if (!Number.isSafeInteger(n)) {
        throw new Error(`column ${col} is not a safe integer: ${raw}`);
      }
      rec[field] = n;
    } else {
      rec[field] = String(v);
    }
  }
  // gameId breaks the tie. (ended_at, round_id) is not unique: the database
  // key is (game_id, round_id), so two games can land on the same pair and the
  // ordering the proofs depend on would then be whatever the server felt like.
  // It is a separate field rather than part of sortKey so that the ordering of
  // every pair that is already distinct is untouched.
  return { kind, record: rec, sortKey: `${row.ended_at}|${row.round_id}`, tieKey: String(row.game_id) };
}

/**
 * Read one period out of Supabase.
 *
 * Order is not cosmetic. Proof indices come from it, so a re-run must
 * produce the identical sequence: sort by (ended_at, round_id).
 */
function makeSupabaseFetch({ url, serviceKey, pageSize = 1000 }) {
  return async function fetchRecords(fromTs, toTs) {
    const out = [];
    // Paged on the primary key, not on an offset over (ended_at, round_id).
    // That pair is not unique: the database key is (game_id, round_id), so two
    // games can produce the same pair and Postgres may order the tie
    // differently for page N and page N+1, which silently skips a row or
    // returns it twice. A skipped row is a hole in a ledger whose whole claim
    // is that it has none; a repeated one makes buildTree throw and stalls the
    // sequence. Paging on id is total and stable, and an insert landing between
    // two pages cannot shift the ones already read.
    let after = 0;
    let total = null;
    for (;;) {
      const q = new URL(`${url}/rest/v1/rounds`);
      q.searchParams.set('select', '*');
      q.searchParams.set('ended_at', `gte.${fromTs}`);
      q.searchParams.append('ended_at', `lt.${toTs}`);
      q.searchParams.set('id', `gt.${after}`);
      q.searchParams.set('order', 'id.asc');
      q.searchParams.set('limit', String(pageSize));

      const res = await fetch(q, {
        headers: {
          apikey: serviceKey,
          authorization: `Bearer ${serviceKey}`,
          // Ask for the total as well. It is the cross check below: the number
          // of rows this loop assembled has to equal the number the database
          // says match the filter.
          prefer: 'count=exact',
        },
      });
      if (!res.ok) throw new Error(`supabase read failed: ${res.status} ${await res.text()}`);
      const rows = await res.json();
      if (total === null) {
        // Content-Range is "<start>-<end>/<total>", or "*/<total>" for an empty
        // result. Only the first page's total is used: later pages are filtered
        // by the same predicate plus an advancing id, so their totals shrink.
        const cr = res.headers.get('content-range');
        const t = cr && cr.split('/')[1];
        total = t && /^\d+$/.test(t) ? Number(t) : undefined;
      }
      out.push(...rows.map(fromRow));

      // Stop on an EMPTY page, not on a short one.
      //
      // `rows.length < pageSize` was the stop condition, and it silently
      // assumed the server honours the requested limit. PostgREST enforces its
      // own db-max-rows independently: with that set below pageSize, every page
      // comes back short, the loop breaks on the first one, and the epoch is
      // anchored over a TRUNCATED record set with no error anywhere. That is a
      // permanent hole in an hour of a ledger whose entire claim is that it has
      // none, produced by a server side setting nobody in this file controls.
      // Paging until the server returns nothing removes the assumption; the id
      // cursor already guarantees the loop terminates.
      if (rows.length === 0) break;
      const lastId = Number(rows[rows.length - 1].id);
      if (!Number.isSafeInteger(lastId) || lastId <= after) {
        throw new Error(`supabase read returned a non advancing id cursor: ${rows[rows.length - 1].id}`);
      }
      after = lastId;
    }

    // Belt and braces against the same class of failure from a different
    // direction: a page that silently drops rows without shortening. If the
    // server would not tell us the total, that is not a reason to proceed
    // quietly, but it is not evidence of truncation either, so it is reported
    // rather than thrown.
    if (typeof total === 'number' && total !== out.length) {
      throw new Error(
        `supabase read assembled ${out.length} rows for [${fromTs}, ${toTs}) but the ` +
        `database reports ${total} match the same filter. STOP: anchoring a ` +
        `truncated hour is permanent.`);
    }
    // Sort again locally. Never rely on the server for an ordering that
    // permanent proofs depend on.
    out.sort((a, b) => (
      a.sortKey < b.sortKey ? -1 : a.sortKey > b.sortKey ? 1
        : a.tieKey < b.tieKey ? -1 : a.tieKey > b.tieKey ? 1 : 0
    ));
    return out.map(({ kind, record }) => ({ kind, record }));
  };
}

/**
 * Hash each entry, refusing anything that fails its own commitment.
 *
 * record-round rejects a mismatched commitment at the door, so a row that
 * reaches here is either older than that check or arrived by some other route.
 * The default is still to stop, because anchoring a broken record puts it
 * beyond reach forever. But stopping is permanent: the table is append only
 * and epochs are strictly sequential, so one such row halts the ledger for
 * good and no amount of restarting helps.
 *
 * `skipInvalid` is the operator's way out of that, and it is deliberately not
 * the default. It quarantines the offending rounds, returns them to the caller
 * and lets the epoch anchor without them, so the sequence continues. The
 * anchored root then does not cover every row in that epoch: the caller must
 * publish what was excluded, or the ledger's own claim about having no holes
 * stops being true.
 */
function prepare(entries, { skipInvalid = false } = {}) {
  const bad = [];
  const leaves = [];
  // The entries that produced `leaves`, in the same order. Returned rather
  // than re-derived, because re-deriving means filtering `entries` a second
  // time against a list of identifiers, and roundId does not identify a round:
  // the database key is (game_id, round_id). One roundId shared across two
  // games dropped the wrong entry, shifted every index after it, and handed
  // players a proof belonging to a different game.
  const kept = [];
  for (const e of entries) {
    if (e.kind === 'seeded' && !seedCommitmentValid(e.record)) {
      bad.push({ gameId: e.record.gameId, roundId: e.record.roundId });
      continue;
    }
    leaves.push(leafHash(e.record, e.kind));
    kept.push(e);
  }
  if (bad.length && !skipInvalid) {
    const names = bad.slice(0, 5).map((b) => `${b.gameId}/${b.roundId}`).join(', ');
    throw new Error(
      `seed commitment failed for ${bad.length} round(s): ${names}. ` +
      'Set skipInvalid to anchor the epoch without them and publish the exclusion list.'
    );
  }
  return { leaves, quarantined: bad, kept };
}

/**
 * Anchor every epoch from the contract's cursor up to the last fully
 * elapsed one. Empty epochs are anchored with EMPTY_PERIOD so the sequence
 * never contains a hole.
 */
async function runOnce({
  rpcUrl, privateKey, contract, fetch, now = Date.now, log = console.log, skipInvalid = false,
  ledger: injectedLedger = null, confirmations = CONFIRMATIONS,
  graceEpochs = GRACE_EPOCHS,
}) {
  // `ledger` is injectable, and that is not a convenience.
  //
  // This function built its own JsonRpcProvider from rpcUrl and privateKey,
  // which made it unreachable from the in-process test harness. The cursor and
  // genesis guards, the catch-up cap, the empty-epoch path, the
  // all-quarantined path, the ordering of done.push against assertLanded, the
  // error classification and the stall alarm were therefore covered by
  // nothing, and a comment in test/anchor.check.cjs asserted the opposite:
  // "runOnce itself is covered by the same code paths". It was not. Every
  // defect this file has had was in that control flow.
  let ledger = injectedLedger;
  if (!ledger) {
    const provider = new ethers.JsonRpcProvider(rpcUrl);
    // NonceManager, not a bare Wallet. JsonRpcProvider caches
    // getTransactionCount for 250 ms, and a catch-up run sends one anchorEpoch
    // after another: a second transaction inside that window reuses the nonce
    // and dies with NONCE_EXPIRED, which drops the run to one epoch and,
    // worse, trips the stall alarm on a transient error. scripts/_connect.cjs
    // already does this.
    const wallet = new ethers.NonceManager(new ethers.Wallet(privateKey, provider));
    ledger = new ethers.Contract(contract, ABI, wallet);
  }
  const contractKey = contract || (ledger.target ?? 'ledger');
  const done = [];
  let failed = null;      // the epoch this run stopped on, if any
  let stalled = null;     // set when that failure means the sequence is stuck

  /**
   * Send an anchor and record it BEFORE waiting for it to be mined.
   *
   * `await tx.wait()` was the first thing after the send, and a rejection
   * there - an RPC timeout, a dropped socket, a reorg at one confirmation -
   * threw into the catch block while the transaction went on to mine anyway.
   * The epoch was then omitted from the result, and because the cursor is read
   * from the CHAIN on the next run, that run starts past the epoch and the
   * proofs are never regenerated. Every receipt for that hour is lost with no
   * rewrite path: exactly the hazard the ordering of done.push against
   * assertLanded was written to close, sitting two lines above it and not
   * covered by it.
   *
   * So the entry is recorded first and carries a status. 'confirmed' means the
   * transaction was mined with `confirmations` behind it AND assertLanded
   * agreed. 'unconfirmed' means the anchor may or may not be on chain and the
   * caller must check before publishing anything in it.
   */
  const sendAnchor = async (entry, epoch, root, count, sample) => {
    const tx = await ledger.anchorEpoch(epoch, root, count);
    entry.tx = tx.hash;
    entry.status = 'unconfirmed';
    done.push(entry);
    await tx.wait(confirmations);
    await assertLanded(ledger, epoch, root, count, sample);
    entry.status = 'confirmed';
    return tx;
  };

  const cursor = Number(await ledger.nextEpoch());
  const genesis = Number(await ledger.genesisEpoch());
  const currentEpoch = Math.floor(now() / 1000 / EPOCH_SECONDS);

  // The contract takes its origin from its own deployment block and the worker
  // derives the period from the wall clock. Disagreement there is a
  // configuration error and would walk decades of empty periods one
  // transaction at a time, so refuse. A genuine backlog is different: cap the
  // work per run and let successive runs drain it.
  if (cursor < genesis) {
    throw new Error(`cursor ${cursor} is below genesisEpoch ${genesis}`);
  }
  if (cursor > currentEpoch) {
    log(`worker clock is behind the contract: cursor ${cursor}, clock ${currentEpoch}`);
    return result();
  }
  // One period of grace before an epoch is closed.
  //
  // The contract allows an epoch to be anchored the instant its period has
  // ended, and the worker took it. But a round is stamped with the epoch its
  // request fell in, on the edge function's clock, and the row appears only
  // when the insert commits. A POST arriving in the last moments of epoch E
  // can therefore land in the database AFTER this worker has already read
  // [start(E), end(E)) and anchored it. The table is append only and an
  // anchored epoch can never be reopened, so that round is in a hole forever:
  // it exists, it is stamped inside an anchored hour, and no proof for it can
  // ever be produced.
  //
  // The window is the edge function's processing and commit latency plus the
  // clock skew between the Supabase region and this host, neither of which
  // this file controls or can measure. One whole period of slack is far more
  // than either and costs a receipt at most one extra hour to become
  // available.
  const closeable = currentEpoch - graceEpochs;
  const end = Math.min(closeable, cursor + MAX_CATCHUP_EPOCHS);
  if (end <= cursor) {
    log(`nothing to close yet: cursor ${cursor}, clock ${currentEpoch}, ` +
        `grace ${graceEpochs} period(s)`);
    return result();
  }
  if (end < closeable) {
    log(`backlog of ${closeable - cursor} periods, draining ${end - cursor} this run`);
  }

  for (let epoch = cursor; epoch < end; epoch++) {
   try {
    const entries = await fetch(epochStart(epoch), epochEnd(epoch));

    if (entries.length === 0) {
      // EMPTY_PERIOD, not a zero. A zero root is also what an epoch that was
      // never anchored reads as, so the contract no longer accepts it: an
      // empty period has to be stated.
      // Recorded before the send completes. There are no receipts for an
      // empty period, but the ordering rule is the same one the non-empty path
      // needs and it should not differ between them.
      const entry = { epoch, root: EMPTY_PERIOD, count: 0, receipts: [] };
      const tx = await sendAnchor(entry, epoch, EMPTY_PERIOD, 0, null);
      failures.delete(`${contractKey}:${epoch}`);
      log(`epoch ${epoch}: empty, tx ${tx.hash}`);
      continue;
    }

    const { leaves, quarantined, kept } = prepare(entries, { skipInvalid });
    if (quarantined.length) {
      log(`epoch ${epoch}: QUARANTINED ${quarantined.length} round(s) failing their own ` +
          `seed commitment, anchoring without them: ` +
          quarantined.map((b) => `${b.gameId}/${b.roundId}`).join(', '));
    }
    if (leaves.length === 0) {
      const entry = { epoch, root: EMPTY_PERIOD, count: 0, receipts: [], quarantined };
      const tx = await sendAnchor(entry, epoch, EMPTY_PERIOD, 0, null);
      failures.delete(`${contractKey}:${epoch}`);
      log(`epoch ${epoch}: every record quarantined, anchored empty, tx ${tx.hash}`);
      continue;
    }
    const tree = buildTree(leaves);

    // Prove every proof before publishing. Cheap, and it catches a broken
    // tree before it is written somewhere permanent.
    for (let i = 0; i < leaves.length; i++) {
      if (!verifyProof(leaves[i], getProof(tree.levels, i), tree.root, leaves.length)) {
        throw new Error(`self check failed at index ${i} of epoch ${epoch}`);
      }
    }

    // Recorded before the send completes, deliberately. sendAnchor pushes the
    // entry as soon as the transaction has a hash and only marks it confirmed
    // once it is mined AND assertLanded agrees, so neither a failed wait nor a
    // failed read can discard proofs for an anchor that is on chain.
    //
    // assertLanded asks the CHAIN whether a receipt this worker just issued
    // actually verifies. Comparing our own value against itself proves nothing
    // about a format disagreement.
    const entry = {
      epoch,
      root: tree.root,
      count: leaves.length,
      quarantined,
      receipts: kept.map((e, i) => ({
        gameId: e.record.gameId,
        roundId: e.record.roundId,
        epoch,
        kind: e.kind,
        leaf: leaves[i],
        proof: getProof(tree.levels, i),
      })),
    };
    const tx = await sendAnchor(entry, epoch, tree.root, leaves.length,
      { leaf: leaves[0], proof: getProof(tree.levels, 0) });

    failures.delete(`${contractKey}:${epoch}`);
    log(`epoch ${epoch}: ${leaves.length} records, root ${tree.root}, tx ${tx.hash}`);
   } catch (err) {
      // Stop here, but hand back what has already been written. Throwing out
      // of the loop would discard the proofs for epochs that are on chain,
      // and the cursor has moved, so re-running would never regenerate them.
      //
      // A row that cannot be canonicalised is the dangerous case: the epoch
      // can never be built, the cursor never moves, and because epochs are
      // strictly sequential the whole ledger stops for good. The database is
      // append only by design, so the row cannot be deleted either. Report it
      // as a distinct failure so an operator can quarantine it rather than
      // discovering the stall days later.
      // Anything that fails deterministically on the same epoch will fail
      // again on the next run, so the sequence is stalled whatever the class
      // of the error. Flag on that, not on the exception type: the seed
      // commitment failure that actually stalls this worker is a plain Error,
      // so keying the alarm on RecordError meant the one stall an outsider
      // could trigger was reported as an ordinary transient failure. How far
      // behind the wall clock the cursor is says how long it has been true.
      const kind = err instanceof RecordError || /RecordError/.test(String(err))
        ? 'UNCANONICALISABLE RECORD'
        : /seed commitment/.test(String(err))
          ? 'SEED COMMITMENT MISMATCH'
          : 'ERROR';
      log(`epoch ${epoch} failed [${kind}]: ${err.message}`);

      // Only a REPEAT failure of the same epoch is a stall. An RPC hiccup or a
      // dropped transaction fails once and succeeds on the next run, and
      // crying wolf on those trains the operator to ignore the one alarm that
      // matters.
      //
      // Two independent signals, because the in-process one alone could never
      // fire in the deployment the README documents. `failures` lives in module
      // scope, and the runbook is "run the worker hourly": a fresh process per
      // hour, so `seen` was always 0, `seen + 1` was always 1, and the branch
      // was unreachable. The one alarm this file calls the one that matters was
      // dead code in production while passing in a long-lived test process.
      //
      // The lag signal survives process boundaries because it is derived from
      // chain state: the cursor is read from the contract every run, and a
      // deterministic failure holds it still while the clock moves on. One
      // period of lag is normal at the boundary; STALL_AFTER periods is the
      // sequence not moving.
      const key = `${contractKey}:${epoch}`;
      const seen = (failures.get(key) ?? 0) + 1;
      failures.set(key, seen);
      // The lag is measured against the earliest moment this epoch could have
      // been closed, not against the clock. With graceEpochs of slack the
      // minimum lag on a first attempt is graceEpochs + 1, so comparing the
      // raw lag to STALL_AFTER would raise the alarm on every ordinary
      // transient failure, which is the crying-wolf failure the counter was
      // written to avoid.
      const lag = currentEpoch - epoch;
      const overdue = lag - graceEpochs;
      if (seen >= STALL_AFTER || overdue >= STALL_AFTER) {
        stalled = { epoch, consecutiveFailures: seen, periodsBehind: lag, periodsOverdue: overdue, error: err.message };
        log(`SEQUENCE STALLED: epoch ${epoch} has failed ${seen} run(s) in this process and ` +
            `is ${overdue} period(s) overdue (${lag} behind the clock, ${graceEpochs} of grace). ` +
            'Nothing anchors until it is resolved.');
      }
      failed = { epoch, kind, error: err.message };
      break;
   }
  }

  return result();

  /**
   * What the caller gets back, and why it is not an array.
   *
   * This function used to `return done` from BOTH the success path and the
   * catch block, so a clean run and a stalled one were indistinguishable: no
   * thrown error, no status, nothing. When assertLanded fired - the control
   * this file spends forty lines justifying - the caller was handed the very
   * receipts the chain had just rejected, unflagged, and the documented caller
   * discarded the return value entirely.
   *
   *   ok          every epoch this run attempted is confirmed on chain
   *   epochs      one entry per attempted epoch, each with `status`
   *   unconfirmed the entries a caller must NOT publish without checking
   *   quarantined rounds excluded from an anchored root; the caller has to
   *               publish these or the no-holes claim stops being true
   *   failed      the epoch this run stopped on, with the error
   *   stalled     set when the failure means nothing will anchor until it is
   *               resolved. This is the alarm.
   */
  function result() {
    const unconfirmed = done.filter((d) => d.status !== 'confirmed');
    const quarantined = done.flatMap((d) => (d.quarantined || []).map(
      (q) => ({ ...q, epoch: d.epoch })));
    return {
      ok: !failed && unconfirmed.length === 0,
      epochs: done,
      unconfirmed,
      quarantined,
      failed,
      stalled,
      cursor,
      currentEpoch,
    };
  }
}

/** Build the object a player is handed. Exactly what verify.html consumes. */
function buildReceipt(record, kind, epoch, proof) {
  return { epoch, kind, record, proof };
}

module.exports = {
  EPOCH_SECONDS, epochStart, epochEnd,
  makeSupabaseFetch, fromRow, prepare, runOnce, buildReceipt, ABI, COLUMNS,
  // Exported so it can be tested. runOnce builds its own provider and is not
  // reachable from the in-process harness, so the most-discussed control in
  // this file shipped once with no automated coverage at all.
  assertLanded,
};
