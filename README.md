# HCOW contracts

The contracts and the tooling around them.

| | |
|---|---|
| `HCOWLedger` | public integrity anchor for game results |
| `HCOWProfitShare` | Bonded Deposit. net profit distributed in USDT each epoch |
| `HCOWStaking` | delegated staking with representatives and commission |
| `HCOWFaucet` | test token faucet. testnet only, never deployed to mainnet |

`HCOWProfitShare` and `HCOWStaking` are what the dApp's data adapter calls.
Twelve of its twenty six methods land on these two.

## Scope

**`HCOWToken` and `HCOWVesting` are not in this repository.** They are the
token itself, which holds the entire 200,000,000 supply, and the vesting
contract, which holds the unlock schedule behind an irreversible `seal()`.
Nothing in this repository or in `SECURITY.md` covers them: not the tests, not
the invariant suites, not the static analysis, not the flattened bytecode
parity check, not the deployment script.

Anyone reading an audit of this repository is reading about four contracts.
On the day the token launches, the two that are not here hold more value than
the four that are. Say so explicitly wherever a report on this repository is
published, and put those two into their own engagement.

---

## HCOWLedger

Public integrity anchor for HashCow game results, on BNB Chain.

Rounds stay in our own database. Each round is hashed into a Merkle leaf,
one root is published per hour, and a player holding a receipt can prove
their round is exactly the one that was committed, without trusting
HashCow and without exposing anybody else's data.

---

## What this proves, and what it does not

**It proves that HashCow cannot alter or delete a result after the fact.**
Roots cannot be rewritten. There is no admin function that edits history,
not even for the owner. Leaderboards, tournaments and reward payouts become
auditable, because a score cannot be inserted or edited later to suit us.

**For seeded rounds it proves the revealed seed is the one the record was
written with.** `keccak256(serverSeed)` must equal `serverSeedHash`, and both
sit inside the anchored leaf, so neither can be swapped afterwards.

**It does not yet prove the outcome was fixed before you played.** The
commitment and the reveal are anchored together, after the round settled, and
the chain never sees the commitment on its own. Nothing on chain records when
`serverSeedHash` first existed, so the operator could in principle choose a
seed after seeing the player's input and still produce a record that verifies.
Closing this needs the commitment published on chain before play, which is
planned and not built. Until it is, we do not claim the stronger property, and
neither should anyone quoting us.

**It does not prove the player played honestly.** Our puzzle and arcade
titles run in the browser, so a determined player can submit a score they
did not earn. The recording endpoint applies sanity limits and rate limits,
but that is a different problem with a different solution. Anchoring makes
records tamper evident against *us*, which is the party with an incentive
to rewrite them. Say it that way in public and it holds up. Say
"unhackable scores" and it does not.

**It does not prove when a backfilled round was played.** Anchoring old rows
today shows they have not changed since today, nothing more. Backfill
therefore uses a separate function and emits a separate event, so anyone
reading the chain can tell live anchors from backfill.

---

## Two kinds of record

A game declares which kind it produces. Both go into the same tree, the same
contract and the same verifier. The contract never sees the difference: it
only ever sees a leaf.

| kind | domain | used by | claim |
|---|---|---|---|
| `skill` | `HCOWs1\|` | the 16 puzzle and arcade titles | this result happened and has not been edited |
| `seeded` | `HCOWv1\|` | any title where the server picks the outcome | plus, the revealed seed is the one this record was written with |

```
skill    gameId roundId playerRef mode level score durationMs outcome endedAt
seeded   gameId roundId playerRef serverSeedHash serverSeed clientSeed nonce outcome timestamp
```

A title can move from `skill` to `seeded` later. Nothing already anchored
changes. This is also the seam where the poker product plugs in if that team
ever wants to feed us records.

---

## Layout

