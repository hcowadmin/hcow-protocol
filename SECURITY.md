# Security status

This document states plainly what has and has not been done to these
contracts. It is updated when that changes.

## Not audited

**These contracts have not been audited by a third-party firm.**
There is no audit report, and we will keep saying so on every surface we
control until one exists. Do not treat anything below as a substitute.

## What has been done

### 1. Unit tests

245+ assertions across `test/ledger.test.cjs`, `test/profitshare.test.cjs`,
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

Result: **no exploitable finding.** Every reported item was reviewed by hand
and classified:

| Detector | Count | Assessment |
| --- | --- | --- |
| `reentrancy-balance` / `reentrancy-no-eth` / `reentrancy-benign` | 24 | Not exploitable. Every function named carries OpenZeppelin `nonReentrant`, and the only cross-function paths Slither identifies are `view` functions, which cannot corrupt state. The external calls are to HCOW and to BSC-USD, neither of which has a transfer hook. |
| `incorrect-equality` | 20 | Not applicable. The detector targets strict equality against balances. Every instance here is a zero check on an internally computed delta, or the Merkle root comparison in `HCOWLedger._verify`, which must be strict equality by definition. |
| `divide-before-multiply` | 3 | Intentional. `participants` and `slice` are amounts that are actually transferred, so they must be rounded to a token amount before being scaled into an accumulator. Reversing the order would credit shares that no transfer backs. |
| `uninitialized-local` | 3 | Style only. Solidity zero-initialises these. |
| `timestamp` | 17 | Not applicable. `block.timestamp` is used for 7-day cooldowns, where validator drift of seconds is irrelevant. |
| `pragma`, `cyclomatic-complexity`, `missing-inheritance` | 5 | Informational. |

Static analysis finds known bug patterns. It does not find accounting or
incentive errors, which is why the next section exists.

### 3. Invariant (property) tests

Randomised state-machine testing. Long seeded sequences of real user actions
are executed against a fresh deployment, and a set of properties is re-checked
after **every single operation**. Reverts are expected outcomes and the
properties must hold through them.

```
npm run test:invariant
```

Latest run: **4,160 operations, 8 seeds per contract, zero violations.**

Seeds are fixed, so any failure is reproducible from the printed seed and
operation index.

#### HCOWProfitShare, 13 properties

| ID | Property |
| --- | --- |
| I1 | **Solvency.** Sum of all claimable USDT never exceeds the USDT held. |
| I2 | Sum of account shares equals `totalShares`. |
| I3 | `totalBondedHcow + totalPendingUnbond` never exceeds the HCOW held. |
| I4 | `accUsdtPerShare` never decreases. |
| I5 | `accDeductedPerShare` never decreases. |
| I6 | `participantCount` equals the number of accounts with a non-zero share. |
| I7 | Sum of `bondedOf` never exceeds `totalBondedHcow`. |
| I8 | Zero shares implies zero bonded HCOW, so deduction cannot divide by zero and no HCOW can become unowned. |
| I9 | A pending unbond always carries a ready time. |
| I10 | `totalUsdtDistributed` never decreases. |
| I11 | `totalHcowDeducted` never decreases. |
| I12 | **No value creation.** Claimed plus still-owed USDT never exceeds what settlements actually credited to participants. |
| I13 | Sum of account pending unbond equals `totalPendingUnbond`. |

#### HCOWStaking, 9 properties

| ID | Property |
| --- | --- |
| S1 | **Solvency.** Principal, reserved unstake, unclaimed rewards and accrued commission together never exceed the HCOW held. |
| S2 | Sum of delegated amounts equals `totalStaked`. |
| S3 | Sum of representative totals equals `totalStaked`. |
| S4 | `totalRewardsOwed` never exceeds `totalRewardsFunded`. |
| S5 | `totalRewardsFunded` never decreases. |
| S6 | No representative commission ever exceeds `MAX_COMMISSION_BPS`. |
| S7 | A pending unstake always carries a ready time. |
| S8 | Sum of account pending unstake equals `totalPendingUnstake`. |
| S9 | Sum of pending rewards never exceeds `totalRewardsOwed`. |

Both suites report per-action coverage so a clean result cannot be produced by
a run in which nothing happened.

### 4. Deployed-bytecode parity

`scripts/checkflat.cjs` compiles each flattened source standalone and compares
creation bytecode against the Hardhat artifact, stripping the trailing
metadata hash. All contracts match. The deployed contracts are verified on
BscScan, so the published source can be checked against what is running.

## What is still missing

- A third-party audit. Planned, not scheduled.
- A public bug bounty.
- Mainnet deployment. Everything above concerns the BSC Testnet deployment.

## Reporting a vulnerability

Email `biz@hash-cow.io`. Please do not open a public issue for a security
report.
