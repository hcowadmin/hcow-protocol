/**
 * HCOW event indexer.
 *
 * Walks BSC logs for HCOWProfitShare and HCOWStaking and writes them into
 * chain_events. Runs on a schedule; each invocation picks up where the last
 * one stopped, so it is safe to call more often than needed and safe to call
 * twice at once (the unique key on tx_hash + log_index makes inserts idempotent).
 *
 * Why a worker at all. Public BSC RPCs cap eth_getLogs by block range and by
 * result count, and the range from deployment to head grows by about 28,800
 * blocks a day. A browser cannot scan that on page load. So the chain is
 * walked once here, in bounded chunks, and the app reads an indexed table.
 *
 * This is a cache, never a source of truth. Balances always come from the
 * contracts. If this table were deleted the app would lose history and lose
 * nothing else, and the worker would rebuild it from GENESIS_BLOCK.
 *
 * Environment:
 *   RPC_URLS             comma separated, tried in order. RPC_URL also accepted
 *   CHAIN_ID             defaults to 97
 *   PROFIT_SHARE_ADDRESS
 *   STAKING_ADDRESS
 *   GENESIS_BLOCK        first block to scan for a contract with no cursor
 *   SUPABASE_URL         injected by Supabase
 *   SUPABASE_SERVICE_ROLE_KEY  injected by Supabase
 *
 * Deploy:
 *   supabase functions deploy index-events --no-verify-jwt
 */

import { createClient } from "jsr:@supabase/supabase-js@2";
import { Interface } from "npm:ethers@6";

/**
 * Several endpoints, tried in order. Public BSC nodes disagree about how wide
 * an eth_getLogs range they will serve and rate limit without warning, and a
 * scheduled job that dies because one node was grumpy is a job nobody trusts.
 */
const RPC_URLS = (Deno.env.get("RPC_URLS") ?? Deno.env.get("RPC_URL") ?? [
  "https://bsc-testnet-rpc.publicnode.com",
  "https://data-seed-prebsc-1-s1.bnbchain.org:8545",
  "https://data-seed-prebsc-2-s1.bnbchain.org:8545",
].join(","))
  .split(",")
  .map((u) => u.trim())
  .filter(Boolean);
const CHAIN_ID = Number(Deno.env.get("CHAIN_ID") ?? "97");
const GENESIS_BLOCK = Number(Deno.env.get("GENESIS_BLOCK") ?? "124862688");

const LEDGER = (Deno.env.get("LEDGER_ADDRESS") ?? "").toLowerCase();
const PROFIT_SHARE = (Deno.env.get("PROFIT_SHARE_ADDRESS") ?? "").toLowerCase();
const STAKING = (Deno.env.get("STAKING_ADDRESS") ?? "").toLowerCase();

/**
 * Range sizing. Public nodes answer "limit exceeded" to a range they consider
 * too wide, and how wide that is depends on the node and on how many logs the
 * range contains, so it cannot be hardcoded. Start optimistic, halve on
 * refusal down to MIN_CHUNK, and grow back after a clean pass.
 *
 * MAX_CHUNKS bounds the work in one invocation because an edge function has a
 * wall clock limit. A long backfill finishes over several scheduled runs
 * rather than in one run that times out and commits nothing.
 */
const START_CHUNK = Number(Deno.env.get("CHUNK") ?? "1000");
const MIN_CHUNK = 100;
const MAX_CHUNK = 5_000;
const MAX_CHUNKS = 40;

/**
 * Node messages that mean "same request, smaller range" rather than "broken".
 *
 * Deliberately narrow. The wide form also matched "rate limit exceeded",
 * "429 Too Many Requests" and "daily request count exceeded", which are the
 * exact conditions the multi endpoint list exists for: matching them here
 * suppressed failover and shrank the window to the floor against a node that
 * was never going to answer.
 */
const RANGE_ERRORS =
  /block range|query returned more than|logs? matched|more than \d+ results|exceeds? (the )?(maximum|max|allowed) (block )?range|requested too many blocks|response size/i;

