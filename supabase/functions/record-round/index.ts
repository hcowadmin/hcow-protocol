// Supabase Edge Function: accept one round from a game client.
//
// The client is not trusted. This function decides what is written, applies
// per game sanity limits, and rate limits by player. It is the only writer
// to public.rounds.
//
// Deploy:  supabase functions deploy record-round --no-verify-jwt
// Secrets: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY (set by the platform)

import { createClient } from 'jsr:@supabase/supabase-js@2';
import { keccak256, toUtf8Bytes } from 'npm:ethers@6';

const ALLOWED_GAMES = new Set([
  'tint','blocko','chroma','moobble','mergeheroes','neondrift','daico',
  'popproof','weave','skyward','herdio','madcow','seedfall','moon',
  'dailyword','trivia',
]);

// Anything above these is a client that has been tampered with, or a bug.
// Rejecting is better than anchoring nonsense, because anchored is forever.
const LIMITS = {
  level: 100_000,
  score: 100_000_000,
  durationMs: 24 * 60 * 60 * 1000,
  nonce: 10_000_000,
  stringLen: 128,
  outcomeLen: 64,
  clockSkewSec: 300,
  perPlayerPerHour: 120,
  perIpPerHour: 600,
};

const ORIGINS = [
  'https://games.hash-cow.io',
  'https://hash-cow.io',
];
const cors = (origin: string | null) => ({
  'access-control-allow-origin':
    origin && (ORIGINS.includes(origin) || origin.endsWith('.hash-cow.io')) ? origin : ORIGINS[0],
  'access-control-allow-headers': 'content-type',
  'access-control-allow-methods': 'POST, OPTIONS',
  'vary': 'origin',
});

const bad = (msg: string, origin: string | null, code = 400) =>
  new Response(JSON.stringify({ error: msg }), {
    status: code,
    headers: { 'content-type': 'application/json', ...cors(origin) },
  });

/**
 * Accept only strings the anchoring pipeline can canonicalise.
 *
 * lib/canonical.js rejects unpaired surrogates and non-NFC text, because both
 * let two different records hash to one leaf. The database is append only, so
 * a row that reaches it and cannot later be canonicalised stalls the anchor
 * sequence permanently: the epoch can never be built and epochs are strictly
 * sequential. The check belongs here, at the only door in.
 */
const str = (v: unknown, max: number) => {
  if (typeof v !== 'string' || v.length === 0 || v.length > max) return null;
  const wellFormed = typeof (v as any).isWellFormed === 'function'
    ? (v as any).isWellFormed()
    : !/[\uD800-\uDFFF]/.test(v.replace(/[\uD800-\uDBFF][\uDC00-\uDFFF]/g, ''));
  if (!wellFormed) return null;
  const nfc = v.normalize('NFC');
  return nfc.length > 0 && nfc.length <= max ? nfc : null;
};
const int = (v: unknown, max: number) =>
  Number.isInteger(v) && (v as number) >= 0 && (v as number) <= max ? (v as number) : null;

