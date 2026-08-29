'use strict';
/**
 * Mutation runner.
 *
 * A guard that no test notices is not a guard, it is a comment. This applies
 * one mutation at a time to a source file, runs the suite that is supposed to
 * catch it, restores the file, and reports whether the suite actually failed.
 *
 * It is deliberately not wired into `npm test`: it edits contracts on disk,
 * and a crash mid-run would leave a mutated tree. It restores in a finally
 * block and verifies the restore before exiting.
 *
 * Usage: node scripts/mutate.cjs [substring of a mutation name]
 */
const fs = require('fs');
const { execSync } = require('child_process');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const PS = 'contracts/HCOWProfitShare.sol';
const LG = 'contracts/HCOWLedger.sol';
const ST = 'contracts/HCOWStaking.sol';

const HH = (f) => `npx hardhat compile >/dev/null 2>&1; npx hardhat run ${f}`;

const MUTATIONS = [
  // ---- lib/anchor.js, the worker's own control flow ----
  {
    // The receipts of an anchor that landed must survive a failed
    // confirmation. Waiting first is what lost them: the cursor is read from
    // the chain, so the next run starts past the epoch and the proofs are
    // never regenerated.
    name: 'the worker waits for the anchor before recording its receipts again',
    file: 'lib/anchor.js',
    from: "    entry.status = 'unconfirmed';\n    done.push(entry);\n    await tx.wait(confirmations);",
    to:   "    entry.status = 'unconfirmed';\n    await tx.wait(confirmations);\n    done.push(entry);",
    run: HH('test/anchor.check.cjs'),
    expect: 'runOnce discarded the receipts of an anchor that landed',
  },
  {
    // The in-process counter can never reach two under the documented runbook,
    // which is a fresh process per hour. The lag signal is what makes the
    // alarm reachable at all.
    name: 'the stall alarm goes back to the in-process counter alone',
    file: 'lib/anchor.js',
    from: '      if (seen >= STALL_AFTER || overdue >= STALL_AFTER) {',
    to:   '      if (seen >= STALL_AFTER) {',
    run: HH('test/anchor.check.cjs'),
    expect: 'runOnce did not raise the stall alarm on a cursor five periods behind',
  },
  {
    // A short page is not the end of the data. PostgREST's own db-max-rows can
    // cap every page below the requested limit, and stopping there anchors a
    // truncated hour permanently.
    name: 'the record read stops on a short page again',
    file: 'lib/anchor.js',
    from: '      if (rows.length === 0) break;',
    to:   '      if (rows.length < pageSize) break;',
    run: HH('test/anchor.check.cjs'),
    expect: 'a server that caps pages below the requested limit truncated the hour',
  },
  {
    // Without the grace period a round inserted at the very end of an epoch
    // can land after the worker has already read and anchored that epoch, and
    // an anchored epoch can never be reopened.
    name: 'the worker closes an epoch the moment it ends again',
    file: 'lib/anchor.js',
    from: '  const closeable = currentEpoch - graceEpochs;',
    to:   '  const closeable = currentEpoch;',
    run: HH('test/anchor.check.cjs'),
    expect: 'the worker closed an epoch that had only just ended, with no grace at all',
  },
  // ---- HCOWProfitShare, this round's guards ----
  {
    // The adversary script's figures are quoted as what a stolen settler key is
    // worth. It had no assertion in it at all and exited 0 whatever it
    // measured, so a regression would have printed a different number and
    // passed. This sends the deduction to the settler instead of the burn
    // address, which is the single worst regression it is meant to catch.
    name: 'a deduction pays the settler instead of the burn address',
    file: PS,
    from: '        if (hcowToDeduct > 0) hcow.safeTransfer(BURN_ADDRESS, hcowToDeduct);',
    to:   '        if (hcowToDeduct > 0) hcow.safeTransfer(msg.sender, hcowToDeduct);',
    run: HH('test/adversary.settler.cjs'),
    expect: 'bonded HCOW the settler can move to itself',
  },
  {
    // A recipient set to this contract makes every settlement self transfer
    // USDT into a balance accUsdtPerShare does not account for. No sweep, no
    // rescue, unreachable by claimUsdt forever.
    name: 'the contract itself can be made a payout recipient again',
    file: PS,
    from: '        if (gameCompany_ == address(this) || team_ == address(this)) revert ZeroAddress();',
    to:   '        if (false) revert ZeroAddress();',
    run: HH('test/profitshare.test.cjs'),
    expect: 'the contract itself cannot be made the game company',
  },
  {
    // The library is the reference verifier the README offers a third party.
    // It shipped without the proof-length check and accepted the Merkle root
    // itself as a leaf with an empty proof, which the chain has always
    // refused. The differential test now drives BOTH sides of every forgery;
    // this proves it does.
    name: 'the library verifier drops the proof length check again',
    file: 'lib/merkle.js',
    from: '  if (proof.length !== depthOf(recordCount)) return false;',
    to:   '  if (false) return false;',
    run: HH('test/merkle.differential.cjs'),
    expect: 'the library does not accept the Merkle root as a leaf either',
  },
  {
    name: 'the library verifier stops rejecting the padding filler',
    file: 'lib/merkle.js',
    from: "  if (l === EMPTY_LEAF.toLowerCase()) return false;",
    to:   '  if (false) return false;',
    run: HH('test/merkle.differential.cjs'),
    expect: 'the padding filler is not a record in the library either',
  },
  {
    name: 'carry removed: the withheld participant leg is not carried',
    file: PS,
    from: '            uint256 newCarry = (profit * PARTICIPANT_BPS) / 10_000 + prior - participants;',
    to:   '            uint256 newCarry = prior;',
    run: HH('test/profitshare.test.cjs'),
    expect: 'the participant half is carried, not reassigned',
  },
  {
    // The published worst case depends on decayWindowAt being written by the
    // first deduction rather than by the clock. If it were clock aligned the
    // packing would be impossible and the figure would be lower, so the two
    // packed measurements have to be able to see the difference.
    name: 'the decay window is aligned to the clock instead of to the first deduction',
    file: PS,
    from: '                decayWindowAt = uint64(block.timestamp);',
    to:   '                decayWindowAt = uint64(block.timestamp - (block.timestamp % DECAY_WINDOW));',
    run: HH('test/profitshare.test.cjs'),
    expect: 'the window is anchored by the first deduction, not by the clock',
  },
  {
    // The boundary is inclusive: a deduction at exactly decayWindowAt +
    // DECAY_WINDOW opens the next window. That inclusiveness is what the
    // published thirty seven day figure rests on, so it has to be visible.
    name: 'the window boundary is made exclusive, so the next window opens a second late',
    file: PS,
    from: '            if (decayWindowAt == 0 || block.timestamp >= decayWindowAt + DECAY_WINDOW) {',
    to:   '            if (decayWindowAt == 0 || block.timestamp > decayWindowAt + DECAY_WINDOW) {',
    run: HH('test/profitshare.test.cjs'),
    expect: 'a second window opens exactly thirty days after the first was anchored',
  },
  {
    name: 'participant floor cap removed',
    file: PS,
    from: '        if (minPoolShares_ > (supply * MAX_MIN_POOL_SHARES_BPS) / 10_000) {',
    to:   '        if (false) {',
    run: HH('test/profitshare.test.cjs'),
    expect: 'a floor above 5% of supply is refused',
  },
  {
    name: 'stall deadline removed: a settled epoch can be closed immediately',
    file: PS,
    from: '        if (block.timestamp < deadline) revert EpochNotStalled(deadline);',
    to:   '        if (false) revert EpochNotStalled(deadline);',
    run: HH('test/profitshare.test.cjs'),
    expect: 'a freshly settled epoch cannot be closed either',
  },
  {
    name: 'the bootstrap fuse drops to the ordinary one',
    file: PS,
    from: '            ? deployedAt + uint64(BOOTSTRAP_STALL_INTERVAL)',
    to:   '            ? deployedAt + uint64(MAX_EPOCH_INTERVAL)',
    run: HH('test/profitshare.test.cjs'),
    expect: 'and thirty days of doing nothing does not change that',
  },
  {
    name: 'total abandonment becomes a permanent quarantine again',
    file: PS,
    from: '        uint64 deadline = openedAt == 0',
    to:   '        if (openedAt == 0) revert EpochNotStalled(0);\n        uint64 deadline = openedAt == 0',
    run: HH('test/profitshare.test.cjs'),
    expect: 'at ninety one, anyone can advance it',
  },
  {
    name: 'deduction gate tests the credited total again, so a carry satisfies it',
    file: PS,
    from: '            _epochCredit(profit, eligibleShares) < MIN_PARTICIPANT_USDT',
    to:   '            participants < MIN_PARTICIPANT_USDT',
    run: HH('test/profitshare.test.cjs'),
    expect: 'one wei of revenue cannot buy a deduction, whatever is carried',
  },
  {
    name: 'deduction gate removed entirely',
    file: PS,
    from: '            deductPpm != 0 &&\n            eligibleShares != 0 &&',
    to:   '            false &&\n            eligibleShares != 0 &&',
    run: HH('test/profitshare.test.cjs'),
    expect: 'a zero profit epoch cannot deduct principal',
  },
  {
    name: 'ownership transfer back to one step',
    file: PS,
    from: '        pendingOwner = newOwner;\n        emit OwnershipTransferStarted(owner, newOwner);',
    to:   '        emit OwnershipTransferred(owner, newOwner);\n        owner = newOwner;',
    run: HH('test/profitshare.test.cjs'),
    expect: 'the nominee can complete the transfer',
  },
  {
    name: 'settler may be a payout recipient (setter)',
    file: PS,
    from: '        if (account == gameCompany || account == team) revert SettlerIsRecipient();',
    to:   '        if (false) revert SettlerIsRecipient();',
    run: HH('test/profitshare.test.cjs'),
    expect: 'setSettler refuses the game company',
  },

  {
    name: 'settleEpoch pays out before it writes its state again',
    file: PS,
    from: '        if (toGameCompany > 0) usdt.safeTransfer(gameCompany, toGameCompany);\n        if (toTeam > 0) usdt.safeTransfer(team, toTeam);\n        if (hcowToDeduct > 0) hcow.safeTransfer(BURN_ADDRESS, hcowToDeduct);',
    to:   '        if (toGameCompany > 0) usdt.safeTransfer(gameCompany, toGameCompany);\n        if (toTeam > 0) usdt.safeTransfer(team, toTeam);',
    run: HH('test/profitshare.test.cjs'),
    expect: 'hcow held equals bonded plus pending',
  },
  {
    name: 'revenue can be settled with no shares at all, stranding the carry',
    file: PS,
    from: '        if (profit > 0 && totalShares == 0) revert NoParticipantsToCarryFor();',
    to:   '        if (false) revert NoParticipantsToCarryFor();',
    run: HH('test/profitshare.test.cjs'),
    expect: 'a settlement with revenue and no shares at all is refused',
  },

  // ---- HCOWStaking ----
  {
    name: 'the representative registry ceiling is raised a thousandfold',
    file: 'contracts/HCOWStaking.sol',
    from: '    uint256 public constant MAX_REPRESENTATIVES = 100;',
    to:   '    uint256 public constant MAX_REPRESENTATIVES = 100_000;',
    run: HH('test/staking.test.cjs'),
    expect: 'the published ceiling is one hundred',
  },
  {
    name: 'the carry release guard moves back above _updateGlobal',
    file: 'contracts/HCOWStaking.sol',
    from: '        _updateGlobal();\n        if (amount == 0 && undistributed == 0) revert ZeroAmount();',
    to:   '        if (amount == 0 && undistributed == 0) revert ZeroAmount();\n        _updateGlobal();',
    run: HH('test/staking.test.cjs'),
    expect: 'the carry can be released with no new money',
  },
  {
    name: 'staking ownership transfer back to one step',
    file: 'contracts/HCOWStaking.sol',
    from: '        pendingOwner = newOwner;\n        emit OwnershipTransferStarted(owner, newOwner);',
    to:   '        emit OwnershipTransferred(owner, newOwner);\n        owner = newOwner;',
    run: HH('test/staking.test.cjs'),
    expect: 'the owner does not change on the first step',
  },

  // ---- HCOWFaucet ----
  {
    name: 'status reports full allowances again instead of what would be paid',
    file: 'contracts/HCOWFaucet.sol',
    from: '        hcowNow = hcowRemaining >= hcowAmount ? hcowAmount : 0;',
    to:   '        hcowNow = claimsLeft;',
    run: HH('test/faucet.test.cjs'),
    expect: 'but the caller would still receive the whole HCOW side',
  },
  {
    name: 'faucet ownership transfer back to one step',
    file: 'contracts/HCOWFaucet.sol',
    from: '        pendingOwner = newOwner;\n        emit OwnershipTransferStarted(owner, newOwner);',
    to:   '        emit OwnershipTransferred(owner, newOwner);\n        owner = newOwner;',
    run: HH('test/faucet.test.cjs'),
    expect: 'the owner does not change on the first step',
  },

  {
    name: 'one proven anchorer is enough to renounce again',
    file: LG,
    from: '        if (provenAnchorerCount < MIN_ANCHORERS_TO_RENOUNCE) {',
    to:   '        if (provenAnchorerCount < 1) {',
    run: HH('test/ledger.test.cjs'),
    expect: 'one proven anchorer is not enough to renounce',
  },
  {
    name: 'the last proven anchorer can revoke itself',
    file: LG,
    from: '        if (hasAnchored[msg.sender] && provenAnchorerCount <= 1) revert NoAnchorerLeft();',
    to:   '        if (false) revert NoAnchorerLeft();',
    run: HH('test/ledger.test.cjs'),
    expect: 'the last proven anchorer cannot revoke itself',
  },

  // ---- HCOWLedger, this round's guards ----
  {
    name: 'record count no longer bound into the anchored value',
    file: LG,
    from: '        return keccak256(abi.encodePacked(COUNT_PREFIX, h, recordCount)) == root;',
    to:   '        return h == root;',
    run: HH('test/merkle.differential.cjs'),
    expect: 'a bare Merkle root anchored without the count binding verifies nothing',
  },
  {
    name: 'the anchor readback compares the worker against itself again',
    file: 'lib/anchor.js',
    from: '  if (!(await ledger.verifyEpochRecord(epoch, sample.leaf, sample.proof))) {',
    to:   '  if (false) {',
    run: HH('test/anchor.check.cjs'),
    expect: 'assertLanded accepted an anchor whose receipts the chain rejects',
  },
  {
    name: 'a backfill root can be replayed',
    file: LG,
    from: '        if (historicalRootAnchored[root]) revert RootAlreadyAnchored(root);',
    to:   '        if (false) revert RootAlreadyAnchored(root);',
    run: HH('test/ledger.test.cjs'),
    expect: 'the same backfill cannot be anchored twice',
  },
  {
    name: 'the padding filler is accepted as a record',
    file: LG,
    from: '        if (leaf == EMPTY_LEAF) return false;',
    to:   '        if (false) return false;',
    run: HH('test/ledger.test.cjs'),
    expect: 'the padding filler cannot be presented as a record',
  },
  {
    name: 'backfill may reach into time the live path covers',
    file: LG,
    from: '        if (coversTo >= genesisStart) revert BackfillCoversLiveTime(genesisStart);',
    to:   '        if (coversTo > block.timestamp) revert BackfillCoversLiveTime(genesisStart);',
    run: HH('test/ledger.test.cjs'),
    expect: 'a backfill cannot reach into time the live path covers',
  },
  {
    name: 'proof of control survives removal',
    file: LG,
    from: '                hasAnchored[account] = false;',
    to:   '                {}',
    run: HH('test/ledger.test.cjs'),
    expect: 'anchoring again re-proves it',
  },
  {
    name: 'the tree pairs an odd node with itself again',
    file: 'lib/merkle.js',
    from: '  while (padded.length < width) padded.push(EMPTY_LEAF);',
    to:   '  while (padded.length < width) padded.push(padded[padded.length - 1]);',
    run: HH('test/merkle.differential.cjs'),
    expect: 'a tree of three does not collide with the same three plus a duplicate',
  },
  {
    // The Solidity side is a single pass with mutually exclusive branches, so
    // reordering it is a no-op and there is nothing to mutate. The JavaScript
    // side is three sequential replacements and IS order dependent. This is
    // that dependency, deleted.
    name: 'the js escaping puts the backslash last, collapsing it onto a real tab',
    file: 'lib/canonical.js',
    from: "  return String(s).replace(/\\\\/g, '\\\\\\\\').replace(/\\t/g, '\\\\t').replace(/\\n/g, '\\\\n');",
    to:   "  return String(s).replace(/\\t/g, '\\\\t').replace(/\\n/g, '\\\\n').replace(/\\\\/g, '\\\\\\\\');",
    run: HH('test/ledger.test.cjs'),
    expect: 'the escaping is invertible on every input tried',
  },
  {
    name: 'the field delimiter is dropped from the join',
    file: LG,
    from: '            out = abi.encodePacked(out, _esc(fields[i]), i == 8 ? "\\n" : "\\t");',
    to:   '            out = abi.encodePacked(out, _esc(fields[i]));',
    run: 'npx hardhat compile >/dev/null 2>&1; forge test --match-contract LeafEncodingTest',
    expect: 'a field boundary can be moved without changing the leaf',
  },
  {
    name: 'the leaf escaping is skipped on chain',
    file: LG,
    from: '            if (c == 0x5c)      { out[j++] = 0x5c; out[j++] = 0x5c; }',
    to:   '            if (false)          { out[j++] = 0x5c; out[j++] = 0x5c; }',
    run: HH('test/ledger.test.cjs'),
    expect: 'the chain computes the same seeded leaf as the library, escaping included',
  },
  {
    name: 'renounce guard counts configured anchorers rather than proven ones',
    file: LG,
    from: '        if (provenAnchorerCount < MIN_ANCHORERS_TO_RENOUNCE) {\n            revert NotEnoughProvenAnchorers(provenAnchorerCount, MIN_ANCHORERS_TO_RENOUNCE);\n        }',
    to:   '        if (anchorerCount < MIN_ANCHORERS_TO_RENOUNCE) {\n            revert NotEnoughProvenAnchorers(provenAnchorerCount, MIN_ANCHORERS_TO_RENOUNCE);\n        }',
    run: HH('test/ledger.test.cjs'),
    // The same assertion catches this and the threshold mutation above. Two
    // different ways of weakening one guard, one test that notices both.
    expect: 'one proven anchorer is not enough to renounce',
  },
  {
    name: 'a zero root accepted as an empty period again',
    file: LG,
    from: '            if (root == bytes32(0)) revert RecordsWithoutRoot();\n            if (recordCount == 0) revert RootWithoutRecords();',
    to:   '            if (root == bytes32(0) && recordCount != 0) revert RecordsWithoutRoot();\n            if (root != bytes32(0) && recordCount == 0) revert RootWithoutRecords();',
    run: HH('test/ledger.test.cjs'),
    expect: 'a zero root is not an empty period attestation',
  },
];