```
contracts/HCOWLedger.sol             the anchor contract
contracts/HCOWProfitShare.sol        bonded deposit and epoch distribution
contracts/HCOWStaking.sol            delegated staking
contracts/HCOWFaucet.sol             test token faucet, testnet only
contracts/test/Mocks.sol             stand in HCOW and USDT, testnet only
flat/                                single file builds for Remix
scripts/deploy.cjs                   deploys the whole set, records addresses
scripts/smoke.cjs                    real transactions against a deployment
scripts/checkflat.cjs                proves flat/ matches the tested sources
lib/canonical.js                     record formats and leaf hashing
lib/merkle.js                        sorted pair Merkle tree, matches the contract
lib/keccak.js                        dependency free keccak256
lib/anchor.js                        the scheduled worker and the Supabase reader
sql/001_rounds.sql                   the append only rounds table
sql/002_chain_events.sql             the event index and its rollups
supabase/functions/record-round/     the only writer to the rounds table
supabase/functions/index-events/     the chain log indexer
web/hcow-record.js                   drop in recorder for the games
web/verify.html                      public verification page, no dependencies
test/                                test suites
foundry/                             machine-searched invariant properties
foundry/medusa/                      the same properties under a second engine
scripts/mutate.cjs                   deletes each guard in turn and checks the suite notices
```

## Running the tests

```bash
npm install
npx hardhat compile
npm run test:all
```

`test:all` ends with `forge test`. A fresh clone needs the Foundry standard
library once, because it is not committed:

```bash
git clone --depth 1 https://github.com/foundry-rs/forge-std foundry/lib/forge-std
```

Measured 29 August 2026.

| suite | result |
|---|---|
| `HCOWLedger` | 145 passed, 0 failed |
| `HCOWProfitShare` | 232 passed, 0 failed |
| `HCOWStaking` | 107 passed, 0 failed |
| `HCOWFaucet` | 49 passed, 0 failed |
| keccak256 against a reference | 318 of 318 match |
| browser page against the libraries | every vector and proof matches, and a lying RPC is refused |
| end to end anchoring | 47 receipts verified, tampering rejected |
| merkle builder against the on-chain verifier | 294 checks across 26 tree sizes, both implementations driven |
| what a stolen settler key is worth (`npm run test:adversary`) | every measured bound at or inside the published figure |
| machine-searched invariants (`npm run test:fuzz`) | 25 properties + 6 tests, 32,768 calls each |
| the same properties, second engine (`npm run test:medusa`) | 300,481 calls over 3,000 sequences, 0 failures |
| flattened sources against the artifacts (`npm run check:flat`) | 6 of 6 byte-identical |
| guards deleted one at a time (`npm run test:mutate`) | 40 of 40 caught by the assertion that names them |

### One thing to know before writing more tests

`ethers` omits `from` when it estimates gas through `BrowserProvider`, which
makes `msg.sender` the zero address and can surface a completely different
revert reason than the one a real user would hit. A cooldown check came back
as "no pending unbond" because of it, which looked like a contract bug and
was not. Every revert assertion in these suites therefore issues a raw
`eth_call` with an explicit sender. For contracts that move money the sender
must never be ambiguous, not even in a test.

And the larger one. These suites replay sequences their author thought of, so a
sequence nobody thought of is not tested. `foundry/` exists for that: 25
properties a machine searches for counterexamples to, over 32,768 generated
call sequences each, and `foundry/medusa/` runs the same properties under a
second engine with a different scheduler. The Medusa harnesses inherit the
invariant contracts rather than restating the properties, because a restated
property drifts from the one it copied and then agrees with the bug.

Bigger still: a property nobody has watched fail proves nothing. Every guard in
this repository is deleted in turn by `npm run test:mutate`, which reports a
mutation as caught only when the suite fails **on the assertion that names
it**. That runner now covers `lib/` as well as the contracts, because the worst
findings this project has had were in `lib/`.

Before trusting any property, delete the guard it claims to protect and check
that it fails. Six of the seven economic guards in `HCOWProfitShare` could be
deleted without this suite noticing, until the properties that name them were
written. `SECURITY.md` section 2b has the current table.

---

## HCOWProfitShare

Participants bond HCOW, the pool is consumed in proportion to usage, and net
profit is distributed in USDT each epoch, split 50 participants / 25 game
company / 25 team.

**What the chain enforces.** The split is computed in the contract and never
passed in. Operating costs above 40% of net revenue are rejected. Rule 4 of
the distribution policy, no distribution means no deduction, is enforced here
rather than in the UI, as the spec requires, and it is tested twice over: an
epoch that brought no money in cannot consume principal whatever a carried
balance makes the credited figure look like, and an epoch whose credited
figure rounds to nothing cannot either.