/** Messages that mean "this endpoint, right now" and should move to the next one. */
const ENDPOINT_ERRORS = /rate limit|too many requests|429|request count|quota|forbidden|unauthorized|timeout|timed out|econn|socket|fetch failed/i;

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

const PROFIT_SHARE_EVENTS = [
  "event Bonded(address indexed account, uint256 hcowAmount, uint256 sharesMinted)",
  "event UnbondRequested(address indexed account, uint256 hcowAmount, uint64 readyAt)",
  "event UnbondCancelled(address indexed account, uint256 hcowAmount, uint256 sharesMinted, uint256 forfeited)",
  "event Unbonded(address indexed account, uint256 hcowAmount, uint256 forfeited)",
  "event UsdtClaimed(address indexed account, uint256 amount)",
  "event EpochSettled(uint64 indexed epoch, uint256 grossReceivedUsdt, uint256 directCostsUsdt, uint256 netRevenueUsdt, uint256 operatingCostsUsdt, uint256 distributableProfitUsdt, uint256 participantsUsdt, uint256 refundedUsdt, uint256 hcowDeducted, uint256 snapshotBondedHcow)",
  // Governance. These belong to HCOWProfitShare and were previously declared
  // against HCOWStaking, which emits none of them: the interface used for the
  // ProfitShare address did not know the topics, parseLog returned null and
  // every one of them was silently dropped. The settler and the two payout
  // recipients could be changed with no row anywhere.
  //
  // Both RecipientsChanged parameters are indexed in the contract. Declaring
  // them non indexed produces the identical topic0 with an incompatible
  // layout, so the decode throws rather than returning null.
  "event SettlerChanged(address indexed account)",
  "event RecipientsChanged(address indexed gameCompany, address indexed team)",
  "event OwnershipTransferred(address indexed from, address indexed to)",
];

const LEDGER_EVENTS = [
  "event EpochAnchored(uint64 indexed epoch, bytes32 root, uint64 recordCount, uint64 anchoredAt)",
  "event HistoricalBatchAnchored(uint64 indexed batchId, bytes32 root, uint64 recordCount, uint64 coversFrom, uint64 coversTo, uint64 anchoredAt)",
  "event AnchorerSet(address indexed account, bool allowed)",
  "event OwnershipTransferred(address indexed from, address indexed to)",
];

const STAKING_EVENTS = [
  "event Staked(address indexed account, bytes32 indexed repId, uint256 amount)",
  "event Redelegated(address indexed account, bytes32 indexed fromRep, bytes32 indexed toRep, uint256 amount)",
  "event UnstakeRequested(address indexed account, uint256 amount, uint64 readyAt)",
  "event UnstakeCancelled(address indexed account, bytes32 indexed repId, uint256 amount)",
  // Governance and commission. Without these a representative's commission can
  // be changed, and every commission payment made, with no row anywhere.
  "event RepresentativeRegistered(bytes32 indexed id, string name, address payout, uint16 commissionBps, bool isFoundation)",
  "event RepresentativeUpdated(bytes32 indexed id, address payout, uint16 commissionBps, bool active)",
  "event CommissionClaimed(bytes32 indexed repId, address indexed payout, uint256 amount)",
  "event RewardFunderChanged(address indexed account)",
  "event OwnershipTransferred(address indexed from, address indexed to)",
  "event Unstaked(address indexed account, uint256 amount)",
  "event RewardsClaimed(address indexed account, uint256 amount)",
  "event RewardsFunded(uint256 amount, uint256 rewardRate, uint64 duration)",
];

const SOURCES = [
  { address: PROFIT_SHARE, iface: new Interface(PROFIT_SHARE_EVENTS) },
  { address: STAKING, iface: new Interface(STAKING_EVENTS) },
  { address: LEDGER, iface: new Interface(LEDGER_EVENTS) },
].filter((s) => s.address.startsWith("0x"));

// ---------------------------------------------------------------------------

let rpcId = 0;
let rpcIndex = 0;

/**
 * Call every endpoint in turn until one answers. A JSON-RPC error is returned
 * from the last endpoint tried rather than swallowed, because "limit exceeded"
 * is information the caller acts on.
 */
