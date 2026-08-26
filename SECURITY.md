# Security status

This document states plainly what has and has not been done to these
contracts. It is updated when that changes.

## Not audited

**These contracts have not been audited by a third-party firm.**
There is no audit report, and we will keep saying so on every surface we
control until one exists. Do not treat anything below as a substitute.

## What has been done

### 1. Unit tests

350 assertions across `test/ledger.test.cjs`, `test/profitshare.test.cjs`,
`test/staking.test.cjs` and `test/faucet.test.cjs`, including every revert
path. `test/eventsigs.check.cjs` additionally checks every event the indexer
declares against the compiled ABIs, in both directions, because a hand written
signature list drifted twice and neither drift was visible in any test. Revert assertions are made with a raw `eth_call` carrying an explicit
sender, because gas estimation through a browser provider omits `from` and can
surface the wrong error.

```
npm run test:all
```

### 2. Static analysis

Slither 0.11.6 over the full source.

```
npm run analyze
```

Nine detector categories fire, 71 results. Every instance was reviewed by hand
and classified:

| Detector | Assessment |
| --- | --- |
| `reentrancy-balance` / `reentrancy-no-eth` / `reentrancy-benign` / `reentrancy-events` | Not exploitable. In `HCOWProfitShare` and `HCOWStaking` every function named carries OpenZeppelin `nonReentrant` off a single shared guard, so cross-function reentrancy is covered too, and the only cross-function paths Slither identifies are `view` functions. `HCOWFaucet` is the exception and has no guard: it writes `lastClaimAt` and both counters before either transfer, and it is a testnet contract holding stand-in tokens. The external calls are to HCOW and to BSC-USD, neither of which has a transfer hook. |
| `incorrect-equality` | Not applicable. The detector targets strict equality against balances. Every instance here is a zero check on an internally computed delta, or the Merkle root comparison in `HCOWLedger._verify`, which must be strict equality by definition. |
| `divide-before-multiply` | Intentional. `participants` and `slice` are amounts that are actually transferred, so they must be rounded to a token amount before being scaled into an accumulator. Reversing the order would credit shares that no transfer backs. |
| `timestamp` | Not applicable. `block.timestamp` is used for cooldowns measured in days, where validator drift of seconds is irrelevant. |
| `pragma`, `cyclomatic-complexity` | Informational. |

Static analysis finds known bug patterns. **It found none of the defects listed
in sections 4 to 17**, which is the honest measure of what it is worth.

### 3. Invariant (property) tests

Randomised state-machine testing. Long seeded sequences of real user actions
are executed against a fresh deployment, and a set of properties is re-checked
after **every single operation**. Reverts are expected outcomes and the
properties must hold through them.

```
npm run test:invariant
```

Latest run: 8 seeds per contract, zero violations. Seeds are fixed, so any
failure is reproducible from the printed seed and operation index.

`HCOWProfitShare` checks 17 properties, `HCOWStaking` 9. The full list is in
`test/invariant.profitshare.cjs` and `test/invariant.staking.cjs`. The two most
load-bearing are solvency (the sum of all claimable USDT never exceeds the USDT
held) and no value creation (claimed plus still-owed USDT never exceeds what
settlements actually credited).

Two properties and one action were added after the self-review below, because
the original suite could not have caught what it found:

- **I14, bonded HCOW is fully attributed.** The original `I7` bounded the
  per-account view from above only, so HCOW stranded behind shares nobody held
  would still have passed.
- **I15, `poolIndex` monotonic and live.**
- **A scripted adversarial action.** Actions were drawn independently, so the
  ordered sequence `requestUnbond -> settleEpoch -> cancelUnbond` by one actor
  never occurred. It is now generated deliberately. The settlement generator
  also produces dust-profit epochs, which uniform sampling never did.

### 4. Adversarial self-review, August 2026

Before commissioning a paid audit we ran an adversarial review of
`HCOWProfitShare` and `HCOWStaking` against the state of the code that had
passed everything in sections 1 to 3. It found defects. They are listed here
because a security document that only lists successes is not a security
document.

Each was reproduced with a proof of concept before being fixed, and each fix
carries a regression test.

| ID | Severity | Defect | Fix |
| --- | --- | --- | --- |
| C-1 | Critical | The per-settlement deduction cap bounded one settlement but not a sequence, and Rule 4 tested `profit != 0` rather than the participant payout. One wei of profit rounds the participant leg to zero while authorising a full-size burn. 400 settlements costing 400 wei of USDT in total reduced a 1,000,000 HCOW pool to 309 HCOW. | Rule 6 requires a real participant payout, and the deduction is rate limited. The rate limit went through several shapes across later rounds and its final form is `MIN_EPOCH_INTERVAL` of seven days plus `MAX_DECAY_PER_WINDOW_PPM` over thirty days: see A-1 and A-3 for the figures that actually hold. |
| H-2 | High | `requestUnbond` before a settlement and `cancelUnbond` after it avoided the deduction entirely, at gas cost, decided from the public mempool. The other participants absorbed the dodger's share. | `poolIndex` records cumulative pool decay. A cancelled unbond rejoins scaled by the decay it sat out, and the difference is burned. A genuine exit still pays nothing. |
| M-4 | Medium | The cap was computed against the live pool, so any participant could shrink the pool in front of a signed settlement and force it to revert, then cancel at no cost. Repeatable indefinitely. | `settleEpoch` takes a rate in parts per million, not an HCOW amount. The contract computes the amount from its own figure, so a front-run cannot invalidate it and the settler cannot overstate it. |
| M-5 | Medium | `uint128` downcasts on share and stake amounts wrapped silently rather than reverting. Reachable as a second-order consequence of C-1. | `SafeCast` on every downcast in both contracts. |
| M-1 | Medium | `updateRepresentative` could repoint `payout`, redirecting commission that had already accrued to the previous address. `claimCommission` is permissionless, so the owner did not have to call it. | Accrued commission is settled to the outgoing address before `payout` changes. |
| M-3 | Medium | `_repIds` only grew and `fundRewards` loops it twice, about 7,500 gas per registered representative on every future round. Enough registrations would push it past the block gas limit on a non-upgradeable contract, permanently ending reward distribution. | `MAX_REPRESENTATIVES = 100`. |
| L-1 | Low | `cancelUnstake` was gated on the representative being active, so the owner could convert a cancellable unstake request into a forced exit. Principal and accrued rewards were never at risk: `withdrawUnstaked`, `claimHcow` and `redelegate` all remain open. | The gate is removed. Cancelling restores a position the delegator already held; it is not a new delegation. |
| L-8 | Low | `bondedOf` rounds down, so `totalShares` can reach zero while `totalBondedHcow` retains dust, contradicting a comment and allowing a division by zero. | The deduction path is explicitly guarded on `totalShares > 0`. |

### 5. Second review round, same day

