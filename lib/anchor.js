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
const { leafHash, seedCommitmentValid, recordTime, KINDS } = require('./canonical');
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
  return { kind, record: rec, sortKey: `${row.ended_at}|${row.round_id}` };
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
    for (let offset = 0; ; offset += pageSize) {
      const q = new URL(`${url}/rest/v1/rounds`);
      q.searchParams.set('select', '*');
      q.searchParams.set('ended_at', `gte.${fromTs}`);
      q.searchParams.append('ended_at', `lt.${toTs}`);
      q.searchParams.set('order', 'ended_at.asc,round_id.asc');
      q.searchParams.set('limit', String(pageSize));
      q.searchParams.set('offset', String(offset));

      const res = await fetch(q, {
        headers: { apikey: serviceKey, authorization: `Bearer ${serviceKey}` },
      });
      if (!res.ok) throw new Error(`supabase read failed: ${res.status} ${await res.text()}`);
      const rows = await res.json();
      out.push(...rows.map(fromRow));
      if (rows.length < pageSize) break;
    }
    // Sort again locally. Never rely on the server for an ordering that
    // permanent proofs depend on.
    out.sort((a, b) => (a.sortKey < b.sortKey ? -1 : a.sortKey > b.sortKey ? 1 : 0));
    return out.map(({ kind, record }) => ({ kind, record }));
  };
}

/** Hash each entry, refusing anything that fails its own commitment. */
function prepare(entries) {
  const bad = [];
  const leaves = [];
  for (const { kind, record } of entries) {
    if (kind === 'seeded' && !seedCommitmentValid(record)) { bad.push(record.roundId); continue; }
    leaves.push(leafHash(record, kind));
  }
  if (bad.length) {
    // Anchoring a round whose seed does not match its own commitment would
    // put a broken record beyond reach forever. Stop instead.
    throw new Error(`seed commitment failed for ${bad.length} round(s): ${bad.slice(0, 5).join(', ')}`);
  }
  return leaves;
}

/**
 * Anchor every epoch from the contract's cursor up to the last fully
 * elapsed one. Empty epochs are anchored with a zero root so the sequence
 * never contains a hole.
 */
async function runOnce({ rpcUrl, privateKey, contract, fetch, now = Date.now, log = console.log }) {
  const provider = new ethers.JsonRpcProvider(rpcUrl);
  const wallet = new ethers.Wallet(privateKey, provider);
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
      log(`epoch ${epoch}: empty, tx ${tx.hash}`);
      done.push({ epoch, root: ethers.ZeroHash, count: 0, tx: tx.hash, receipts: [] });
      continue;
    }

    const leaves = prepare(entries);
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
    log(`epoch ${epoch}: ${leaves.length} records, root ${tree.root}, tx ${tx.hash}`);

    done.push({
      epoch,
      root: tree.root,
      count: leaves.length,
      tx: tx.hash,
      receipts: entries.map((e, i) => ({
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
      log(`epoch ${epoch} failed: ${err.message}`);
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