The participant leg is scaled to the eligible share of the pool, measured
against a floor set at deployment (`minPoolShares`, capped by the contract at
5% of supply, 1,000,000 HCOW on mainnet). Below that floor the pool is not yet
real and the leg is not paid out in full.

**Whatever the pool could not take is carried, not reassigned.** It stays in
the contract as `carriedParticipantUsdt` and is released to the first epoch
with a real pool, on top of that epoch's own leg. The two fixed recipients take
their own quarters and never more, and it is never refunded to the settler
either: the settler is the one party that both authors the revenue figure and
can move the divisor, by bonding into the pool from any address in the
settlement block, so a refund path is a discount it sets for itself.

So the identity is
`distributableProfit = participants + gameCompany + team + the change in
carriedParticipantUsdt`. The carry term is zero in an ordinary epoch, positive
when the pool is below the floor, and negative when a real pool releases what
was withheld; the two directions are reported by `ParticipantUsdtCarried` and
`ParticipantUsdtReleased`, so an indexer reconciles without reading storage.
Every figure in the settlement is what was actually paid.

**The carry is attributed to whoever is eligible when it is released, not to the
participants it was withheld from.** That is a real property and it is stated
plainly: a position that arrives after the withholding, sits through one
settlement and becomes eligible, shares in a balance accrued before it existed.
The money reaches participants, which is what the guard is for, but "a small
pool is paid later rather than less" is only true if the small pool is still
there. The USDT is pulled in during settlement, so a published figure
that was never funded cannot be settled. Settled epochs have no edit path.

**An abandoned epoch can be closed by anyone.** A settler that stops leaves
deposits quarantined forever while still carrying the deduction whenever a
settlement eventually arrives. Thirty days after the last settlement, any
address may call `closeStalledEpoch()`, which records an epoch with every figure
at zero and lifts the quarantine. It moves no money and cannot deduct.

Before the first settlement the fuse is longer: `BOOTSTRAP_STALL_INTERVAL`, 90
days from deployment. At thirty a stranger could burn all-zero epochs during a
perfectly healthy launch window; measured, four of them before the operator had
settled anything. Refusing the path outright until the first settlement was the
other obvious fix and it opened a liveness hole instead, because a settler that
never settles once would then leave every bonded position quarantined forever
with no permissionless way to advance anything. Ninety days of total silence
from deployment is not a launch window.

Either way it closes at most one epoch per `MAX_EPOCH_INTERVAL`, and it emits
`StalledEpochClosed` and deliberately **not** `EpochSettled`, so an epoch
authored by a stranger is not indistinguishable from a settlement to anything
reading events.

Two consequences are accepted rather than fixed, and both are stated here
because a reader should not have to find them in the code. A pending unbond
whose next epoch is closed as stalled **leaves without its deduction charge**,
and the position that owes the charge can call the function itself; charging it
would need an unbounded forward scan on a hot path, and it costs at most one
settlement's rate. And closing sets `lastSettledAt`, so a settler that was about
to settle at day 31 waits another `MIN_EPOCH_INTERVAL` and that month's revenue
folds into the next epoch. Both require the settler to have been silent for
thirty days, having had twenty-three days of opportunity, which is the case this
exists for.

**What it cannot enforce.** Gross revenue and the cost lines come from off
chain. Apple and Google settle by bank transfer and no contract can audit
that. The honest claim is that the published waterfall cannot be edited
afterwards and the money moved as stated, not that the revenue is proven.

**Accounting.** Bonded balances are shares. A deduction lowers the pool's
HCOW and every participant shrinks by the same proportion in one operation,
with no per-user writes. USDT distribution is O(1) in the number of
participants.

Two accumulators run in parallel: one for USDT owed, one for HCOW deducted.
The second exists purely so `lifetimeOf(account)` can answer "how much of my
principal has been consumed" without the settlement loop ever touching a
per-account slot. `participantCount` tracks accounts holding shares; a pending
unbond is not counted, because money on its way out is not participating.

**The two 25% recipients are separate addresses and may be set to the same
one.** Whichever they are, they are readable on chain, so the label in the
documents can always be checked against where the money actually goes.

---

## HCOWStaking

Delegated staking. A holder delegates to one representative, rewards are
funded in HCOW and split by delegated weight, each representative keeps a
commission capped at 10%.

Rewards are funded, never minted. HCOW has a fixed supply and no mint
function, so every reward paid was transferred in first.