async function rpc<T>(method: string, params: unknown[]): Promise<T> {
  let lastError: Error | null = null;

  for (let attempt = 0; attempt < RPC_URLS.length; attempt++) {
    const url = RPC_URLS[(rpcIndex + attempt) % RPC_URLS.length];
    try {
      const res = await fetch(url, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ jsonrpc: "2.0", id: ++rpcId, method, params }),
      });
      if (!res.ok) throw new Error(`http ${res.status}`);
      const body = await res.json();
      if (body.error) throw new Error(body.error.message ?? "rpc error");
      // Stick with whichever endpoint just worked.
      rpcIndex = (rpcIndex + attempt) % RPC_URLS.length;
      return body.result as T;
    } catch (e) {
      lastError = e as Error;
      // A range refusal is not an endpoint failure. Surface it immediately so
      // the caller can retry smaller instead of burning every endpoint on a
      // request all of them would refuse.
      // "limit exceeded" and "query timeout" are matched by both patterns:
      // some nodes say them for a range refusal and some for a rate limit.
      // Failover is the cheaper guess, so the endpoint pattern wins here.
      // getLogsAdaptive then shrinks on either, so neither reading is fatal.
      if (RANGE_ERRORS.test(lastError.message) && !ENDPOINT_ERRORS.test(lastError.message)) break;
    }
  }
  throw new Error(`rpc ${method}: ${lastError?.message ?? "no endpoint answered"}`);
}

/**
 * eth_getLogs over [from, from + size - 1], shrinking the window until a node
 * accepts it. Returns the logs and the size that worked, so the caller can
 * carry the working size forward instead of rediscovering it every chunk.
 */
async function getLogsAdaptive(
  address: string,
  from: number,
  size: number,
  head: number,
): Promise<{ logs: RawLog[]; to: number; size: number }> {
  let width = size;
  for (;;) {
    const to = Math.min(from + width - 1, head);
    try {
      const logs = await rpc<RawLog[]>("eth_getLogs", [{
        address,
        fromBlock: hex(from),
        toBlock: hex(to),
      }]);
      return { logs, to, size: width };
    } catch (e) {
      const msg = (e as Error).message;
      // Shrink on either pattern. Halving costs one round trip; throwing costs
      // the whole run and the cursor does not advance. A node's phrasing for
      // "too much at once" is not standardised and will not stay matched
      // forever, so the failure mode here has to be retry, not death.
      if ((!RANGE_ERRORS.test(msg) && !ENDPOINT_ERRORS.test(msg)) || width <= MIN_CHUNK) throw e;
      width = Math.max(MIN_CHUNK, Math.floor(width / 2));
      await sleep(250);
    }
  }
}

const hex = (n: number) => "0x" + n.toString(16);

interface RawLog {
  address: string;
  topics: string[];
  data: string;
  blockNumber: string;
  transactionHash: string;
  logIndex: string;
}

/**
 * Block timestamps, fetched once per block rather than once per log. Safe to
 * keep across invocations of a warm instance because a mined block's timestamp
 * never changes; bounded so a long backfill cannot grow it without limit.
 */
const blockTimes = new Map<number, string>();
const BLOCK_CACHE_MAX = 5_000;

async function blockTime(n: number): Promise<string> {
  const cached = blockTimes.get(n);
  if (cached) return cached;
  if (blockTimes.size >= BLOCK_CACHE_MAX) blockTimes.clear();
  const b = await rpc<{ timestamp: string }>("eth_getBlockByNumber", [hex(n), false]);
  const iso = new Date(Number(BigInt(b.timestamp)) * 1000).toISOString();
  blockTimes.set(n, iso);
  return iso;
}