The fixes above were themselves reviewed, on the principle that code written
under time pressure to close a Critical is the most likely place to find the
next one. Two of them were incomplete.

| ID | Severity | Defect | Fix |
| --- | --- | --- | --- |
| R-1 | High | The `poolIndex` charge was applied in `cancelUnbond` only. `withdrawUnbonded` still paid out in full, so the dodge survived intact: request an unbond, let the settlement pass, wait out the seven-day cooldown, withdraw everything, bond again. The first fix taxed only the people who changed their mind. | Both exit doors are priced identically. A position pays for every settlement it was present for, whichever way it leaves. |
| R-2 | High | Rule 6 tested `participants != 0`, which is satisfied by two wei of profit. One wei was blocked and two wei bought a full 2% burn. An incomplete fix to the Critical it was written for. | `MIN_PARTICIPANT_USDT`, one USDT, as a sanity floor. The economic bound remains the rate limit, not the attacker's cost. |
| R-3 | Medium | `cancelUnbond` credited the forfeited HCOW to `totalHcowDeducted`, so that figure stopped reconciling with the sum of the settled epochs it is supposed to summarise. | A separate `totalHcowForfeited`. `totalHcowDeducted` now equals the sum of every `Settlement.hcowDeducted` and nothing else. |
| R-4 | Low | `_bookmark` ran after the forfeit burn, so an HCOW with a transfer hook could read an inflated `claimableOf` mid-burn. State-changing reentry was already blocked by `nonReentrant`. | The bookmark moved above the external call. |
| R-5 | Low | `updateRepresentative` performed its new commission transfer before writing `r.payout`, and carried no reentrancy guard. With a hooking token the old payout could re-enter `fundRewards` and accrue fresh commission under the old address. | `nonReentrant`, and all effects written before the transfer. |
| R-6 | Low | `poolIndex` at 1e18 degraded under sustained maximum-rate deduction and could floor to a value where a single settlement charged tens of percent. | The index is a running product, so it now carries 1e27 precision and decays by the stated rate rather than by the rounded amount. |

### 6. Third review round: HCOWLedger and HCOWFaucet

Reviewed after the two contracts above, and fixed in the same pass.

| ID | Severity | Defect | Fix |
| --- | --- | --- | --- |
| G-1 | Critical | `nextEpoch` started at zero while the anchoring worker derives the period from the wall clock. A deployment today would have needed roughly half a million catch-up transactions before it could anchor the current hour, with no fast-forward path and no setter. The end-to-end test rebased every timestamp to keep epochs at 0, 1, 2, which is exactly why nobody saw it. | `genesisEpoch` is set from `block.timestamp` at construction and the cursor starts there. The worker reads it and refuses to run if the cursor is below genesis, which is a configuration error. A genuine backlog is different and is drained rather than refused: `MAX_CATCHUP_EPOCHS` caps the work per run at thirty days and successive runs continue. The end-to-end test now runs at the real epoch number. |
| G-2 | Critical | Three ways for two different records to hash to one leaf: unpaired surrogates collapsed to U+FFFD by `TextEncoder`, database nulls stringified to `"null"`, and integers past 2^53 losing precision. Any of them lets one anchored leaf stand for more than one record, which is the substitution the whole scheme exists to prevent. | Canonicalisation rejects ill-formed strings, requires NFC, and requires safe integers with no negative zero. The database reader refuses null and parses integers from their string form. |
| G-3 | High | A stolen anchorer key could anchor empty roots forward past the current hour, permanently consuming the epoch namespace for about thirty cents a year. Revoking the key would not give it back. | An epoch may only be anchored once its period has ended. A stolen key is confined to the past. |
| G-4 | High | Nothing stopped the same root being anchored to more than one epoch, so a receipt verified in several periods at once and "this round belongs to hour N" was the operator's choice rather than the chain's. | A root may be anchored once **to a live epoch**. Historical batches are deliberately outside that rule and outside the sequence: `anchorHistorical` neither reads nor writes `rootAnchored`, because writing it in both let a backfill consume a root a live epoch then needed and bricked the ledger. A historical root can be re-submitted, and `totalRecords()` counts whatever a historical batch asserts, so neither is a chain-proven figure. |
| G-5 | High | Leaf and node hashes shared a preimage space, and an odd node was promoted rather than paired, so two different leaf sets could produce one root and a shortened proof let the root itself be presented as a record. | Node hashes carry a `0x01` prefix, odd nodes are paired with themselves, and the proof length must equal the depth implied by the record count. The separation is now structural rather than an argument about collision difficulty. |
| G-6 | Medium | The published `LEAF_DOMAIN` was the seeded tag, but the sixteen puzzle and arcade titles use a different one. An independent verifier following the on-chain constant would fail on every skill record. | `LEAF_DOMAIN_SEEDED` and `LEAF_DOMAIN_SKILL`, both published. |
| G-7 | Medium | The faucet required both token balances before dispensing either, and USDT drains fifty times faster than HCOW, so the expected steady state was a faucet holding tens of millions of test HCOW and refusing to give any of it out. | Each side is dispensed on its own. Refusal only when both are short. |
| G-8 | Low | `setAmounts(0, 0)` let a claim succeed paying nothing while still burning the caller's cooldown, and reported an infinite number of claims left. A faucet deployed with one address for both tokens bricked on its first claim. `anchorHistorical` accepted a range ending in the future. `smoke.cjs` would anchor fabricated data into whatever ledger it was pointed at. | All four refused outright. |

### 7. Fourth round: the two design changes

The three rounds above fixed defects without changing what the contracts do.
These two change it, because the problem was the mechanism rather than a
mistake inside it. Both were known and deferred; deferring them turned out not
to be viable, because a partial fix in either place is trivially routed around.

| ID | Severity | Defect | Fix |
| --- | --- | --- | --- |
| D-1 | High | `HCOWProfitShare` credited the participant leg to whoever held shares at the instant of settlement. No time weighting, no eligibility delay, and settlement parameters are visible in the mempool, so a holder could bond immediately before a settlement, take a full pro rata cut of a quarter's profit for one block of exposure, and unbond. Measured: an arrival with nine times the pool's stake took nine tenths of the distribution. | Shares bonded during the open epoch are principal immediately, so they back `bondedOf` and absorb deduction, but they do not earn until that epoch closes. `accAtEpoch` records the accumulator at each settlement, so a position is credited for every epoch after the one it joined even if the account is never touched in between. |
| D-2 | High | `HCOWStaking` split each funding as a lump sum by instantaneous weight. A position staked for one block earned what a position staked all quarter earned, and `redelegate` was free and instant, so commission could be avoided entirely by moving to a zero commission representative around a funding round. | Rewards stream per second over a declared period. There is no moment to jump into or out of. Measured: 900,000 HCOW staked for ten seconds of a 90,000 second period now earns 0.89 HCOW rather than most of the round. Commission is taken at the rate that was in force while the reward accrued, using a per representative anchor, so changing it never reaches backwards and a hop cannot claw it back. |