**On naming.** HCOW is a token on BNB Chain, not its own network. Nothing
here secures a chain or produces blocks. The contract records delegations,
splits funded rewards and pays commission. External descriptions should
match that.

---

## Deploying to BSC testnet

Testnet first, always. Testnet BNB is free, so the only thing a mistake costs
is a redeploy, and nothing that happens there can touch a real balance.

There are two routes. They produce the same bytecode.

### Route A, browser only

No tooling to install. `flat/` holds five self contained files with every
import inlined, one per contract plus `TestTokens.flat.sol` carrying both
mocks, ready to paste into Remix. `scripts/checkflat.cjs`
compiles each of those files standalone and compares the creation bytecode
against the artifact Hardhat built from the original imported sources, so a
flattened file that had drifted would fail the check rather than reach a
chain. All six currently match.

Deploy order, because most of them take the token addresses as constructor
arguments. **Step 1 is testnet only.** On mainnet the token comes from the
`hcow-contracts` repository and there is no mock of anything; see the mainnet
section below before doing any of this against chain 56.

```
1  TestTokens.flat.sol      MockHCOW, then MockUSDT      no arguments
                            TESTNET ONLY. Never on mainnet.
2  HCOWLedger.flat.sol      HCOWLedger(owner, anchorer)
3  HCOWProfitShare.flat.sol HCOWProfitShare(hcow, usdt, owner, settler,
                                           gameCompany, team, minPoolShares)
4  HCOWStaking.flat.sol     HCOWStaking(hcow, owner, funder)
5  HCOWFaucet.flat.sol      HCOWFaucet(hcow, usdt, owner)
                            TESTNET ONLY. It gives away whatever is in it.
```

Compiler 0.8.34, optimizer on, 200 runs, EVM version paris. Anything else
produces different bytecode and a later verification will not match.

0.8.34 is deliberate. Remix bundles it as its local compiler and falls back to
it alone when it cannot reach the version list, which is the state a browser
on a restricted network ends up in. The whole project builds and tests on that
exact version, `0.8.34+commit.80d5c536`, so what gets deployed from a browser
is what was tested. The contracts declare `^0.8.26`, so an older toolchain
still compiles them; only the pinned build version moved.

### Route B, scripted

```bash
export DEPLOYER_KEY=0x...          # throwaway wallet, testnet only
npm run deploy:testnet
npm run smoke:testnet
```

`deploy.cjs` writes `deployments/bscTestnet.json` with every address and
every role. `smoke.cjs` reads it. The dApp and the anchoring worker do not:
both take their addresses from configuration, so that file is the record of
what was deployed, not a runtime dependency.
Outside chain 97 it refuses to deploy placeholder tokens and demands real
`HCOW_ADDRESS` and `USDT_ADDRESS`.

`smoke.cjs` then sends real transactions against what was just deployed:
it anchors an epoch and verifies a proof and a tampered proof on chain, bonds
HCOW, settles an epoch and checks the distributable profit figure landed, then
registers a representative, stakes, funds rewards and checks the 5% commission
split before claiming. Seventeen assertions. Compiling is not proof that a
contract works; this is.

It does not check the 350 / 175 / 175 split, and it cannot: the bond it makes
is in the same epoch it then settles, so nobody is eligible, the participant
leg is returned to the settler and `participantsUsdt` for that epoch is zero by
design. The split is covered by `test/profitshare.test.cjs`. It also does not
claim USDT, for the same reason.

Both scripts talk to the node through a plain `JsonRpcProvider` and a
`NonceManager` rather than a Hardhat ethers plugin, so `from` is explicit on
every call and a cached nonce cannot abort a deployment halfway through.

### Rehearsing without spending anything

```bash
HARDHAT_CHAIN_ID=97 npx hardhat node          # one terminal
HARDHAT_CHAIN_ID=97 DEPLOYER_KEY=<node key> \
  npx hardhat run scripts/deploy.cjs --network localhost
HARDHAT_CHAIN_ID=97 DEPLOYER_KEY=<node key> \
  npx hardhat run scripts/smoke.cjs --network localhost
```

The local node impersonates chain 97 so the same code path runs. Nothing in
the contracts depends on the chain id.

### Wallets