/** BigInt values are stored as decimal strings so no precision is lost. */
function decodeArgs(iface: Interface, log: RawLog) {
  // parseLog returns null for a topic0 it does not know, but throws when it
  // knows the topic0 and the layout disagrees, which is what a drifted indexed
  // flag looks like. An uncaught throw here propagates out of run(), the cursor
  // never advances, and the indexer stops on that block permanently. A log it
  // cannot decode must degrade to a skipped row, never to a halt.
  let parsed;
  try {
    parsed = iface.parseLog({ topics: [...log.topics], data: log.data });
  } catch (e) {
    console.warn(`undecodable log at ${log.blockNumber} topic0 ${log.topics[0]}: ${(e as Error).message}`);
    return null;
  }
  if (!parsed) return null;
  const args: Record<string, string> = {};
  parsed.fragment.inputs.forEach((input, i) => {
    const v = parsed.args[i];
    args[input.name] = typeof v === "bigint" ? v.toString() : String(v);
  });
  return { name: parsed.name, args };
}

Deno.serve(async () => {
  try {
    return await run();
  } catch (e) {
    // Return the failure as JSON rather than letting it become an opaque 500.
    // This runs on a schedule, so the log line is the only place anyone will
    // ever see why it stopped.
    return json({ ok: false, error: (e as Error).message }, 500);
  }
});

async function run(): Promise<Response> {
  const started = Date.now();
  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  if (SOURCES.length === 0) {
    return json({ error: "no contract addresses configured" }, 500);
  }

  const head = Number(BigInt(await rpc<string>("eth_blockNumber", [])));
  const report: Record<string, unknown>[] = [];

  for (const source of SOURCES) {
    const key = `${CHAIN_ID}:${source.address}`;
    const { data: state } = await supabase
      .from("indexer_state")
      .select("last_block")
      .eq("key", key)
      .maybeSingle();

    // last_block is the last block already indexed, so start one past it.
    let from = state ? Number(state.last_block) + 1 : GENESIS_BLOCK;
    if (from > head) {
      report.push({ contract: source.address, upToDate: true, head });
      continue;
    }

    let inserted = 0;
    let chunks = 0;
    let cursor = from;
    let width = START_CHUNK;

    while (cursor <= head && chunks < MAX_CHUNKS) {
      const got = await getLogsAdaptive(source.address, cursor, width, head);
      const { logs, to } = got;
      // Creep back up after a clean pass so one grumpy moment does not pin the
      // indexer at 100 blocks a request for the rest of the backfill.
      width = Math.min(MAX_CHUNK, got.size < width ? got.size : Math.floor(got.size * 1.5));

      const rows = [];
      for (const log of logs) {
        const decoded = decodeArgs(source.iface, log);
        // An event this indexer does not know about is skipped rather than
        // stored raw. A half-decoded row in a table the UI trusts is worse
        // than a missing one.
        if (!decoded) continue;

        const blockNumber = Number(BigInt(log.blockNumber));
        rows.push({
          chain_id: CHAIN_ID,
          contract: source.address,
          event: decoded.name,
          block_number: blockNumber,
          block_time: await blockTime(blockNumber),
          tx_hash: log.transactionHash,
          log_index: Number(BigInt(log.logIndex)),
          account: decoded.args.account ? decoded.args.account.toLowerCase() : null,
          epoch: decoded.name === "EpochSettled" ? Number(decoded.args.epoch) : null,
          args: decoded.args,
        });
      }

      if (rows.length > 0) {
        // Idempotent: re-running a range already covered updates nothing new.
        const { error } = await supabase
          .from("chain_events")
          .upsert(rows, { onConflict: "tx_hash,log_index", ignoreDuplicates: true });
        if (error) throw new Error(`insert: ${error.message}`);
        inserted += rows.length;
      }

      // Advance the cursor only after the rows for this range are committed,
      // so a crash mid-run replays the chunk instead of skipping it.
      const { error: cursorErr } = await supabase
        .from("indexer_state")
        .upsert({ key, last_block: to, updated_at: new Date().toISOString() });
      if (cursorErr) throw new Error(`cursor: ${cursorErr.message}`);

      cursor = to + 1;
      chunks++;
      await sleep(120);   // stay under public node rate limits
    }

    report.push({
      contract: source.address,
      from,
      to: cursor - 1,
      head,
      inserted,
      chunkSize: width,
      caughtUp: cursor > head,
    });
  }

  return json({ ok: true, chainId: CHAIN_ID, head, ms: Date.now() - started, report });
}

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body, null, 2), {
    status,
    headers: { "content-type": "application/json" },
  });
}