Two consequences worth stating plainly. `fundRewards` now takes a duration,
between one day and one year, and seconds that elapse with nothing staked are
carried into the next period rather than handed to whoever stakes first.
And the `active` flag on a representative now gates new delegations only, not
accrual: punishing a delegator for a decision the owner made about their
representative was never the point of the flag, and it stranded them mid
cooldown.

### 8. Fifth round: reviewing the two design changes

Both changes in section 7 were then reviewed, with two independent oracles for
the staking side: a transcription of the contract's own arithmetic, and a
segment-wise exact integrator that closes a segment on every state change. Two
defects were found in the profit share change. The staking change survived
around five thousand randomised operations with no accounting error, which is
recorded here because a review that only lists what broke is not a review.

| ID | Severity | Defect | Fix |
| --- | --- | --- | --- |
| E-1 | High | The deduction gate tested `participants`, but the eligibility change added a later branch that zeroes that same variable and refunds the settler when nobody is eligible. Gate and payment came apart, so an epoch that distributed nothing could still burn 2% of the pool. Reachable on launch day, when every bonded position is an arrival. | The gate tests what actually reaches participants, `eligibleShares` included. |
| E-2 | Medium-High | Quarantine was measured in settlements, and an epoch that distributes nothing costs nothing to produce. Two settlements in adjacent blocks released an arrival for free and handed it the whole of the next distribution: measured at 90% of a 3,000 USDT leg for two blocks of exposure, the same split the change was written to prevent. | `MIN_EPOCH_INTERVAL`, so an epoch is a period of time rather than a call. `DEDUCT_COOLDOWN` was removed as redundant. The interval was one day at this point and was raised to seven in A-3, because one day was still short enough to buy eligibility for a quarterly distribution. |
| E-3 | Medium | In `HCOWStaking`, `fundRewards` reset `periodFinish` unconditionally, so one wei on a year long duration stretched the entire remaining budget behind it. Measured: a sole staker holding 15,694 HCOW instead of 100,000 six days later. Repeatable every block by the funder, who is not the owner, and irreversible by anyone else. | A funding may never slow the stream it replaces. |
| E-4 | Low | The accumulator's granularity is `totalStaked / ACC_PRECISION` wei per call, so at 1e18 against an 18 decimal token a slow stream over a large pool stranded a real fraction of it, owed to nobody and recoverable by nobody. Measured at 23% of a period in the extreme. | `ACC_PRECISION` raised to 1e24, six orders finer. Every product it appears in now divides before multiplying again, so the headroom is unchanged even with a one wei pool absorbing the whole supply. |
| E-5 | Low | `_rewardsOwed` could drift below the sum of individual claims through repeated floor differences, eventually reverting the last claimant with an arithmetic panic. | The three decrements are clamped. The counter is documented as a reserve rather than a sum: each account's credit is the difference of two independently floored figures, so adding up every view can land up to one wei per delegator above it. Solvency is maintained against the token balance, which is what the invariant suite checks. |

### 9. Full audit pass, both economic contracts

Rounds 1 to 5 chased specific changes. This one was a full audit of
`HCOWProfitShare` and `HCOWStaking` from scratch, run as a paid engagement
would be: scope and trust model, access control, arithmetic, liveness,
external interactions, economics, code quality, with proof of concept for
every finding. It produced the largest single batch, including two defects in
work from the previous round.

| ID | Severity | Defect | Fix |
| --- | --- | --- | --- |
| A-1 | Critical | The per settlement cap bounds a mistake but not a campaign. At two percent a day a compromised settler reduced a 1,000,000 HCOW pool to 627 HCOW in a year, for 730 USDT of funding, 370 of which came back through the two fixed legs. | `MAX_DECAY_PER_WINDOW_PPM`, three percent per window, on top of the per settlement cap. Windows are fixed rather than sliding, so two can be packed and the honest worst case over an arbitrary thirty days is six percent. The published usage rule decays about half a percent a month, so this is six times the headroom honest operation needs. |
| A-2 | High | A pending unbond kept paying the deduction rate forever, including long after its cooldown had run out. Measured: a position that was slow to press withdraw lost 999,372 of 1,000,000 HCOW. The position was not in the pool for any of those settlements. | The charge stops at `unbondReadyAt`. `poolIndexAtEpoch` and `settledAtEpoch` make the window exact, and `MIN_EPOCH_INTERVAL` against `UNBOND_COOLDOWN` bounds the walk to two settlements. |
| A-3 | High | Quarantine ended at the next settlement and the floor on epoch length was one day, so an arrival could buy eligibility for a quarterly distribution with one day of exposure. Measured: 270,000 of a 300,000 USDT leg. | `MIN_EPOCH_INTERVAL` raised to seven days, matching `UNBOND_COOLDOWN`. Becoming eligible now costs the same real time as leaving. |
| A-4 | High | Both exit doors called the token's own `burn`. HCOW is not in this repository; a burn that is absent, paused or role gated would have locked every pending position permanently, on a contract with no admin recovery. | Consumed principal is transferred to the standard burn address. That works against any ERC20 and removes supply just as verifiably, and no exit depends on an external function any more. |
| A-5 | High | In `HCOWStaking`, the funding guard blocked slowing the stream but not compressing it. One wei on the minimum duration pulled a year's budget into 24 hours; measured, a same-block arrival took 9,872,876 of a 10,000,000 HCOW budget. The mirror image of the defect fixed in the previous round. | A funding may add tokens or add time. It may never move the rate down or the end date in. |
| A-6 | High | `accRewardPerShare` could be inflated without bound by funding into a pool of a few wei, after which an ordinary sized position overflowed on every path that touched it, locking principal permanently. Measured: 82,708,635 HCOW stuck, 41% of supply. | 512 bit intermediates through `Math.mulDiv` at every site in both contracts, plus `MIN_STAKE_FOR_ACCRUAL`: below one HCOW staked, seconds are carried rather than distributed. |
| A-7 | Medium | A single dominant participant could veto every deducting settlement by front running it with an unbond request, free and repeatable. Introduced by the previous round's fix. | With nobody eligible there is nothing to charge, so the deduction is dropped rather than the settlement refused. |
| A-8 | Medium | `settleEpoch` paid the two fixed legs out of the figure it requested rather than the figure that arrived, so a lossy USDT would have taken the shortfall out of the participant reserve and frozen every claim. BSC-USD sits behind an upgradeable proxy. | The arrival is measured, exactly as `bond` already did for HCOW, and a shortfall reverts. |
| A-9 | Medium | Carried reward funds had no release path except a further funding with fresh tokens, and there is no sweep. A launch that funds before anyone stakes stranded the whole amount. | **Attempted, then withdrawn.** A zero-amount funding path was added and removed: it read the carried figure before advancing the accumulator, so it failed in exactly the state it existed for. Carried funds are released by the next ordinary funding, which needs only to keep the rate non-zero. Accepted as an operational requirement rather than a code path. |
| A-10 | Medium | `MAX_REPRESENTATIVES` was a permanent ceiling with no deregistration: a typo'd id or ordinary churn consumed slots for good. | **Attempted, then withdrawn** after it produced B-1 below. A record reads empty the moment a delegator requests a full unstake, while their delegation still points at it, so "empty" is not a safe test for "unused". The ceiling is permanent again and is disclosed as accepted risk. A representative can be retired with `updateRepresentative(active=false)`; its slot is not reclaimable and its name cannot be changed. |
| A-11 | Low | `lifetimeOf` reported none of the principal a position lost through the unbond path, so a dashboard built on it showed zero while a tenth of the position had been burned. Accumulator precision was 1e18 against an 18 decimal token, stranding whole distributions when the participant leg was small. `commissionOf` returned zero for an unregistered id where its sibling reverts. | Forfeits fold into the per account figure; precision raised to 1e24 with mulDiv throughout; unknown ids revert. |