| | |
|---|---|
| deploy | fresh MetaMask account, testnet BNB only, key may be exported |
| owner | testnet: the deploy account. mainnet: hardware wallet or multisig |
| anchorer | hot wallet, gas only, never anything else |
| settler | holds the USDT being distributed |

The deploy script prints a warning whenever owner equals the deploy key,
because that is exactly the configuration that must never reach mainnet.

### Deploying to BSC mainnet

There are six contracts across two repositories and nobody had written down the
order. This is it.

`hcow-contracts` holds the token and the vesting contract. `hcow-protocol`,
this repository, holds the other four. The token must exist before the two
economic contracts, because both take its address as an immutable constructor
argument, and a wrong one there is not a mistake that can be corrected.

```
hcow-contracts   1  HCOWToken(treasury)
                 2  verify on BscScan, confirm bytecode, before any value moves
                 3  HCOWVesting(token, tgeTime, owner)
                 4  addSchedule x 9        <- see that repo's README, step 6
                 5  transfer totalScheduled into the vesting contract
                 6  seal(count, scheduled, tgeUnlock, scheduleHash)
                       do 5 and 6 in ONE TRANSACTION, via fundAndSeal

hcow-protocol    7  HCOWLedger(owner, anchorer)
                 8  HCOWProfitShare(hcow, usdt, owner, settler,
                                    gameCompany, team, minPoolShares)
                    minPoolShares = 1_000_000e18 on mainnet
                 9  HCOWStaking(hcow, owner, funder)
                    no faucet, no mock tokens, ever

off chain       10  sql/001, sql/002, sql/003; deploy both edge functions;
                    schedule the anchorer; publish verify.html
```

Steps 7 to 9 do not depend on 4 to 6, only on 1. They can go up first if that
is more convenient.

Run `scripts/deploy.cjs` for steps 7 to 9 rather than pasting constructor
arguments into Remix by hand. Every guard that stops a role being the deploy
key, being zero, or being both settler and payout recipient lives in that
script, and pasting into a browser form runs none of them. It also asks both
token addresses for their name, symbol, decimals and supply before committing
them, and refuses anything that is not an eighteen decimal ERC20, because
`MIN_PARTICIPANT_USDT` is written as `1e18` and against a six decimal USDT the
deduction gate is silently unreachable for the life of the contract.

If it must be Remix, deploy the identical constructor tuples to testnet first,
read every role back off the deployed contract, and have a second person check
them against this list before touching chain 56.

### Roles at a glance

| Role | Contracts | What a compromise costs | Custody |
|---|---|---|---|
| treasury | Token, Vesting | the entire supply until it is inside the vesting contract and sealed | multisig, mandatory |
| owner | Ledger, ProfitShare, Staking, Faucet | can set the settler and both payout recipients, so it can recover half of every settlement while burning bonded principal at the ceiling. Cannot take bonded HCOW. `HCOWProfitShare` and `HCOWStaking` have no `renounceOwnership`, so a lost key freezes those roles forever. On all four contracts the role moves in two steps: `transferOwnership` nominates, `acceptOwnership` is called by the nominee, and `cancelOwnershipTransfer` withdraws a nomination, so an unreachable address cannot be handed the role | multisig |
| settler | ProfitShare | cannot take bonded HCOW. Can burn up to 3% of the bonded pool per decay window; the window is fixed rather than sliding and is anchored by the first deduction in it, so windows can be packed and the worst case is 5.87% over any thirty days (59,999 ppm summed) and 6.82% over any thirty-seven (70,000 ppm), at a partly refunded cost | hardware wallet, holds live USDT |
| anchorer | Ledger | junk roots in elapsed periods. Loud, and revocable by the owner. Cannot touch history or future periods | hot wallet, gas only |
| gameCompany / team | ProfitShare | its own 25% leg, and never more. Cannot take any part of the participant leg: an exit or an arrival mid-epoch leaves the leg with the eligible pool, and a pool below `minPoolShares` has its leg carried inside the contract rather than handed over | multisig |
| rewardFunder | Staking | cannot extract, and cannot slow a live stream: a funding may add tokens or add time, never redistribute what is promised. Can decline to fund new money, but a balance already carried inside the contract can be released without any: `fundRewards(0, duration)` re-streams the carry under the same floors | hardware wallet, holds HCOW |
| deployer | all | on a hand-typed Remix deployment, whatever it types | hardware wallet, tuples checked by a second person |
| Supabase `service_role` | off chain | **can insert rounds that then anchor as genuine.** The chain proves nothing was altered after anchoring, not that it was true before | treat as a key, rotate, never leaves the dashboard |

