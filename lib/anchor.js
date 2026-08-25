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
const { buildTree, getProof, verifyProof } = require('./merkle');

const ABI = [
  'function nextEpoch() view returns (uint64)',
  'function genesisEpoch() view returns (uint64)',
  'function anchorEpoch(uint64 epoch, bytes32 root, uint64 recordCount)',
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
 * "<contract>:<epoch>" -> consecutive failures, across runs inside one process.
 * Keyed on the contract as well, because epoch numbers come from the wall clock
 * and two ledgers driven from one process would otherwise share them, so a
 * single transient failure on each would read as one epoch failing twice.
 */
const failures = new Map();

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
    for (;;) {
      const q = new URL(`${url}/rest/v1/rounds`);
      q.searchParams.set('select', '*');
      q.searchParams.set('ended_at', `gte.${fromTs}`);
      q.searchParams.append('ended_at', `lt.${toTs}`);
      q.searchParams.set('id', `gt.${after}`);
      q.searchParams.set('order', 'id.asc');
      q.searchParams.set('limit', String(pageSize));

      const res = await fetch(q, {
        headers: { apikey: serviceKey, authorization: `Bearer ${serviceKey}` },
      });
      if (!res.ok) throw new Error(`supabase read failed: ${res.status} ${await res.text()}`);
      const rows = await res.json();
      out.push(...rows.map(fromRow));
      if (rows.length < pageSize) break;
      const lastId = Number(rows[rows.length - 1].id);
      if (!Number.isSafeInteger(lastId) || lastId <= after) {
        throw new Error(`supabase read returned a non advancing id cursor: ${rows[rows.length - 1].id}`);
      }
      after = lastId;
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
 * elapsed one. Empty epochs are anchored with a zero root so the sequence
 * never contains a hole.
 */
async function runOnce({
  rpcUrl, privateKey, contract, fetch, now = Date.now, log = console.log, skipInvalid = false,
}) {
  const provider = new ethers.JsonRpcProvider(rpcUrl);
  // NonceManager, not a bare Wallet. JsonRpcProvider caches getTransactionCount
  // for 250 ms, and a catch-up run sends one anchorEpoch after another: a
  // second transaction inside that window reuses the nonce and dies with
  // NONCE_EXPIRED, which drops the run to one epoch and, worse, trips the stall
  // alarm on a transient error. scripts/_connect.cjs already does this.
  const wallet = new ethers.NonceManager(new ethers.Wallet(privateKey, provider));
  const ledger = new ethers.Contract(contract, ABI, wallet);

  const cursor = Number(await ledger.nextEpoch());
  const genesis = Number(await ledger.genesisEpoch());
  const currentEpoch = Math.floor(now() / 1000 / EPOCH_SECONDS);
  const done = [];

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
    return done;
  }
  const end = Math.min(currentEpoch, cursor + MAX_CATCHUP_EPOCHS);
  if (end < currentEpoch) {
    log(`backlog of ${currentEpoch - cursor} periods, draining ${end - cursor} this run`);
  }

  for (let epoch = cursor; epoch < end; epoch++) {
   try {
    const entries = await fetch(epochStart(epoch), epochEnd(epoch));

    if (entries.length === 0) {
      const tx = await ledger.anchorEpoch(epoch, ethers.ZeroHash, 0);
      await tx.wait();
      failures.delete(`${contract}:${epoch}`);
      log(`epoch ${epoch}: empty, tx ${tx.hash}`);
      done.push({ epoch, root: ethers.ZeroHash, count: 0, tx: tx.hash, receipts: [] });
      continue;
    }

    const { leaves, quarantined, kept } = prepare(entries, { skipInvalid });
    if (quarantined.length) {
      log(`epoch ${epoch}: QUARANTINED ${quarantined.length} round(s) failing their own ` +
          `seed commitment, anchoring without them: ` +
          quarantined.map((b) => `${b.gameId}/${b.roundId}`).join(', '));
    }
    if (leaves.length === 0) {
      const tx = await ledger.anchorEpoch(epoch, ethers.ZeroHash, 0);
      await tx.wait();
      failures.delete(`${contract}:${epoch}`);
      log(`epoch ${epoch}: every record quarantined, anchored empty, tx ${tx.hash}`);
      done.push({ epoch, root: ethers.ZeroHash, count: 0, tx: tx.hash, receipts: [], quarantined });
      continue;
    }
    const tree = buildTree(leaves);

    // Prove every proof before publishing. Cheap, and it catches a broken
    // tree before it is written somewhere permanent.
    for (let i = 0; i < leaves.length; i++) {
      if (!verifyProof(leaves[i], getProof(tree.levels, i), tree.root)) {
        throw new Error(`self check failed at index ${i} of epoch ${epoch}`);
      }
    }

    const tx = await ledger.anchorEpoch(epoch, tree.root, leaves.length);
    await tx.wait();
    failures.delete(`${contract}:${epoch}`);
    log(`epoch ${epoch}: ${leaves.length} records, root ${tree.root}, tx ${tx.hash}`);

    done.push({
      epoch,
      root: tree.root,
      count: leaves.length,
      tx: tx.hash,
      quarantined,
      receipts: kept.map((e, i) => ({
        gameId: e.record.gameId,
        roundId: e.record.roundId,
        epoch,
        kind: e.kind,
        leaf: leaves[i],
        proof: getProof(tree.levels, i),
      })),
    });
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
      // matters. Keying it on how far behind the clock is did exactly that.
      const key = `${contract}:${epoch}`;
      const seen = failures.get(key) ?? 0;
      failures.set(key, seen + 1);
      if (seen + 1 >= STALL_AFTER) {
        log(`SEQUENCE STALLED: epoch ${epoch} has now failed ${seen + 1} runs in a row and ` +
            `the cursor is ${currentEpoch - epoch} periods behind the clock. ` +
            'Nothing anchors until it is resolved.');
      }
      return done;
   }
  }

  return done;
}

/** Build the object a player is handed. Exactly what verify.html consumes. */
function buildReceipt(record, kind, epoch, proof) {
  return { epoch, kind, record, proof };
}

module.exports = {
  EPOCH_SECONDS, epochStart, epochEnd,
  makeSupabaseFetch, fromRow, prepare, runOnce, buildReceipt, ABI, COLUMNS,
};