### 10. Review of the audit pass fixes

| ID | Severity | Defect | Fix |
| --- | --- | --- | --- |
| B-1 | Critical | `deregisterRepresentative` checked that a representative held no weight, no delegators and no commission. A full unstake produces exactly that state while the delegation still points at the record and can be cancelled back into it. Removing it there let `cancelUnstake` recreate a representative outside the registry, at zero commission, with 1,000 HCOW of live stake attributed to nobody. Re-registering the same id then wiped the delegator's accrued rewards: measured, 1,296,000 HCOW gone in one transaction. | The feature was deleted rather than guarded. A counter-based fix was written and discarded: the finding showed the emptiness test itself was the wrong idea, and adding state to prop it up was the kind of change that had been producing these findings in the first place. |
| B-2 | High | Stopping the pending-unbond charge at the cooldown made the withdraw door strictly cheaper than the cancel door for the same end state, so the step-out-and-return dodge was free again and the forfeit in `cancelUnbond` became unreachable. Measured: dodger keeps 100,000 HCOW where an honest holder keeps 94,119. Charging every settlement forever, which is what it replaced, was equally wrong in the other direction. | Exactly one settlement is charged, the first after the request, priced identically at both doors. |
| B-3 | High | The thirty day ceiling was metered as a movement in `poolIndex`, which says nothing about how much HCOW was destroyed. With most of the pool in pending unbonds, two settlements at the cap burned 30 HCOW of a 1,001,000 reserve and exhausted the window, locking the settler out of any deduction for thirty days. A dominant holder could trigger that deliberately and repeat it. | The window is metered in HCOW. The first attempt measured it against a reserve snapshotted when the window opened, which was itself wrong; see C-2 below. |
| B-4 | High | The carried-funds path read `undistributed` before advancing the accumulator, so it rejected the call in exactly the state it exists for: a pool that emptied and was left idle has the carried seconds only implicitly until some call materialises them. | The check runs after `_updateGlobal` and after the transfer. |
| B-5 | Medium | `MIN_REWARD_DURATION` was applied to the absolute duration while the extension rule demanded a duration reaching the current end date. In the last day of a period the two had no intersection unless the funder supplied an outsized top-up. | The floor applies to a fresh period; a live one may be extended to its own end date. |
| B-6 | Low | `totalRewardsOwed()` counted seconds that `_updateGlobal` would carry rather than reserve, double counting them against `undistributed`. | The view mirrors the state machine's condition exactly. |

The decay window is fixed rather than sliding, so two adjacent windows can pack
their allowances back to back and a rolling thirty days can reach close to
twice `MAX_DECAY_PER_WINDOW_PPM`. That is stated in the contract rather than
rounded down.

### 11. Final review before freeze

The two changes above were reviewed once more. Both had a defect, and both are
recorded here rather than quietly corrected, because the pattern is the point:
every round in which new state or a new feature was introduced produced a
finding, and the rounds that removed things did not.

| ID | Severity | Defect | Fix |
| --- | --- | --- | --- |
| C-1 | High | `fundRewards` folded the absolute `MIN_REWARD_DURATION` into the "must reach the current end date" rule, and in doing so dropped it whenever a period was live. In the last seconds of a period any duration was accepted, so a top up could be released into a one second window. Measured: 999,980 of a 1,000,000 HCOW funding taken by a same block arrival. A-5 in a smaller window. | Both floors apply, and the binding one is whichever is larger. |
| C-2 | High | The decay ceiling was measured against a reserve snapshotted when the window opened, and never reconciled with it again. Capital parked in the pool at that instant and withdrawn a block later still counted, so the ceiling could be inflated for free: measured, a victim pool lost 7.76% inside a window whose stated ceiling was 3%. The mirror also held, a pool that grew after the snapshot was held to an allowance sized for one that no longer existed, which is B-3 returning. | Superseded by E-2 in section 14. The ceiling has no base at all any more. |
| C-3 | Low | The off-chain event indexer still declared the pre-change signatures for `UnstakeCancelled` and `RewardsFunded`, so both were being dropped silently. Several figures in this document described controls that had since been removed or reshaped. | Signatures updated; the affected rows above now say what was withdrawn and why. This fix was itself incomplete: see E-6 in section 14, which is why signatures are now checked by a test rather than by reading. |

### 12. Open, not yet fixed



Stated here rather than discovered later.

- **The seed commitment is not independently timestamped.** For seeded rounds
  `serverSeedHash` and `serverSeed` are both fields of the same record,
  anchored together after the round settled, and the chain never sees either
  on its own. `keccak(seed) == hash` is a relation that can be satisfied at any
  time, so it proves the revealed seed is the one this record was written with
  and nothing more. It does **not** prove the outcome was fixed before play.
  Closing it needs the commitment published on chain ahead of the round. The
  stronger claim has been removed from the README and from the public verifier
  page, and should not be made anywhere else until the mechanism exists.
- **Omission is not covered.** The ledger proves a record was not altered. It
  does not prove that every record was included: `recordCount` is asserted by
  the anchorer and there is no non-inclusion proof, so a round left out of a
  tree is undetectable from the chain.
- **Ownership transfer is single step** in all four contracts. A mistyped
  address is final. Left as it is deliberately: at this point in the review
  every round that added code produced a finding, and this one is disclosed
  rather than patched under time pressure.
- **`HCOWToken` and `HCOWVesting` are not in this repository.** They hold the
  entire supply and the unlock schedule and live in `hcow-contracts`. They were
  reviewed for the first time in section 14 and must be inside the external
  audit scope. See the scope note at the top of the README.
- **`recordCount` is asserted by the anchorer** and is not bound to the tree,
  so published record totals are not chain-proven figures even though the
  proofs themselves are. Do not quote the totals as if they were.