The last row is the one that gets left off wallet inventories. It is not a
wallet and it is as security critical as the anchorer.

---

## HCOWFaucet

Testnet only. Hands out test HCOW and test USDT, one claim per address per
day, so a tester can actually bond and claim rather than only look at a
dashboard. It holds what was put into it and has no mint path, so a bug here
cannot inflate anything.

It does not dispense gas. Calling `claim` already costs gas, so a faucet that
paid for gas could never be reached by the person who needs it. Testers get
their first tBNB from the public BNB Chain faucet or from the team.

The dApp attaches it as `adapter.faucet`, which is `undefined` unless a faucet
address is configured. On a mainnet build the claim button does not exist,
rather than existing and failing.

---

## The event index

`sql/002_chain_events.sql` plus `supabase/functions/index-events/` exist for
one reason: a browser cannot scan a year of BSC logs on page load. Public RPCs
cap `eth_getLogs` by block range and by result count, and the range from
deployment to head grows by about 28,800 blocks a day. So a worker walks the
chain in bounded chunks and writes decoded events into `chain_events`, and the
dApp reads an indexed table instead.

**It is a cache, never a source of truth.** Balances always come from the
contracts. Delete the table and the app loses history and nothing else; the
worker rebuilds it from `GENESIS_BLOCK`.

The cursor advances only after the rows for a chunk are committed, so a crash
mid-run replays that chunk rather than skipping it, and the unique key on
`(tx_hash, log_index)` makes the replay a no-op. That combination is what makes
the worker safe to schedule aggressively.

Reads are public because chain data is public. Writes are service-role only.
The anon key the browser ships with cannot insert a row, which matters more
than it looks: an index anyone can write to is a place to plant a settlement
that never happened.

Two rollup views, `epoch_settlements` and `revenue_windows`, are plain views
rather than materialised ones. One settlement a week means freshness beats
speed, and a stale materialised view showing last week's revenue as this
week's is a worse failure than a slow query.

---

## Rules that must never be broken once live

1. Do not add, remove or reorder fields in a kind. Every receipt ever issued
   would stop verifying.
2. Do not change the escaping.
3. Do not reuse a `roundId` within a game.
4. `playerRef` stays opaque. Never a wallet address, an email, or anything
   that identifies a person on its own.

If a format has to change, add a new kind with a new domain tag and leave
the old one readable forever.

### The anchoring sequence

Live epochs are strictly sequential and there is no cursor override, so the
order these are done in is not a preference.

5. **Anchor every period, including the empty ones.** An hour with no rounds
   is anchored with `EMPTY_PERIOD` and a count of zero. A zero root is refused
   outright: it is also what an epoch that was never anchored reads as, so it
   cannot serve as an attestation of anything. `isEmptyPeriod(epoch)` is how a
   reader tells "we state this hour was empty" from "this hour was never
   reached".
6. **Never skip forward.** `anchorEpoch` only accepts `nextEpoch`. After an
   outage the worker drains the backlog in order, oldest first, up to
   `MAX_CATCHUP_EPOCHS` per run. There is no way to jump the cursor, so a skip
   is not a gap that can be filled in later; it is a permanent stop.
7. **Anchor a period only after it has ended.** The contract enforces this. It
   exists so a stolen anchorer key cannot burn a year of future periods in one
   transaction, which revoking the key would not undo.
8. **A backfill covers time before this contract existed, and a batch is
   submitted once.** Two bounds:
   - `coversTo` must be earlier than `genesisEpoch * EPOCH_SECONDS`. A backfill
     covers the past by definition, and "the past" means before this contract,
     not merely before now. Bounded at the current time instead, a backfill
     could claim hours the live path had already anchored and the same records
     were counted in both totals.
   - A root already used by a backfill is refused, through a map kept apart from
     the live one so a backfill can never poison a pending live root. This is
     what stops the trigger the audit names: an ordinary retry after a dropped
     connection resubmits the identical batch, and the identical batch has the
     identical root.

   Ranges may be submitted **out of order and may overlap**. An older archive is
   routinely discovered after a newer one, and two games' histories overlap in
   calendar time while containing entirely different records. An earlier version
   forbade both, and it was wrong twice over: it made those permanently
   impossible, it handed a stolen anchorer key a one-transaction irreversible
   denial of all future backfill, and the owner-only escape hatch added to
   relieve that re-opened the very double count the rule existed to prevent.

   **`totalHistoricalRecords` is therefore a figure the anchorer asserts**, in
   exactly the way a single batch's declared `recordCount` is. A tree rebuilt
   over the same rounds is a different root over the same period and the
   contract accepts it. Publish the figure as a claim, not as something the
   chain proves.