const FILES = [...new Set(MUTATIONS.map((m) => m.file))];
const BAK = (f) => path.join(ROOT, f + '.mutbak');

/**
 * Crash-safe restore, and it has to happen BEFORE the baseline is taken.
 *
 * The per-mutation `finally` and the signal handlers both need the event loop,
 * and `execSync` blocks it: a SIGTERM from a timeout, or a SIGKILL, lands while
 * a contract is mutated and neither ever runs. It happened, and the mutated
 * source sat on disk afterwards. A sidecar written before the mutation
 * survives anything, so this invocation puts the tree back before doing
 * anything else.
 *
 * The ordering is the whole point and it was wrong. ORIGINAL used to be read
 * at module load, above this loop, so after an interrupted run the baseline
 * was the MUTATED text. restoreAll() then wrote the mutation back over the
 * file this loop had just recovered, the verification below compared it
 * against the same poisoned baseline and passed, and the run ended by printing
 * "all sources restored and rebuilt" over a guard-deleted contract that
 * `npx hardhat compile` then baked into the artifacts. The sidecar existed
 * exactly for this failure and the recovery undid itself.
 */
for (const f of FILES) {
  if (fs.existsSync(BAK(f))) {
    fs.writeFileSync(path.join(ROOT, f), fs.readFileSync(BAK(f)));
    fs.unlinkSync(BAK(f));
    console.log(`restored ${f} from a previous interrupted run`);
  }
}