- **The revenue and cost figures are produced off chain.** No contract can
  audit an Apple or Google bank transfer. What is enforced is that the
  published waterfall cannot be edited afterwards and that the money actually
  moved.
- **`hcowToDeduct` is derived from a policy, not from an oracle.** The contract
  enforces the ceiling and the rate limit. It does not and cannot verify that
  the rate matches the published value rule.
- **Rounding dust is not recoverable.** Both contracts round in the protocol's
  favour and neither has a sweep function.
- **A newly bonded position absorbs the next deduction while earning nothing
  from it.** Eligibility is deferred by one epoch so that a same-epoch arrival
  cannot claim that epoch's revenue, but the pool decays uniformly, so a bond
  made just before a settlement pays up to 2% and receives no distribution for
  it. Charging new shares separately would need a second decay index applying
  to pending unbonds as well, and at this point in the review every round that
  added state produced a finding. Disclosed rather than patched.
- **`MIN_PARTICIPANT_USDT` is an absolute floor, not a proportional one.** One
  USDT reaching participants satisfies Rule 6 regardless of pool size, so a
  determined settler can run the rate ceiling at a token outlay. The decay
  window ceiling is what actually bounds the loss, and it is 3% per window,
  which because the window is fixed rather than sliding means up to 6% over an
  arbitrary thirty days. Rule 6 only stops a deduction with no distribution at
  all.
- **`undistributed` has no delivery date.** Rewards that accrue while the pool
  is below `MIN_STAKE_FOR_ACCRUAL`, plus division remainders, carry into the
  next funding. Between periods the reward funder can attach them to a duration
  of up to `MAX_REWARD_DURATION`. Nothing is destroyed, and the funder can
  already decline to fund at all, so this is the same liveness dependency
  stated below and not a new power.
- **The Supabase service-role key can insert rounds that then anchor as
  genuine.** The chain proves nothing was altered after anchoring; it says
  nothing about what was true before it. `record-round` has rate limits, not
  authentication, so a caller who can reach the endpoint can write rounds. This
  key belongs in the wallet and key inventory alongside the anchorer, and it is
  not currently in any role document.
- **The faucet's global ceiling bounds the drain rate, not a funded Sybil.**
  250 claims per interval and no contract callers means one address cannot
  empty it in a block. Someone willing to fund many EOAs can still take a
  day's allocation. It is a testnet contract holding stand-in tokens; the
  exposure is the public testnet campaign, not money.
- **Consumed principal is transferred to `0x…dEaD`, not burned through the
  token.** That removes the dependency on an external `burn()` (A-4) and adds a
  smaller one: the deployed HCOW must permit transfers to that address and
  charge no transfer fee. It also means `totalSupply()` never moves, so any
  circulating or burned figure must read `balanceOf(0xdEaD)` rather than
  subtracting from supply. Both are mainnet deployment gates.

### 13. Deployed-bytecode parity

`scripts/checkflat.cjs` compiles each flattened source standalone and compares
creation bytecode against the Hardhat artifact, stripping the trailing
metadata hash. All six match, zero differ.

Run `rm -rf artifacts cache` before any Slither run. Slither reads every
build-info file Hardhat has ever written, so a stale one makes it report on
code that no longer exists. A report produced without clearing them once ran to
1,259 lines, half of it about deleted contracts.

### 14. System-level audit, 25 August 2026

The eleven rounds above were each conducted per contract. That is the reason
this one exists: asked whether the review was looking at the whole system, the
honest answer was no. It was not. The first thing a system-level pass found was
that `HCOWToken` and `HCOWVesting`, which between them hold 100% of the supply
and the entire unlock schedule, had never been reviewed at all and were not in
the audit scope. Five independent passes were then run: `HCOWProfitShare`,
`HCOWStaking`, `HCOWLedger` with `HCOWFaucet` and the off-chain pipeline,
`HCOWToken` with `HCOWVesting`, and a cross-system pass over both repositories,
the deployment procedure, the role matrix and every factual claim in the
documents.

Everything below was reproduced with a script before it was written down.

**In `HCOWVesting`, the two highest-consequence findings in the whole review.**

| ID | Severity | Defect | Fix |
| --- | --- | --- | --- |
| E-1 | Critical | Missing the TGE date destroyed the entire balance. `seal()` refused to run at or after `tgeTime`, `release()` refused to run before the seal, `renounceOwnership` always reverted, and there is no sweep. Funding comes before sealing by construction, so the tokens are already inside. Measured: 200,000,000 HCOW, 100% of supply, locked with no recovery by anyone, forever. Of the orderings of add, fund, seal and the passing of TGE, only those in which a successful seal precedes TGE survived, and every ordering in which TGE arrives first is terminal. This was self-inflicted: the `NotSealed` gate that closed the pre-seal drain window created it. | `seal()` has no deadline any more. `addSchedule` is what closes at `tgeTime`, which is where the danger actually was: a schedule written moments before a seal could otherwise unlock in the same block. A missed date is now a delay. |
| E-2 | High | A schedule with no cliff and no linear period released 100% at TGE whatever `tgeBps` said, while `totalTgeUnlock()` reported the `tgeBps` figure. The commitment `seal()` checks was therefore not the thing that happens. A dropped fifth argument produces it: the published table loaded with Public as `(60,000,000, 1500, 0, 0)` sealed cleanly against `27,000,000` and unlocked `78,000,000`. At `(200,000,000, 1, 0, 0)` the understatement is ten thousandfold. | `addSchedule` refuses a partial TGE unlock with neither period, and `totalTgeUnlock()` now runs the same vesting maths `release()` runs rather than summing basis points, so the committed figure and the released figure cannot diverge. |
| E-3 | High | Transposing `cliffMonths` and `linearMonths`, the classic error for two adjacent same-typed arguments, left the beneficiary count, the scheduled total and the TGE unlock all exactly correct. Every check in the contract passed. Measured: Seed's `cliff 0 / linear 3` became `cliff 3 / linear 0` and dropped 15,000,000 in one block; Team's lockup silently became 36 months of nothing. The per-schedule readback in the runbook was the only defence, and a runbook is what gets skipped. | `seal()` takes a fourth argument, a running hash over every schedule field by field. It is the only value that moves when this happens. |
| E-4 | Medium | `addSchedule` bounded the running total against the token's **live** `totalSupply()`, and the published allocation is exactly `INITIAL_SUPPLY`. HCOW is burnable, so a holder of one wei could permanently prevent the published table from being loaded. Measured: the eighth schedule loads and the ninth is refused, and since `tgeTime` is immutable the only repair is a full redeploy. | The bound is snapshotted in the constructor. |
| E-5 | Low | `transferOwnership` was blocked after sealing and `renounceOwnership` always reverted, but `Ownable2Step.acceptOwnership` was not overridden, so a transfer started before the seal completed freely afterwards and changed `owner()` on the explorer. No fund risk; the claim was simply false. Also: a TGE timestamp arbitrarily far in the future was accepted, and `seal()` looped over an unbounded array. | `acceptOwnership` is refused after sealing and `seal()` clears any pending owner. TGE is capped at one year out and the beneficiary list at 200. |