9. **One anchorer key must have actually anchored before ownership is
   renounced.** `renounceOwnership` counts anchorers that have written to the
   contract, not anchorers that were configured. Add the key, let it anchor one
   real period, confirm `provenAnchorerCount()` reads at least one, and only
   then renounce. Removing an anchorer clears its proof, so a key rotated out
   and later re-added has to anchor again before it counts: the guard is meant
   to evidence a live key, not one that was live once.

### What the anchored value is

`getEpoch(e).root` is **not** the bare Merkle root. It is

```
keccak256(0x02 ++ merkleRoot ++ uint64(recordCount))
```

Storing the bare root left `recordCount` a free-standing claim beside it.
Binding the two means an observer who rebuilds the tree from the published
records reproduces the anchored value only if the count matches as well.

This does not let the contract detect an inflated count: it is told the value
and the count by the same caller and has no independent view of the record set.
What it does is make the claim checkable off chain, which it previously was not.
`lib/merkle.js` exposes this as `commit(merkleRoot, recordCount)`, and
`buildTree` returns both `merkleRoot` and the anchored `root`.

Levels are also **padded to a power of two with `EMPTY_LEAF`** rather than
pairing an odd node with itself. Self-pairing made a tree of *n* leaves and a
tree of *n + 1* whose last leaf repeats the *n*-th produce the identical root,
and the required proof length was identical for both, so binding the count fixed
the count and left uniqueness open. Padding closes it. Proof length is unchanged
at ceil(log2(n)) and the contract's verification is untouched.

### The hashing rule is on the chain, as code

`leafSeeded(string[9])` and `leafSkill(string[9])` are `pure` functions that take
a record and return the exact 32 bytes the tree was built from, escaping
included. `LEAF_RULE`, `TREE_RULE`, `FIELDS_SEEDED`, `FIELDS_SKILL`,
`NODE_PREFIX`, `COUNT_PREFIX`, `EMPTY_LEAF` and `EMPTY_PERIOD` state the rest.

Publishing the two domain tags alone was half a rule. A verifier that knows the
tag but not the field order, the separator or the escaping still has to take the
rest from a document, or from our JavaScript, which is the one thing a proof
exists to make unnecessary. `test/ledger.test.cjs` asserts the chain's own
answer against `lib/canonical.js` on tab, newline and backslash inputs, so the
published rule and the implementation cannot drift.

### Deploying the ledger: the order is not a preference

The contract cannot tell a correct anchored value from a wrong one. It is handed
32 bytes and stores them. So:

- **Contract before worker** anchors bare Merkle roots that are *accepted*, and
  every receipt for those hours verifies false forever with no rewrite path.
- **Worker before contract** does the same in reverse, and stalls on the first
  empty hour.

Neither is recoverable. Deploy the contract and ship the new `lib/` in one
release, with the worker paused across the change, then the verify page, then
the edge function. `lib/anchor.js` reads each anchor back off the chain and
refuses to continue if it does not match what it computed, which is the only
detection there is.

---

## Bringing it up

**1. Create the table.** Run `sql/001_rounds.sql` in the Supabase SQL editor.
It creates `rounds`, blocks updates, deletes and truncates with triggers, and
revokes the anon key. The append only triggers matter: a row that can change
after it was anchored would make the anchor a lie. They are declared
`ENABLE ALWAYS`, so they still fire under `session_replication_role = replica`;
with the default they would not, and the guarantee would be one `SET` away from
not existing.

**2. Deploy the recording endpoint.**

```bash
supabase functions deploy record-round --no-verify-jwt
```

It is the only writer. The client is not trusted, so the function decides
what is stored, clamps the values, ignores a client clock that is more than
five minutes out, and rate limits to 120 rounds per player per hour.

