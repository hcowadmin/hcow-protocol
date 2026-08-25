# Security status

This document states plainly what has and has not been done to these
contracts. It is updated when that changes.

## Not audited

**These contracts have not been audited by a third-party firm.**
There is no audit report, and we will keep saying so on every surface we
control until one exists. Do not treat anything below as a substitute.

## What has been done

### 1. Unit tests

290 assertions across `test/ledger.test.cjs`, `test/profitshare.test.cjs`,
`test/staking.test.cjs` and `test/faucet.test.cjs`, including every revert
path. Revert assertions are made with a raw `eth_call` carrying an explicit
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

Eleven detector categories fire. Every instance was reviewed by hand and
classified:

| Detector | Assessment |
| --- | --- |
| `reentrancy-balance` / `reentrancy-no-eth` / `reentrancy-benign` / `reentrancy-events` | Not exploitable. Every function named carries OpenZeppelin `nonReentrant` off a single shared guard, so cross-function reentrancy is covered too, and the only cross-function paths Slither identifies are `view` functions. The external calls are to HCOW and to BSC-USD, neither of which has a transfer hook. |
| `incorrect-equality` | Not applicable. The detector targets strict equality against balances. Every instance here is a zero check on an internally computed delta, or the Merkle root comparison in `HCOWLedger._verify`, which must be strict equality by definition. |
| `divide-before-multiply` | Intentional. `participants` and `slice` are amounts that are actually transferred, so they must be rounded to a token amount before being scaled into an accumulator. Reversing the order would credit shares that no transfer backs. |
| `uninitialized-local` | Style only. Solidity zero-initialises these. |
| `timestamp` | Not applicable. `block.timestamp` is used for cooldowns measured in days, where validator drift of seconds is irrelevant. |
| `pragma`, `cyclomatic-complexity`, `missing-inheritance` | Informational. |

Static analysis finds known bug patterns. **It found none of the defects listed
in sections 4 to 7**, which is the honest measure of what it is worth.

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

`HCOWProfitShare` checks 15 properties, `HCOWStaking` 9. The full list is in
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
| C-1 | Critical | The per-settlement deduction cap bounded one settlement but not a sequence, and Rule 4 tested `profit != 0` rather than the participant payout. One wei of profit rounds the participant leg to zero while authorising a full-size burn. 400 settlements costing 400 wei of USDT in total reduced a 1,000,000 HCOW pool to 309 HCOW. | The deduction rate is now capped **and** rate limited by `DEDUCT_COOLDOWN`, and Rule 6 requires a non-zero participant payout. Worst case is 2% per day, so a participant who reacts inside the seven-day unbond cooldown cannot lose more than about 13% of principal. |
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
| G-1 | Critical | `nextEpoch` started at zero while the anchoring worker derives the period from the wall clock. A deployment today would have needed roughly half a million catch-up transactions before it could anchor the current hour, with no fast-forward path and no setter. The end-to-end test rebased every timestamp to keep epochs at 0, 1, 2, which is exactly why nobody saw it. | `genesisEpoch` is set from `block.timestamp` at construction and the cursor starts there. The worker reads it and refuses to run if the two disagree by more than a month. The end-to-end test now runs at the real epoch number, currently 496,569. |
| G-2 | Critical | Three ways for two different records to hash to one leaf: unpaired surrogates collapsed to U+FFFD by `TextEncoder`, database nulls stringified to `"null"`, and integers past 2^53 losing precision. Any of them lets one anchored leaf stand for more than one record, which is the substitution the whole scheme exists to prevent. | Canonicalisation rejects ill-formed strings, requires NFC, and requires safe integers with no negative zero. The database reader refuses null and parses integers from their string form. |
| G-3 | High | A stolen anchorer key could anchor empty roots forward past the current hour, permanently consuming the epoch namespace for about thirty cents a year. Revoking the key would not give it back. | An epoch may only be anchored once its period has ended. A stolen key is confined to the past. |
| G-4 | High | Nothing stopped the same root being anchored to more than one epoch, so a receipt verified in several periods at once and "this round belongs to hour N" was the operator's choice rather than the chain's. | A root may be anchored once, live or historical. |
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

### 8. Open, not yet fixed



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
- **`IBurnable(hcow).burn()` is an assumption about a token that is not in this
  repository.** Confirming that the deployed HCOW burns from `msg.sender` with
  no fee and no allowlist is a mainnet deployment gate.

### 9. Deployed-bytecode parity

`scripts/checkflat.cjs` compiles each flattened source standalone and compares
creation bytecode against the Hardhat artifact, stripping the trailing
metadata hash. All contracts match.

## What is still missing

- A third-party audit. In procurement.
- A public bug bounty.
- Mainnet deployment. Everything above concerns BSC Testnet.

## Reporting a vulnerability

Email `biz@hash-cow.io`. Please do not open a public issue for a security
report.