**In `HCOWProfitShare` and `HCOWStaking`.**

| ID | Severity | Defect | Fix |
| --- | --- | --- | --- |
| E-6 | High | The participant leg was divided across the eligible shares alone, so it went entirely to whoever arrived first however small they were. Measured: one wei bonded in epoch 0, a 10,000,000 HCOW cohort bonded in epoch 1, and the settlement paid the one wei **300,000 USDT** and the cohort nothing, while the cohort funded 200,000 HCOW of the burn. | The leg is scaled to the eligible fraction of the pool and whatever the eligible pool cannot take goes to gameCompany and team, named in `gameCompanyUsdt` and `teamUsdt`. Took four attempts: F-1 and F-2 in section 15, G-1 and G-2 in section 16, H-1 in section 17. |
| E-7 | Medium | The decay window ceiling **was** vetoable, directly contradicting C-2 above and the comment written beside it. A dominant holder requesting an unbond in front of a settlement shrank the live pool, the ceiling shrank with it, the settlement reverted with `DecayWindowExhausted(2996.25, 12624.84)`, and cancelling cost the holder **0.0**. Every ceiling with a base can be moved by moving the base: live invites the veto, snapshotted invites the parking, and counting pending unbonds loosens the rate bound for everyone else. | The ceiling is a rate. `decayWindowPpm` accumulates `deductPpm` against `MAX_DECAY_PER_WINDOW_PPM` and there is no base at all. The bound this gives is on the **bonded** pool, and because the window is fixed rather than sliding the honest worst case over an arbitrary thirty days is twice `MAX_DECAY_PER_WINDOW_PPM`, 6% and not 3%. See section 15. |
| E-8 | Medium | The two funding floors in `fundRewards` conflicted, so during the final `MIN_REWARD_DURATION` of **every** period no top-up was accepted however large. Measured: 9,900,000 HCOW rejected with 60 seconds remaining. B-5 reintroduced verbatim by the C-1 fix. | The rate floor is taken against `minDuration` rather than against whatever is left of the old period. The first attempt waived the floor instead and was a defect: see F-3 in section 15. |

**In `HCOWLedger`, `HCOWFaucet` and the off-chain pipeline.** These are not in
the audit scope and they are where the two worst findings of the round were.

| ID | Severity | Defect | Fix |
| --- | --- | --- | --- |
| E-9 | Critical | **One unauthenticated HTTP request killed the ledger permanently.** `record-round` validated `serverSeedHash` and `serverSeed` as strings and never checked that one hashed to the other. The anchorer *did* check, and threw. Epochs are strictly sequential, the table is append-only by trigger, and the endpoint is deployed `--no-verify-jwt`. Measured: the cursor froze at epoch 496577 while the clock ran on, and the gap grew by one every hour forever. No wallet, no key, no cost. | The commitment is checked at the door. The anchorer additionally gained an explicit operator quarantine path, off by default, so a row that somehow reaches the table can be excluded and published as excluded rather than stopping the sequence. |
| E-10 | High | The faucet was emptied by one funding address in five transactions: a factory deploying a throwaway claimer per allowance took all 5,000,000 test HCOW for about 0.034 tBNB, and reported `claimerCount = 100` while doing it. The per-address cooldown is untouched by this, so the previous "always spend the cooldown" fix did nothing about it. | Contract callers are refused, and a global ceiling of 250 claims per interval means the faucet cannot drain faster than it can be refilled. The ceiling needed an owner reset and a `status()` field, which the first attempt lacked: see F-4 in section 15. |
| E-11 | Medium | Up to 300 seconds of every hour, an accepted round landed in an epoch that had already been anchored, and was then unanchorable forever: no receipt, no verification, and a silent hole in a ledger whose whole claim is that it has none. Measured: 300 of 3,600 submission seconds, 8.3% of the hour. | `endedAt` is clamped to the current epoch at the door. |
| E-12 | Medium | Three governance events on the money contract were never indexed: `SettlerChanged`, `RecipientsChanged` and `OwnershipTransferred` were declared against `HCOWStaking`, which emits none of them. `RecipientsChanged` was additionally declared non-indexed while the contract indexes both parameters, which is the identical topic0 with an incompatible layout, and `parseLog` throws rather than returning null on that. There was no try/catch, so the throw would have propagated out and stopped the indexer permanently. C-3 above claimed these were fixed. | Declarations corrected and the ledger added as a third source. `decodeArgs` catches. Most importantly `npm run test:eventsigs` now checks every declaration against the compiled ABIs in both directions, so this cannot drift again unnoticed. |
| E-13 | Medium | The anchorer paged Supabase with `LIMIT`/`OFFSET` over `(ended_at, round_id)`, which is not unique: the database key is `(game_id, round_id)`. Postgres may order a tie differently between two pages, which silently skips a row or returns it twice. A skipped row is a hole; a repeated one makes `buildTree` throw and stalls the sequence exactly as E-9 did. | Paged on the primary key with a keyset cursor, and `game_id` breaks the sort tie deterministically. |
| E-14 | Low | Two ordinary administrative calls killed the ledger: removing the last anchorer and then renouncing ownership left a contract that can never anchor again. Also, the `verify.html` lede still claimed the seed was "published before the round was played", the retraction having landed in the documents but not in the page; the page's local root comparison accepted receipts the contract rejects, because it checked neither the proof length against the record count nor that the epoch was in range; a string `proof` threw outside every `try` and the page silently did nothing; the stall alarm keyed on an exception class that the actual stall does not use; and the RPC failover pattern treated "rate limit exceeded" as a range refusal, suppressing failover for the exact condition the endpoint list exists for. | All six fixed. The page now calls `verifyEpochRecord` on chain as the authoritative answer and explains a local mismatch rather than ruling on it. |

**In the documents.** Sixty factual claims in `SECURITY.md`, the two READMEs
and the deployment notes were checked line by line against the code as it
stands. Twelve were false, including the assertion counts, the detector count
and list in section 2, the claim that every reentrancy-flagged function carries
a guard (`HCOWFaucet` does not), the G-4 claim that a root may be anchored once
"live or historical", C-3 above, and the vest repository's "compiles clean with
zero warnings". All twelve are corrected. Separately, the vest repository as
uploaded to GitHub was missing `compile.cjs`, `package.json` and
`contracts/test/Attackers.sol`, so an auditor cloning it could not compile or
run a single one of the assertions its README cites.

