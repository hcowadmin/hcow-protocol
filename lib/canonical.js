'use strict';
/**
 * Record formats and leaf hashing for HCOWLedger.
 *
 * The whole system rests on one rule: the same game round must always
 * produce the same 32 bytes, in any language, on any machine, forever.
 * That is what this file defines. Change anything here and every proof
 * ever issued stops verifying, so treat each kind as frozen once its
 * first root is on chain.
 *
 * There are two kinds of record, because our games make two different
 * claims and pretending otherwise would be dishonest.
 *
 *   skill   A result that happened and has not been edited since.
 *           Used by the puzzle and arcade titles. There is no money on
 *           the outcome, so what matters is that a score cannot be
 *           inserted or rewritten after the fact.
 *
 *   seeded  A result whose randomness was committed before play and
 *           revealed after. Used by titles where the server picks the
 *           outcome and the player needs to check it was not chosen
 *           against them.
 *
 * Both go into the same contract and the same anchor. A game can move
 * from skill to seeded later without touching anything already anchored.
 */

const { keccakUtf8 } = require('./keccak');

const KINDS = {
  skill: {
    domain: 'HCOWs1|',
    fields: [
      'gameId',      // string   "tint"
      'roundId',     // string   unique per game, never reused
      'playerRef',   // string   opaque and stable. never a wallet or an email
      'mode',        // string   "campaign" | "endless" | "daily" ...
      'level',       // integer  level or stage reached
      'score',       // integer  the number the leaderboard uses
      'durationMs',  // integer  wall clock length of the round
      'outcome',     // string   "cleared" | "failed" | "quit"
      'endedAt',     // integer  unix seconds when the round settled
    ],
    integers: ['level', 'score', 'durationMs', 'endedAt'],
    timeField: 'endedAt',
  },
  seeded: {
    domain: 'HCOWv1|',
    fields: [
      'gameId',
      'roundId',
      'playerRef',
      'serverSeedHash', // commitment published BEFORE the round
      'serverSeed',     // revealed AFTER the round
      'clientSeed',     // supplied by the player or the client
      'nonce',          // integer round counter within the seed pair
      'outcome',        // canonical outcome, exactly as shown to the player
      'timestamp',      // integer unix seconds when the round settled
    ],
    integers: ['nonce', 'timestamp'],
    timeField: 'timestamp',
  },
};

class RecordError extends Error {}

function specOf(kind) {
  const spec = KINDS[kind];
  if (!spec) throw new RecordError(`unknown record kind: ${kind}`);
  return spec;
}

function assertValid(rec, kind) {
  const spec = specOf(kind);
  if (rec === null || typeof rec !== 'object' || Array.isArray(rec)) {
    throw new RecordError('record must be a plain object');
  }
  for (const f of spec.fields) {
    if (!(f in rec)) throw new RecordError(`missing field: ${f}`);
    const v = rec[f];
    if (spec.integers.includes(f)) {
      // Number.isInteger alone is not enough. Postgres bigint runs past 2^53,
      // where two different scores round to the same JS number and therefore
      // to the same leaf, and String() switches to exponential notation above
      // 1e21 and would bake that into the canonical bytes forever. -0 also
      // passes Number.isInteger and serialises as "0".
      if (typeof v !== 'number' || !Number.isSafeInteger(v)) {
        throw new RecordError(`${f} must be a safe integer, got ${String(v)}`);
      }
      if (v < 0 || Object.is(v, -0)) {
        throw new RecordError(`${f} must be a non negative integer`);
      }
    } else {
      if (typeof v !== 'string') throw new RecordError(`${f} must be a string`);
      if (v.length === 0) throw new RecordError(`${f} must not be empty`);
      // A lone surrogate is replaced by U+FFFD on the way to UTF-8, so an
      // unbounded number of distinct strings would share one leaf. That is
      // exactly the substitution this whole scheme exists to prevent.
      if (typeof v.isWellFormed === 'function' ? !v.isWellFormed() : /[\uD800-\uDFFF]/.test(v.replace(/[\uD800-\uDBFF][\uDC00-\uDFFF]/g, ''))) {
        throw new RecordError(`${f} contains an unpaired surrogate`);
      }
      // The same text in NFC and NFD is two different byte strings and so two
      // different leaves. A receipt that passes through any normalising
      // pipeline would stop verifying and the player would be told, wrongly,
      // that their record was altered.
      if (v.normalize('NFC') !== v) {
        throw new RecordError(`${f} must be Unicode NFC normalised`);
      }
    }
  }
  const extra = Object.keys(rec).filter((k) => !spec.fields.includes(k));
  if (extra.length) {
    throw new RecordError(
      `unexpected field(s): ${extra.join(', ')}. Adding fields silently would break every existing proof.`
    );
  }
  return spec;
}

/**
 * Deterministic serialisation. Not JSON.stringify, because that leaves too
 * much to the runtime. Fixed field order, tab separated, newline terminated,
 * with backslash, tab and newline escaped so a value can never fake a
 * delimiter.
 */
function canonicalize(rec, kind) {
  const spec = assertValid(rec, kind);
  return spec.fields
    .map((f) => {
      const s = spec.integers.includes(f) ? String(rec[f]) : rec[f];
      return s.replace(/\\/g, '\\\\').replace(/\t/g, '\\t').replace(/\n/g, '\\n');
    })
    .join('\t') + '\n';
}

/** keccak256 of the kind's domain tag followed by the canonical form. */
function leafHash(rec, kind) {
  const spec = specOf(kind);
  return keccakUtf8(spec.domain + canonicalize(rec, kind));
}

/**
 * For seeded records only: check the revealed seed against the commitment
 * that was published before the round. This is what makes the outcome
 * provably fair. The anchor is what makes the record immutable. Two
 * separate claims, both needed.
 */
function seedCommitmentValid(rec) {
  return keccakUtf8(rec.serverSeed).toLowerCase() === String(rec.serverSeedHash).toLowerCase();
}

/** Unix seconds the record belongs to, whichever kind it is. */
function recordTime(rec, kind) {
  return rec[specOf(kind).timeField];
}

module.exports = { KINDS, canonicalize, leafHash, seedCommitmentValid, recordTime, RecordError };