Deno.serve(async (req) => {
  const origin = req.headers.get('origin');
  if (req.method === 'OPTIONS') return new Response(null, { headers: cors(origin) });
  if (req.method !== 'POST') return bad('POST only', origin, 405);

  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return bad('invalid json', origin); }

  const gameId = str(body.gameId, 32);
  if (!gameId || !ALLOWED_GAMES.has(gameId)) return bad('unknown gameId', origin);

  const roundId = str(body.roundId, LIMITS.stringLen);
  const playerRef = str(body.playerRef, LIMITS.stringLen);
  const outcome = str(body.outcome, LIMITS.outcomeLen);
  if (!roundId || !playerRef || !outcome) return bad('missing core fields', origin);

  const kind = body.kind === 'seeded' ? 'seeded' : 'skill';
  const now = Math.floor(Date.now() / 1000);

  // The client's clock is not authoritative. Accept a small skew, otherwise
  // stamp server time, so a device with a wrong clock cannot land a round in
  // an epoch that has already been anchored.
  const claimed = kind === 'seeded' ? body.timestamp : body.endedAt;
  let endedAt = int(claimed, now + LIMITS.clockSkewSec) ?? now;
  if (Math.abs(endedAt - now) > LIMITS.clockSkewSec) endedAt = now;
  // The anchorer now leaves one period of grace before closing an epoch, but
  // that grace is slack for commit latency and clock skew, not a licence to
  // backdate: a round backdated into the previous epoch by a slow client clock
  // still lands in one that will be anchored before anybody notices. The table is append only and epochs never reopen, so that row is
  // unanchorable forever: no receipt, no verification, and a silent hole in a
  // ledger whose whole claim is that it has none. The accepted skew may move
  // the timestamp within the current epoch, never out of it.
  const epochStart = Math.floor(now / 3600) * 3600;
  if (endedAt < epochStart) endedAt = epochStart;
  // And forward too. The clamp was one sided, so the sentence above was false
  // in the other direction: with `now` late in an epoch and a client clock
  // running fast, an accepted skew pushed the timestamp into the NEXT epoch.
  // That epoch is still open, so it is not the unanchorable case, but it files
  // a round into an hour it did not happen in and makes both hours' counts
  // wrong. Clamped to the last second of the current period.
  const epochEnd = epochStart + 3599;
  if (endedAt > epochEnd) endedAt = epochEnd;

  const row: Record<string, unknown> = {
    kind, game_id: gameId, round_id: roundId, player_ref: playerRef,
    outcome, ended_at: endedAt,
  };

  // The commitment is checked here, at the only door in, and never later.
  // A round whose revealed seed does not hash to its own commitment cannot be
  // turned into a leaf, and the anchorer refuses to anchor an epoch containing
  // one. Since the table is append only and epochs are strictly sequential,
  // letting one through would stop the ledger permanently: a single
  // unauthenticated POST, no wallet and no key, and the audit trail is dead.
  if (kind === 'seeded') {
    const h = str(body.serverSeedHash, 66);
    const sd = str(body.serverSeed, LIMITS.stringLen);
    if (!h || !sd) return bad('invalid seeded fields', origin);
    let digest: string;
    try { digest = keccak256(toUtf8Bytes(sd)); } catch { return bad('invalid serverSeed', origin); }
    if (digest.toLowerCase() !== h.toLowerCase()) {
      return bad('serverSeed does not match serverSeedHash', origin);
    }
  }

  if (kind === 'skill') {
    const mode = str(body.mode, 32);
    const level = int(body.level, LIMITS.level);
    const score = int(body.score, LIMITS.score);
    const durationMs = int(body.durationMs, LIMITS.durationMs);
    if (mode === null || level === null || score === null || durationMs === null) {
      return bad('invalid skill fields', origin);
    }
    Object.assign(row, { mode, level, score, duration_ms: durationMs });
  } else {
    const h = str(body.serverSeedHash, 66);
    const s = str(body.serverSeed, LIMITS.stringLen);
    const c = str(body.clientSeed, LIMITS.stringLen);
    const n = int(body.nonce, LIMITS.nonce);
    if (!h || !s || !c || n === null) return bad('invalid seeded fields', origin);
    Object.assign(row, { server_seed_hash: h, server_seed: s, client_seed: c, nonce: n });
  }

  const db = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    { auth: { persistSession: false } },
  );

  // Two flood guards. The per player one is keyed on a value the caller
  // supplies, so rotating it walks around the limit; it stays because it is
  // what stops one buggy client filling the hour. The second is keyed on the
  // caller address, which the caller cannot choose, and it is the one that
  // actually bounds a flood. Neither is authentication: see SECURITY.md.
  const { count } = await db.from('rounds')
    .select('id', { count: 'exact', head: true })
    .eq('player_ref', playerRef)
    .gte('ended_at', now - 3600);
  if ((count ?? 0) >= LIMITS.perPlayerPerHour) return bad('rate limited', origin, 429);

  // The LAST hop, not the first. X-Forwarded-For is appended to, not replaced,
  // so element zero is whatever the client put there: keying on it is keying on
  // a value the caller chooses, which is the exact weakness the per player
  // limit has. It also lets a caller write a victim's address into an
  // append-only table and rate limit that victim. The last element is the one
  // the edge tier added. Length capped because this is stored, forever.
  //
  // What this ASSUMES, stated because it is an assumption and not a check:
  // that exactly one trusted proxy appends to the header. Two ways it can be
  // wrong, and this function cannot tell either of them from correct
  // operation.
  //
  //   - A CDN in front of the platform makes the last hop the CDN's own
  //     address, shared by every caller. perIpPerHour then becomes a GLOBAL
  //     cap that one caller exhausts, denying service to everyone else.
  //   - No X-Forwarded-For reaching the function at all leaves `ip` empty,
  //     source_ip unset, and NO ip limit in force. It fails open, and the
  //     player_ref limit that remains is keyed on a value the caller chooses.
  //
  // Both are deployment properties, so the honest thing is a deployment check
  // rather than more code here: after deploying, call this endpoint from two
  // different networks and confirm the two rows carry two different
  // source_ip values, and that neither is a private or CDN range. Do it again
  // after any change to the domain or CDN in front of it. This is the third
  // iteration of this control (SECURITY.md section 15 records the first) and
  // the trust boundary has been assumed every time.
  //
  // A missing header is at least made visible rather than silently skipped.
  const hops = (req.headers.get('x-forwarded-for') ?? '')
    .split(',').map((h) => h.trim()).filter(Boolean);
  const ip = (hops[hops.length - 1] ?? '').slice(0, 45);
  if (!ip) {
    // Not a rejection: refusing every round because the platform stopped
    // sending a header would be a worse outage than the flood this limits.
    // But it must not be invisible.
    console.warn('record-round: no X-Forwarded-For, the per IP rate limit is NOT in force');
  }
  if (ip) {
    const { count: ipCount } = await db.from('rounds')
      .select('id', { count: 'exact', head: true })
      .eq('source_ip', ip)
      .gte('ended_at', now - 3600);
    if ((ipCount ?? 0) >= LIMITS.perIpPerHour) return bad('rate limited', origin, 429);
    row.source_ip = ip;
  }

  const { error } = await db.from('rounds').insert(row);
  if (error) {
    // A duplicate round id is a retry, not a failure. Treat it as success so
    // the client stops queuing it.
    if (error.code === '23505') {
      return new Response(JSON.stringify({ ok: true, duplicate: true }), {
        headers: { 'content-type': 'application/json', ...cors(origin) },
      });
    }
    return bad('write failed', origin, 500);
  }

  return new Response(JSON.stringify({ ok: true }), {
    headers: { 'content-type': 'application/json', ...cors(origin) },
  });
});