**What could not be broken.** Merkle second-preimage and node-as-leaf
substitution, across 12 epochs and 108 receipts, with root-as-leaf, internal
nodes, foreign leaves, reversed, short and over-long proofs all rejected.
Three-way canonicalisation agreement between the recorder, the anchorer and the
verifier: 678 targeted cases plus 200,000 fuzzed unicode strings, zero
divergences. Vesting conservation across 60 random schedules over 200 months:
`totalScheduled == totalReleased ==` the sum of balances, residue zero wei.
HCOW conservation in `HCOWProfitShare` at roughly 1,600 checkpoints, exact.
`HCOWStaking` against an exact rational integration model over 7 seeds:
zero divergence. No reentrancy anywhere. No SQL access-control gap. No DOM XSS
in `verify.html`.

### 15. Review of the section 14 fixes, same day

Section 14's fixes were themselves put through three independent adversarial
passes, on the same principle that produced sections 5, 8, 10 and 11: on this
codebase roughly half of every round's findings have been introduced by the
previous round's fix. That held again. Five of the twenty-odd changes in
section 14 were defective, and two of them were worse than what they replaced.

| ID | Severity | Defect introduced by a section 14 fix | Fix |
| --- | --- | --- | --- |
| F-1 | High | E-6 scaled the participant leg to the eligible fraction but left Rule 6 testing the **unscaled** figure, forty five lines earlier. A pool whose eligible part is a rounding error therefore computed a large leg, credited zero, and burned principal against it. Measured: one wei eligible against a 100,000,000 HCOW cohort, gate passed on 1.0 USDT, **zero credited, 2,000,000 HCOW destroyed**. That is the original Critical C-1 returning in new arithmetic, which is exactly what the rule it guards exists to stop. | The scaling is computed before the gate and the gate tests the credited figure. Regression tested. |
| F-2 | Medium | E-6 returned the unpayable remainder to the settler with no event field naming it, so the published waterfall stopped reconciling in the log: measured across 26 settlements, **816,904 USDT** moved unlogged, in every one of the 26. | `EpochSettled` and the `Settlement` struct carry `gameCompanyUsdt` and `teamUsdt` as actually paid, and the `epoch_settlements` view exposes both, so `distributableProfit = participants + gameCompany + team` reconciles from the log alone in every branch. Two further attempts were needed: see G-1, G-2 in section 16 and H-1 in section 17. |
| F-3 | Medium | E-8 waived the rate floor whenever `remaining < MIN_REWARD_DURATION`, which is true for all but the first second of any period funded at the minimum duration. One wei on a year long duration then stretched a 9,900,000 HCOW budget out behind it, a **365 fold** slowdown. E-3 from section 8, returning. | The floor divides by `minDuration` rather than being waived. The 9,900,000 top-up E-8 was written for is still accepted; the stretch is refused. |
| F-4 | Medium | E-10's global faucet ceiling had no reset, so 250 throwaway addresses closed the faucet for a day and refilling it did not reopen it. A cheap denial of service replacing a cheap drain. `status()` could not see the ceiling either, so the UI disabled nothing and let testers sign transactions that revert. | `resetWindow()`, owner only. `status()` returns the window state and folds it into `claimsLeft`. |
| F-5 | High | E-9's anchorer quarantine filtered the receipts array by `roundId` alone. `roundId` does not identify a round; `(game_id, round_id)` does, which is the same fact E-13 turns on. One shared `roundId` dropped a **valid** round from another game, shifted every index after it, and handed players a proof belonging to a different record. The verification page then told them their receipt had been tampered with. | `prepare` returns the entries it kept, in the order it kept them, and the receipts are built from those. The quarantine list carries game and id. Regression tested; nothing in the suite reached `prepare` before, which is why it shipped. |

Three further defects in the section 14 fixes, all Medium: the new IP rate limit
keyed on the **first** `X-Forwarded-For` hop, which is client-supplied, so it
limited nothing and let a caller write a victim's address into an append-only
table; the narrowed RPC error pattern stopped matching four real BSC and Erigon
range refusals, turning a shrink-and-retry into a dead run; and the `HCOWVesting`
supply cap snapshot accepted zero at construction, which refuses every schedule
and leaves a contract that can never be finished or renounced. All three fixed.

Two claims written **in** section 14 were themselves wrong and are corrected
above and in the source: the decay window's justification said a pending unbond
is charged for every settlement it sits through, when `_chargeIndex` charges it
for exactly one, forever; and the "3% per thirty days" figure ignores that the
window is fixed rather than sliding. Measured against a greedy settler, the
enforced bound is **4.92% over any thirty days** and **5.87% over thirty
seven**. `MIN_EPOCH_INTERVAL` at seven days is what stops two full windows
landing inside thirty.

One design change came out of this round rather than a defect. `HCOWVesting.seal`
is now permissionless from `tgeTime` onward. E-1 removed the seal deadline
because missing it destroyed 100% of the supply; leaving the function owner-only
forever left the same total loss arriving by a different road, an owner key that
is lost, frozen or unwilling. After TGE the table is frozen, `addSchedule` is
closed and all four commitments have to match already-public figures, so the
only thing another caller can do is finish a job that was left undone.

### 16. Review of the section 15 fixes, same day

And again. Section 15's fixes were put through a further adversarial pass, and
two of them were defective in a way that was worse than what they replaced.
Three generations of fix, three generations of finding. The pattern is not
noise, it is the load-bearing fact about this codebase, and it is the reason a
third-party audit is not optional.

| ID | Severity | Defect introduced by a section 15 fix | Fix |
| --- | --- | --- | --- |
| G-1 | High | F-1 made Rule 6 test the credited participant figure, and F-2 made that figure include money carried from an earlier epoch. Between them they killed **Rule 4**: an epoch bringing in no revenue at all could satisfy the gate on a carried balance and burn principal. Measured: `gross 0, direct 0, opex 0`, no USDT entering the contract, `deductPpm 20000` accepted, **2,000 HCOW destroyed** against a distributable profit of zero. Not contrived; it fired 24 times in a 1,600 operation randomised walk. | The carry is gone, so the gate reads only this epoch's own money and Rule 4 holds by construction. Regression tested directly. |
| G-2 | High | F-2's carried balance was a pot with no link to the shares it was deferred for. Everybody unbonds, `totalShares` reaches zero, one wei bonds, and two settlements later that wei withdraws the entire pot. Measured: **500 USDT withdrawn for 1 wei of HCOW**. The window arose unprompted in a 1,200 operation run holding 5,142 USDT. E-6's own defect, rebuilt out of the fix for it. | The remainder no longer goes anywhere the settler or an arriving bonder can reach: it is split between gameCompany and team. `deferredUsdt` is deleted. Returning it to the settler, which is what this fix did first, turned out to be its own High: see H-1 in section 17. |
| G-3 | High | Not introduced by a fix, and not a contract defect: `test/invariant.staking.cjs` called `hre.ethers.provider`, which is `undefined` because this project loads no hardhat-ethers plugin. Every `fundRewards`, `claimHcow` and `claimCommission` threw inside the surrounding try and was booked as a revert. Over 1,760 operations: **fundRewards ok 0, claimHcow ok 0, claimCommission ok 0**, and the suite printed "all invariants held". The entire reward and commission surface had zero invariant coverage, including everything sections 14 and 15 changed. | One line. The run now executes 85 fundings, 165 reward claims and 77 commission claims, and the invariants do hold. |
| G-4 | Medium | F-3's widened RPC pattern went too far the other way: a bare `limit exceeded` alternative matched quota messages, so a node that had run out of monthly capacity was treated as refusing a range and never failed over. Five of sixteen realistic messages misclassified. | The bare alternative removed; the specific range phrasings kept. |
| G-5 | Low | E-9's failure counter was keyed on the epoch number alone. Epoch numbers come from the wall clock, so two ledgers driven from one process share them and one transient failure on each read as one epoch failing twice. It was also not cleared on two of the three success paths. | Keyed on contract and epoch, cleared on every success. |