**3. Add one line to each game.**

```html
<script src="https://cdn.hash-cow.io/hcow-record.js"
        data-game="tint" data-endpoint="https://<project>.functions.supabase.co/record-round"></script>
```

and one call where a round settles:

```js
HCOWRecord.skill({ mode:'campaign', level:12, score:8400,
                   durationMs:64210, outcome:'cleared' });
```

The recorder handles the round id, the player reference, the timestamp,
retries and an offline queue. It never blocks the game and never throws into
game code.

**4. Deploy the contract.** `HCOWLedger(owner, anchorer)`.
Owner should be a hardware wallet or multisig; it can only manage who may
anchor and can never alter a root. The anchorer is the hot wallet the worker
signs with, holding gas and nothing else. If that key leaks, an attacker can
write junk into future epochs, which is loud and obvious, and is shut off
with `setAnchorer(addr, false)`. Anchored history is untouchable either way.

**5. Run the worker hourly.**

```js
const { runOnce, makeSupabaseFetch } = require('./lib/anchor');

const r = await runOnce({
  rpcUrl: process.env.BSC_RPC,
  privateKey: process.env.ANCHORER_KEY,
  contract: process.env.LEDGER_ADDRESS,
  fetch: makeSupabaseFetch({ url: process.env.SUPABASE_URL,
                             serviceKey: process.env.SUPABASE_SERVICE_KEY }),
});

// The return value is not decoration. Read it, or the three things below
// happen silently.
if (r.stalled) {
  // Nothing will anchor until this is resolved, and epochs are strictly
  // sequential, so the ledger is stopped. Page someone.
  alert(`ledger stalled at epoch ${r.stalled.epoch}: ${r.stalled.error}`);
}
for (const e of r.unconfirmed) {
  // The transaction may or may not be on chain. Do NOT hand out receipts from
  // these until getEpoch(e.epoch) shows the root; the next run will not
  // regenerate them, because the cursor comes from the chain.
  hold(e);
}
for (const q of r.quarantined) {
  // Rounds excluded from an anchored root. Publish them, or the ledger's own
  // claim to have no holes stops being true.
  publishExclusion(q);
}
for (const e of r.epochs) {
  if (e.status === 'confirmed') storeReceipts(e.receipts);
}
```

The worker leaves **one period of grace**: it closes epoch `E` once the clock
is inside `E+2`, not the instant `E` ends. A round is stamped with the epoch its
request fell in and appears when its insert commits, so one made in the last
moments of an hour can land in the database after that hour was read. An
anchored epoch can never be reopened and the table is append only, so without
the grace such a round would be unanchorable forever. The cost is that a receipt
becomes available within about two hours rather than one.

`runOnce` never throws for an anchoring failure. It returns
`{ ok, epochs, unconfirmed, quarantined, failed, stalled, cursor, currentEpoch }`
and stops at the first epoch it could not complete, because epochs are
sequential and continuing past one would leave a hole.

**6. Publish `web/verify.html`** at `verify.hash-cow.io` with the contract
address filled in.

---

## Cost

Measured on the compiled contract.

| | |
|---|---|
| Gas, first anchor | 121,409 |
| Gas, steady state | 104,297 |
| Hourly anchoring, per year | 913,641,720 gas |
| Cost per year at 0.1 gwei | about $55 |
| Cost per year at 1 gwei | about $548 |
| Daily anchoring, per year at 1 gwei | about $23 |
| Proof size for 1,001 records | 10 hashes, 320 bytes |

Assumes BNB at $600. Proof size grows with the logarithm of the record
count, so a million rounds an hour would still be a 20 hash proof.

---

## Still open

- **Which games record first.** Recommend one title end to end before all
  sixteen, so the shape of the data is proven against something real.
- **Where receipts are served.** Simplest is an endpoint that takes a
  `gameId` and `roundId` and returns the receipt JSON.
- **Backfill.** Our own database currently holds saves and scores, not round
  records, so there is little to backfill and the honest claim is that
  anchoring runs live from the day it starts. A growing verifiable number
  beats a large unverifiable one.
- **Anti cheat.** Out of scope here and worth keeping separate. Anchoring
  and cheat detection are different problems, and conflating them in public
  messaging is how a good claim turns into a bad one.
