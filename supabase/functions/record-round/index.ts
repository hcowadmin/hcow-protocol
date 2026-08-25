// Supabase Edge Function: accept one round from a game client.
//
// The client is not trusted. This function decides what is written, applies
// per game sanity limits, and rate limits by player. It is the only writer
// to public.rounds.
//
// Deploy:  supabase functions deploy record-round --no-verify-jwt
// Secrets: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY (set by the platform)

import { createClient } from 'jsr:@supabase/supabase-js@2';

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

  const row: Record<string, unknown> = {
    kind, game_id: gameId, round_id: roundId, player_ref: playerRef,
    outcome, ended_at: endedAt,
  };

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

  // Cheap flood guard: no more than 120 rounds per player per hour.
  const { count } = await db.from('rounds')
    .select('id', { count: 'exact', head: true })
    .eq('player_ref', playerRef)
    .gte('ended_at', now - 3600);
  if ((count ?? 0) >= 120) return bad('rate limited', origin, 429);

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