// Every file any mutation touches, as it is NOW, after the recovery above.
const ORIGINAL = new Map(FILES.map((f) => [f, fs.readFileSync(path.join(ROOT, f), 'utf8')]));
function restoreAll() {
  for (const [f, text] of ORIGINAL) {
    const p = path.join(ROOT, f);
    if (fs.readFileSync(p, 'utf8') !== text) fs.writeFileSync(p, text);
  }
}


function run(m) {
  const p = path.join(ROOT, m.file);
  const original = fs.readFileSync(p, 'utf8');
  if (!original.includes(m.from)) {
    return { name: m.name, status: 'SKIP', detail: 'anchor text not found; the mutation is stale' };
  }
  fs.writeFileSync(BAK(m.file), original);
  fs.writeFileSync(p, original.replace(m.from, m.to));
  let out = '', failed = false;
  try {
    out = execSync(m.run, { cwd: ROOT, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
  } catch (e) {
    failed = true;
    out = (e.stdout || '') + (e.stderr || '');
  } finally {
    fs.writeFileSync(p, original);
    if (fs.existsSync(BAK(m.file))) fs.unlinkSync(BAK(m.file));
  }
  // The suite must fail, and it must fail on the named assertion. A suite that
  // fails for an unrelated reason, a compile error included, proves nothing
  // about the guard.
  // The assertion name must appear on a FAILURE line. The fallback that used
  // to sit here, `|| out.includes(m.expect)`, matched the same name printed in
  // the suite's PASS report, so for eighteen of the entries in this file
  // `named` was unconditionally true and the status collapsed to "the suite
  // failed somehow" - which is exactly the discrimination the comment below
  // claims to make. Demonstrated: deleting one guard and pairing it with an
  // assertion that still passes under that deletion reported CAUGHT.
  // `XX name` and `FAIL  name` from the hand-written suites, `[FAIL: name]`
  // from forge. All three are failure markers; nothing else in either output
  // puts one of these immediately before an assertion's own text.
  //
  // One optional token is allowed between the marker and the name, because
  // some suites parameterise an assertion by the case it is running:
  // merkle.differential.cjs prints `FAIL  n=300: the library refuses ...`.
  // The token may not contain whitespace or a pipe, so this still requires the
  // marker and the assertion name to be on the same line with at most one
  // label between them. It does NOT reopen the hole the paragraph above
  // describes: a PASS report line begins `ok  <name>`, which has no failure
  // marker anywhere before the name.
  const named = new RegExp(
    '(XX|FAIL:?)\\s+([^\\s|]{1,32}\\s+)?' + m.expect.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
  ).test(out);
  if (process.env.MUTATE_DEBUG) console.log(out.split('\n').filter((l) => /FAIL|XX /.test(l)).join('\n'));
  return {
    name: m.name,
    status: failed && named ? 'CAUGHT' : failed ? 'FAILED ELSEWHERE' : 'SURVIVED',
    detail: failed && named ? m.expect
      : (out.split('\n').filter((l) => /XX |Error|error/.test(l)).slice(0, 3).join(' | ') || out.slice(-300)).slice(0, 300),
  };
}

const filter = process.argv[2];
const chosen = filter ? MUTATIONS.filter((m) => m.name.includes(filter)) : MUTATIONS;
const results = [];
for (const m of chosen) {
  process.stdout.write(`... ${m.name}\n`);
  const r = run(m);
  results.push(r);
  console.log(`    ${r.status}  ${r.detail}`);
}
console.log('');
const w = Math.max(...results.map((r) => r.name.length));
for (const r of results) console.log(`${r.status.padEnd(17)} ${r.name.padEnd(w)}`);
const bad = results.filter((r) => r.status !== 'CAUGHT');
console.log(`\n${results.length - bad.length} of ${results.length} mutations caught`);
// The tree must be clean when this exits, whatever happened above. Each
// mutation restores its own file in a finally block; this is the check that it
// actually did, because a mutated contract left on disk would be shipped.
restoreAll();
for (const [f, text] of ORIGINAL) {
  if (fs.readFileSync(path.join(ROOT, f), 'utf8') !== text) {
    console.error(`RESTORE FAILED: ${f} does not match what it was at start`);
    process.exit(2);
  }
}
// A mutation whose anchor text is no longer in the source silently tests
// nothing. Reported as a failure, not as a skip.
const stale = MUTATIONS.filter((m) => !ORIGINAL.get(m.file).includes(m.from));
if (stale.length) {
  console.error('STALE MUTATIONS, anchor text not found:');
  for (const m of stale) console.error(`  ${m.name}`);
  process.exit(2);
}
// Rebuild from the restored sources. The artifacts on disk are otherwise those
// of the last mutation, and the next thing anyone runs - checkflat, which gates
// BscScan verification - reports a false mismatch against them.
try { execSync('npx hardhat compile', { cwd: ROOT, stdio: 'ignore' }); } catch (_) {}
console.log('all sources restored and rebuilt');
process.exit(bad.length ? 1 : 0);
