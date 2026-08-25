# Security status

This document states plainly what has and has not been done to these
contracts. It is updated when that changes.

## Not audited

**These contracts have not been audited by a third-party firm.**
There is no audit report, and we will keep saying so on every surface we
control until one exists. Do not treat anything below as a substitute.

## What has been done

### 1. Unit tests

259 assertions across `test/ledger.test.cjs`, `test/profitshare.test.cjs`,
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
in section 4**, which is the honest measure of what it is worth.

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

### 5. Known and accepted, not fixed

Stated here rather than discovered later.

- **Same-epoch bonding.** `accUsdtPerShare` credits whoever holds shares at the
  instant of settlement. There is no time weighting and no eligibility delay,
  so an account that bonds shortly before a settlement receives a full share of
  that epoch. Correcting this requires separating eligible from ineligible
  shares, which is a design change rather than a fix, and it is deferred to the
  audited revision. Until then settlements are submitted through a private
  relay so the parameters are not visible in the public mempool.
- **Lump-sum staking rewards.** `fundRewards` splits by instantaneous weight,
  with the same consequence, and `redelegate` is free and instant, so
  commission can be avoided by moving to a zero-commission representative
  around a funding round. The correct fix is time-weighted accrual, which
  replaces the reward mechanism. Same deferral, same mitigation.
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

### 6. Deployed-bytecode parity

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
