/**
 * HCOW round recorder. Drop into any game with one script tag.
 *
 *   <script src="https://cdn.hash-cow.io/hcow-record.js"
 *           data-game="tint" data-endpoint="https://api.hash-cow.io/record"></script>
 *
 * Then call once when a round settles:
 *
 *   HCOWRecord.skill({ mode:'campaign', level:12, score:8400,
 *                      durationMs:64210, outcome:'cleared' });
 *
 * Everything else is handled here: the round id, the player reference, the
 * timestamp, retries, and an offline queue. It never blocks the game and it
 * never throws into game code.
 */
(function (global) {
  'use strict';

  var S = document.currentScript || {};
  var D = (S.dataset || {});
  var GAME = D.game || 'unknown';
  var ENDPOINT = D.endpoint || '';
  var QUEUE_KEY = 'hcow_round_q_v1';
  var REF_KEY = 'hcow_player_ref_v1';
  var MAX_QUEUE = 200;

  /* ---- player reference -------------------------------------------
     Opaque and stable, generated on the device. Never a wallet address,
     never an email. It exists so a player can find their own rounds, not
     so we can identify a person.                                      */
  function playerRef() {
    var v = null;
    try { v = localStorage.getItem(REF_KEY); } catch (e) {}
    if (v) return v;
    var bytes = new Uint8Array(12);
    (global.crypto || {}).getRandomValues
      ? global.crypto.getRandomValues(bytes)
      : bytes.forEach(function (_, i) { bytes[i] = Math.floor(Math.random() * 256); });
    v = 'p_' + Array.from(bytes, function (b) { return b.toString(16).padStart(2, '0'); }).join('');
    try { localStorage.setItem(REF_KEY, v); } catch (e) {}
    return v;
  }

  function roundId() {
    var bytes = new Uint8Array(8);
    (global.crypto || {}).getRandomValues
      ? global.crypto.getRandomValues(bytes)
      : bytes.forEach(function (_, i) { bytes[i] = Math.floor(Math.random() * 256); });
    return Date.now().toString(36) + '-' +
      Array.from(bytes, function (b) { return b.toString(16).padStart(2, '0'); }).join('');
  }

  /* ---- offline queue ---------------------------------------------- */
  function readQueue() {
    try { return JSON.parse(localStorage.getItem(QUEUE_KEY) || '[]'); } catch (e) { return []; }
  }
  function writeQueue(q) {
    try { localStorage.setItem(QUEUE_KEY, JSON.stringify(q.slice(-MAX_QUEUE))); } catch (e) {}
  }
  function enqueue(rec) { var q = readQueue(); q.push(rec); writeQueue(q); }

  function send(rec) {
    if (!ENDPOINT) return Promise.reject(new Error('no endpoint configured'));
    return fetch(ENDPOINT, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(rec),
      keepalive: true,          // survives the page closing right after a round
      credentials: 'omit',
    }).then(function (r) {
      if (!r.ok) throw new Error('http ' + r.status);
      return true;
    });
  }

  function flush() {
    var q = readQueue();
    if (!q.length) return;
    writeQueue([]);
    var stuck = [];
    var done = 0;
    q.forEach(function (rec) {
      send(rec).catch(function () { stuck.push(rec); }).then(function () {
        if (++done === q.length && stuck.length) {
          writeQueue(readQueue().concat(stuck));
        }
      });
    });
  }

  function submit(kind, fields) {
    var rec;
    try {
      rec = Object.assign({
        kind: kind,
        gameId: GAME,
        roundId: roundId(),
        playerRef: playerRef(),
      }, fields);
    } catch (e) { return; }

    send(rec).catch(function () { enqueue(rec); });
  }

  var HCOWRecord = {
    /** A skill or puzzle result. */
    skill: function (o) {
      submit('skill', {
        mode: String(o && o.mode || 'default'),
        level: Math.max(0, Math.trunc(Number(o && o.level) || 0)),
        score: Math.max(0, Math.trunc(Number(o && o.score) || 0)),
        durationMs: Math.max(0, Math.trunc(Number(o && o.durationMs) || 0)),
        outcome: String(o && o.outcome || 'cleared'),
        endedAt: Math.floor(Date.now() / 1000),
      });
    },
    /** A round whose randomness was committed in advance. */
    seeded: function (o) {
      submit('seeded', {
        serverSeedHash: String(o && o.serverSeedHash || ''),
        serverSeed: String(o && o.serverSeed || ''),
        clientSeed: String(o && o.clientSeed || ''),
        nonce: Math.max(0, Math.trunc(Number(o && o.nonce) || 0)),
        outcome: String(o && o.outcome || ''),
        timestamp: Math.floor(Date.now() / 1000),
      });
    },
    playerRef: playerRef,
    flush: flush,
  };

  global.HCOWRecord = HCOWRecord;

  // retry anything left over from a previous session
  if (document.readyState === 'complete') flush();
  else global.addEventListener('load', flush);
  global.addEventListener('online', flush);
})(window);