The `HCOWVesting` fixes from section 15 survived this pass: permissionless
post-TGE sealing was attacked directly and no state was found in which a
stranger sealing costs a beneficiary anything, because the table is frozen by
then, `addSchedule` is closed, and all four commitments must match figures that
are already public. The only power it removes is the owner's ability to
withhold a table it can no longer change.

The `fundRewards` rate floor from F-3 also survived: binary-searched at eight
different values of `remaining`, a one wei funding cannot stretch a live budget
by a single second, and genuine top-ups are accepted at 3,600, 600, 60 and 1
seconds remaining.

### Audit scope, and the figure to quote

Six contracts across two repositories. Slither's `human-summary` on this tree
reports **1,277 SLOC** for the four in `hcow-protocol`, plus **18** for the two
test mocks. `HCOWToken` and `HCOWVesting` in `hcow-contracts` add **216** lines
excluding comments and blanks, counted by hand because that repository has no
Slither wiring. Roughly **1,500 lines** of Solidity in total, and the exact
figure depends on the counting convention a firm uses, so ask for theirs rather
than quoting ours.

**The scope must include `hcow-contracts`.** Those 216 lines control 100% of
the supply and the entire unlock schedule, `seal()` is irreversible, and until
25 August 2026 nobody had reviewed them at all. They are also where the single
Critical with the largest loss lived.

Not in scope and not proposed for it, but load-bearing: `lib/anchor.js`,
`lib/canonical.js`, `lib/merkle.js`, `lib/keccak.js`, both Supabase edge
functions, both SQL files, `web/verify.html`, `web/hcow-record.js` and
`scripts/deploy.cjs`. The two worst findings of the 25 August round were in
that list, not in the contracts.

### 17. Focused re-audit of the settlement rewrite, same day

The distribution logic in `settleEpoch` had by this point been rewritten three
times in one day, each version fixing the last version's defect. A fourth pass
was run against that function alone, on the assumption that the third version
was also broken. It was, and the finding had been present since the first
rewrite without any of the three earlier passes seeing it.

| ID | Severity | Defect | Fix |
| --- | --- | --- | --- |
| H-1 | High | The unpayable part of the participant leg was returned to `msg.sender`, and `msg.sender` is the settler: the one party that both authors the revenue figure and can move the divisor. `participants = mulDiv(leg, eligibleShares, totalShares)` reads `totalShares` live, and any bond in the settlement block, from any address, inflates it without limit. Measured: bonding 999 times the pool cut the settler's outlay from 100% to **50.05%**, recovering **49,950 of a 50,000 USDT** participant leg, then unbonding a week later at zero HCOW cost. `UNBOND_COOLDOWN` and `MIN_EPOCH_INTERVAL` are both seven days, so the capital cycles on exactly the cadence the settler already controls. Four measured epochs: settler HCOW delta **0**, USDT spent **200,200 instead of 400,000**, cohort left with **200 instead of 200,000**, a 99.9% loss. | The remainder goes to gameCompany and team instead, neither of which may be the settler. Diluting the pool now costs the settler the same and gains it nothing, so the incentive is removed rather than bounded. Regression tested with the accomplice on a separate address, because blocking the settler's own address closes nothing. |
| H-2 | Medium | The same money was also what arrivals paid for. A bond made just before a settlement absorbs the deduction at the full rate, earns nothing that epoch, and its share of the leg was the settler's discount. Measured: a 1,000,000 HCOW arrival lost 20,000 HCOW, was credited 0 USDT, and cut the settler's outlay from 1,000 to 750. | Closed by H-1's fix. The arrival still absorbs the deduction, which is the disclosed quarantine trade-off, but nothing about it now enriches the settler. |
| H-3 | Medium | `_bookmark` floored `rewardDebt`, so `floor(s·accNow) − floor(s·accThen)` could credit up to one wei more than the pool received on every share-count change. The contract retains exactly what it distributes, so there is no cushion. | `Math.Rounding.Ceil` on the debt. It cannot over-credit by construction: the credit is now bounded above by the true entitlement. Honest note: **this one was not independently reproduced here.** The auditor measured a gap opening at epoch 7 of a 40 epoch run and a claim reverting with `ERC20InsufficientBalance`; two attempts to rebuild that scenario produced no gap on either the fixed or the unfixed build. The fix is kept because the unrounded form is provably capable of over-crediting and the rounded form provably is not. |
| H-4 | Low | The event NatSpec said the two 25% legs "are exactly a quarter of `distributableProfitUsdt` each". False whenever `profit % 4 != 0`, and false in general once the unclaimed remainder is added to them. Fired on 161 of 239 randomised settlements. | Both legs are now stated in the event and the struct as actually paid, and the comment says what the real rule is. |

**What the pass could not break**, at the scale it tried: Rule 4 across a 306
cell grid of profit values and share shapes, zero cells burning principal
against a sub-1-USDT credit; Rule 6 at a worst case of 2.00 USDT buying 200,000
HCOW of burn, twenty times better than the version before it and 7.7e12 times
better than the original; the waterfall identity across four branches and 391
randomised settlements; conservation of HCOW, USDT and shares over 3,200
operations on 20 seeds with the settler acting as a participant; and the
eligibility machinery, with no retroactive or double credit found.

**On the test estate.** The invariant harness never had the settler bond, which
is why H-1 survived three passes, and its pools were large enough that H-3's
one-wei drift was absorbed. Both are now addressed: the settler participates,
and bond sizes are sometimes small enough that the truncation cushion cannot
hide drift.

## What is still missing

- A third-party audit. In procurement.
- A public bug bounty.
- Mainnet deployment. Everything above concerns BSC Testnet.

## Reporting a vulnerability

Email `biz@hash-cow.io`. Please do not open a public issue for a security
report.
