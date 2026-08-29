// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/**
 * @title HCOWLedger
 * @notice Public integrity anchor for HashCow game outcome records.
 *
 * WHAT THIS IS
 * Game rounds are recorded off chain. Each record is hashed into a Merkle
 * leaf, the leaves of a period are combined into one Merkle root, and only
 * that root is written here. Anyone holding a record and its Merkle proof
 * can verify against this contract that the record is exactly the one that
 * was committed, without trusting HashCow and without HashCow revealing
 * anything about other players.
 *
 * WHAT IT GUARANTEES
 * - A root, once written, can never be changed or removed. There is no
 *   admin function that rewrites history. Not for the owner either.
 * - Live epochs are strictly sequential. Epoch n cannot be written before
 *   epoch n-1. A period with no rounds is still anchored, with the
 *   EMPTY_PERIOD constant and a zero count, so the sequence can never
 *   contain a silent hole and an attested empty hour is distinguishable from
 *   one that was never reached. A zero root is refused: it is also what an
 *   unanchored epoch reads as, so it cannot attest to anything.
 *
 * WHAT IT DOES NOT GUARANTEE
 * - A historical batch proves the data has not changed since the moment it
 *   was anchored. It does not prove when the rounds were played. Backfilled
 *   history is therefore recorded through a separate function and a separate
 *   event, so nobody can read it as live evidence. This distinction is
 *   deliberate.
 */
contract HCOWLedger {
    struct Anchor {
        bytes32 root;         // Merkle root over the period's record leaves
        uint64  recordCount;  // number of leaves in the tree
        uint64  anchoredAt;   // block timestamp of the anchoring transaction
    }

    struct HistoricalBatch {
        bytes32 root;
        uint64  recordCount;
        uint64  anchoredAt;
        uint64  coversFrom;   // earliest record timestamp in the batch
        uint64  coversTo;     // latest record timestamp in the batch
    }

    /// @notice Domain separators leaf hashes are built with, one per record
    ///         kind. Published on chain so verifiers never have to guess the
    ///         format. There is deliberately no single LEAF_DOMAIN: the two
    ///         kinds carry different fields and must not be interchangeable.
    string public constant LEAF_DOMAIN_SEEDED = "HCOWv1|";
    string public constant LEAF_DOMAIN_SKILL = "HCOWs1|";

    /**
     * @notice The full rule for turning a game round into a leaf, published
     *         here so an independent verifier never has to take it from a
     *         document that can be edited after the fact.
     *
     * Publishing only the two domain tags was half the rule. A verifier that
     * knows the tag but not the field order, the separator or the escaping
     * cannot reproduce a leaf, so in practice it had to trust our JavaScript,
     * which is the one thing a proof is supposed to make unnecessary.
     *
     * leaf = keccak256( utf8( domain ++ field_1 ++ TAB ++ ... ++ field_n ++ LF ) )
     *
     * Integers are rendered in base ten with no separators, no sign for zero
     * and no exponent. In every field, a backslash becomes two backslashes, a
     * tab becomes backslash-t and a newline becomes backslash-n, applied in
     * that order. The field order is fixed per kind and is frozen once a kind's
     * first root is anchored.
     */
    string public constant LEAF_RULE =
        "leaf=keccak256(domain||f1||0x09||...||fn||0x0a); "
        "integers base10; escape: backslash->2x, 0x09->\\t, 0x0a->\\n";

    /// @notice Field order for a seeded record, in the order they are joined.
    string public constant FIELDS_SEEDED =
        "gameId,roundId,playerRef,serverSeedHash,serverSeed,clientSeed,nonce,outcome,timestamp";

    /// @notice Field order for a skill record, in the order they are joined.
    string public constant FIELDS_SKILL =
        "gameId,roundId,playerRef,mode,level,score,durationMs,outcome,endedAt";

    /// @notice Prefix on every internal node hash. Leaf preimages begin with a
    ///         domain tag and are not 65 bytes, so no node preimage can ever
    ///         be read as a leaf preimage. This makes the separation
    ///         structural rather than a statement about how hard it would be
    ///         to steer two keccak outputs into a valid record layout.
    /// Public for the same reason the two leaf domains are: an independent
    /// verifier must be able to read every part of the hashing rule off the
    /// chain rather than take it from a document that could be edited.
    bytes1 public constant NODE_PREFIX = 0x01;

    /// @notice Prefix on the final fold that binds a tree's record count into
    ///         the value this contract stores.
    ///
    /// Storing the bare Merkle root left `recordCount` a free-standing claim:
    /// the same root was a valid anchor for more than one count, and
    /// `totalRecords()` could be inflated without any published receipt
    /// betraying it. What is anchored is now
    ///
    ///     keccak256(COUNT_PREFIX ++ merkleRoot ++ recordCount)
    ///
    /// and `_verify` performs that fold before comparing, so a receipt issued
    /// under one count cannot be presented under another. 0x02 keeps this
    /// preimage space disjoint from both node preimages (0x01) and leaf
    /// preimages (a domain tag).
    bytes1 public constant COUNT_PREFIX = 0x02;

    /// @notice Filler leaf used to pad a tree up to a power of two.
    ///
    /// An odd node used to be paired with itself. That made a tree of n leaves
    /// and a tree of n + 1 whose last leaf repeats the n-th produce the
    /// identical root, so binding the count into the anchored value fixed the
    /// count and left uniqueness open: a duplicated final record stayed
    /// indistinguishable from a distinct one. Padding to a power of two with a
    /// filler that is not a record closes that, at no cost to proof length,
    /// which is ceil(log2(n)) either way.
    ///
    /// It cannot collide with a record leaf: a canonical record preimage begins
    /// with a domain tag and carries eight tab separators and a trailing
    /// newline, and this preimage carries neither.
    bytes32 public constant EMPTY_LEAF = keccak256("HCOWv1|empty-leaf");

    /// @notice How a tree is built from leaves, published for the same reason
    ///         the leaf rule is. `_verify` shows the checking half; this states
    ///         the building half, which a verifier otherwise has to take from
    ///         our JavaScript.
    string public constant TREE_RULE =
        "pad leaves with EMPTY_LEAF to a power of two; "
        "node=keccak256(0x01||min(a,b)||max(a,b)); "
        "anchored=keccak256(0x02||root||uint64 recordCount)";

    /// @notice The value anchored for a period that genuinely had no rounds.
    ///
    /// A zero root used to mean "empty", which is also what an epoch that was
    /// never anchored reads as, so `getEpoch(e).root == 0` could not tell an
    /// attestation apart from an absence. This constant is a positive
    /// statement: the operator anchored this period and states it was empty.
    /// It is excluded from the replay guard, because empty periods legitimately
    /// repeat.
    bytes32 public constant EMPTY_PERIOD = keccak256("HCOWv1|empty-period");

    /**
     * @notice Length of one period, in seconds. An epoch may only be anchored
     *         once the period it covers has finished.
     *
     * @dev BNB Chain block times are short and, since BEP-520, block.timestamp
     *      can be IDENTICAL across consecutive blocks. Nothing here is keyed on
     *      a timestamp being unique or strictly increasing: an epoch is a
     *      bucket, timestamp / EPOCH_SECONDS, and two blocks landing in the
     *      same bucket is the normal case rather than an anomaly. Replay is
     *      prevented by the per-epoch and per-root guards, not by time.
     *
     *      It does matter off chain. An indexer that assumes one block per
     *      timestamp, or that orders events by timestamp alone, will merge or
     *      reorder anchors that happened in different blocks. Order by
     *      (blockNumber, logIndex).
     */
    uint64 public constant EPOCH_SECONDS = 3600;

    /// @notice Proven anchorers required before ownership may be renounced.
    ///         Two, because renouncement removes `setAnchorer` forever and one
    ///         key is then a single point of permanent failure in both
    ///         directions: lost, and the ledger can never advance; stolen, and
    ///         nobody can revoke it.
    uint256 public constant MIN_ANCHORERS_TO_RENOUNCE = 2;

    /// @notice First epoch this deployment will accept. Set at construction to
    ///         the current period, so the anchoring worker, which derives the
    ///         period from the wall clock, has the same origin the contract
    ///         does. A deployment starting at zero would need one catch up
    ///         transaction for every hour since 1970 before it could anchor
    ///         the current one, and there is no path to skip them.
    uint64 public immutable genesisEpoch;

    address public owner;
    /// @notice Nominated owner. Not the owner until it calls acceptOwnership.
    address public pendingOwner;
    mapping(address => bool) public isAnchorer;
    /// @notice Anchorers that have actually written to this contract at least
    ///         once, and are still permitted. Renouncing is refused unless one
    ///         exists: `anchorerCount` alone is satisfied by an address nobody
    ///         controls, which is the same dead ledger with a guard in front
    ///         of it.
    mapping(address => bool) public hasAnchored;
    uint256 public provenAnchorerCount;
    /// @notice How many addresses may anchor. Renouncing ownership is refused
    ///         while this is zero, because that combination is unrecoverable.
    uint256 public anchorerCount;

    /// @notice Next live epoch expected. Also the count of anchored epochs.
    uint64 public nextEpoch;
    /// @notice Number of historical backfill batches recorded.
    uint64 public historicalBatchCount;
    /// @notice Total records covered by live epochs.
    uint256 public totalLiveRecords;
    /// @notice Total records covered by historical batches.
    uint256 public totalHistoricalRecords;

    /**
     * @notice Roots already anchored to a live epoch, so a receipt cannot be
     *         made to verify in more than one period.
     *
     * Deliberately NOT written by anchorHistorical, which has its own map.
     * Live epochs are strictly sequential with no way to move the cursor, so
     * anything that can make the next epoch's root unusable stops the ledger
     * for good, and a shared map would let a stolen anchorer key poison a
     * pending live root by front running it with a backfill. Two live epochs
     * cannot honestly share a root anyway: round ids differ, so their leaf sets
     * differ, and empty periods are excluded below.
     */
    mapping(bytes32 => bool) public rootAnchored;

    /// @notice Roots already anchored as a backfill. Kept apart from
    ///         `rootAnchored` so a backfill can never make a live root
    ///         unusable, which would stop the ledger permanently.
    mapping(bytes32 => bool) public historicalRootAnchored;

    mapping(uint64 => Anchor) private _epochs;
    mapping(uint64 => HistoricalBatch) private _historical;

    event EpochAnchored(uint64 indexed epoch, bytes32 root, uint64 recordCount, uint64 anchoredAt);
    event HistoricalBatchAnchored(
        uint64 indexed batchId,
        bytes32 root,
        uint64 recordCount,
        uint64 coversFrom,
        uint64 coversTo,
        uint64 anchoredAt
    );
    event AnchorerSet(address indexed account, bool allowed);
    event OwnershipTransferred(address indexed from, address indexed to);
    event OwnershipTransferStarted(address indexed from, address indexed to);
    event OwnershipTransferCancelled(address indexed nominee);

    error NotOwner();
    error NotAnchorer();
    error WrongEpoch(uint64 expected, uint64 given);
    /// A record count with no root, or a root with no record count. Each names
    /// what was supplied, not what was missing.
    error RecordsWithoutRoot();
    error RootWithoutRecords();
    error BadRange();
    error EpochNotFinished(uint64 endsAt);
    error RootAlreadyAnchored(bytes32 root);
    error ZeroAddress();
    error NoAnchorerLeft();
    error NotPendingOwner();
    /// Renouncing with fewer proven anchorers than the permanent minimum.
    error NotEnoughProvenAnchorers(uint256 proven, uint256 required);
    /// A backfill range reaching into time the live path is responsible for.
    /// Names the first second this contract covers itself.
    error BackfillCoversLiveTime(uint64 genesisStart);
    /// An epoch with records may not be anchored as an empty period, and an
    /// empty period may not claim records.
    error EmptyPeriodWithRecords();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyAnchorer() {
        if (!isAnchorer[msg.sender]) revert NotAnchorer();
        _;
    }

    constructor(address initialOwner, address initialAnchorer) {
        if (initialOwner == address(0)) revert ZeroAddress();
        genesisEpoch = uint64(block.timestamp) / EPOCH_SECONDS;
        nextEpoch = genesisEpoch;
        owner = initialOwner;
        emit OwnershipTransferred(address(0), initialOwner);
        if (initialAnchorer != address(0)) {
            isAnchorer[initialAnchorer] = true;
            anchorerCount = 1;
            emit AnchorerSet(initialAnchorer, true);
        }
    }

    // ------------------------------------------------------------------
    // anchoring
    // ------------------------------------------------------------------

    /**
     * @notice Anchor one live period.
     * @param epoch  Must equal nextEpoch. Sequential by design.
     * @param root   The anchored value: keccak256(COUNT_PREFIX ++ merkleRoot
     *               ++ uint64 recordCount), or EMPTY_PERIOD if the period had
     *               no rounds. NOT the bare Merkle root, and NOT bytes32(0).
     * @param recordCount Number of leaves. Must be 0 exactly when root is 0.
     */
    function anchorEpoch(uint64 epoch, bytes32 root, uint64 recordCount) external onlyAnchorer {
        if (epoch != nextEpoch) revert WrongEpoch(nextEpoch, epoch);
        // A period with no rounds is stated, not implied by a zero. A zero
        // root is what an epoch that was never anchored also reads as, so it
        // is no longer accepted as an attestation at all.
        if (root == EMPTY_PERIOD) {
            if (recordCount != 0) revert EmptyPeriodWithRecords();
        } else {
            if (root == bytes32(0)) revert RecordsWithoutRoot();
            if (recordCount == 0) revert RootWithoutRecords();
        }

        // An epoch may only be anchored once its period has ended. Without
        // this a stolen anchorer key could burn a year of future periods for
        // pocket change, and revoking the key would not give them back.
        uint64 endsAt = (epoch + 1) * EPOCH_SECONDS;
        if (block.timestamp < endsAt) revert EpochNotFinished(endsAt);

        // Empty periods legitimately repeat, so the replay guard skips them.
        if (root != EMPTY_PERIOD) {
            if (rootAnchored[root]) revert RootAlreadyAnchored(root);
            rootAnchored[root] = true;
        }

        _markProven();

        _epochs[epoch] = Anchor({
            root: root,
            recordCount: recordCount,
            anchoredAt: uint64(block.timestamp)
        });

        // Deliberately checked. An unchecked increment would wrap at
        // type(uint64).max and hand back epoch 0, which is the one thing
        // this contract exists to prevent. The gas saving is not worth it.
        nextEpoch = epoch + 1;
        totalLiveRecords += recordCount;

        emit EpochAnchored(epoch, root, recordCount, uint64(block.timestamp));
    }

    /**
     * @notice Anchor a backfill of records that predate this contract.
     * @dev Deliberately separate from anchorEpoch. This proves the data has
     *      not changed since now, not that it existed earlier.
     */
    function anchorHistorical(
        bytes32 root,
        uint64 recordCount,
        uint64 coversFrom,
        uint64 coversTo
    ) external onlyAnchorer returns (uint64 batchId) {
        if (root == bytes32(0) || root == EMPTY_PERIOD) revert RecordsWithoutRoot();
        if (recordCount == 0) revert RootWithoutRecords();
        if (coversFrom == 0 || coversTo < coversFrom) revert BadRange();
        // A backfill covers the past by definition, and "the past" means before
        // this contract existed, not merely before now. Bounded at the current
        // time instead, a backfill could claim hours the live path has already
        // anchored and the same records were counted in both totals: measured,
        // one thousand records reported as two thousand across the two
        // counters. This is also what stops a stolen anchorer key from pushing
        // the backfill horizon to the present in one transaction and locking
        // out every genuine archive after it.
        uint64 genesisStart = genesisEpoch * EPOCH_SECONDS;
        if (coversTo >= genesisStart) revert BackfillCoversLiveTime(genesisStart);

        // A separate guard, not `rootAnchored`. Writing a backfill root into
        // the live map would let a stolen anchorer key poison the next live
        // epoch's root by front running it, which is the reason that map is
        // deliberately not written here.
        //
        // This is what stops the trigger the finding names: an ordinary retry
        // after a dropped connection resubmits the identical batch, and the
        // identical batch has the identical root. Measured on the previous
        // code, one 50,000 record backfill submitted ten times reported 500,000
        // records; it is now refused on the second submission.
        //
        // WHAT IT DOES NOT STOP, stated rather than papered over: a tree
        // rebuilt over the same rounds in a different order, or with one extra
        // round, is a DIFFERENT root over the same period and passes. The
        // contract has no independent view of the record set, so
        // `totalHistoricalRecords` remains a figure the anchorer asserts, in
        // exactly the way the declared `recordCount` of a single batch is. It
        // must be published as such.
        //
        // An earlier version also required each range to start after the
        // previous one ended, which the finding offers as an optional extra
        // *if* batches are always submitted oldest first. They are not
        // necessarily: an older archive can be discovered after a newer one,
        // and two games' histories genuinely overlap in calendar time while
        // containing entirely different records. As an absolute rule it made
        // those permanently impossible and handed a stolen anchorer key a
        // one-transaction, irreversible denial of all future backfill. The
        // owner-only escape hatch added to relieve that was worse: lowering the
        // horizon re-opened the very double count the rule existed to prevent,
        // and the same 50,000 records could then be published as 100,000 by an
        // owner that had granted itself the anchorer role. A guard that has to
        // be disarmed to be usable, and that reintroduces the finding when
        // disarmed, is not a guard.
        if (historicalRootAnchored[root]) revert RootAlreadyAnchored(root);
        historicalRootAnchored[root] = true;

        _markProven();

        batchId = historicalBatchCount;
        _historical[batchId] = HistoricalBatch({
            root: root,
            recordCount: recordCount,
            anchoredAt: uint64(block.timestamp),
            coversFrom: coversFrom,
            coversTo: coversTo
        });

        historicalBatchCount = batchId + 1;
        totalHistoricalRecords += recordCount;

        emit HistoricalBatchAnchored(
            batchId, root, recordCount, coversFrom, coversTo, uint64(block.timestamp)
        );
    }

    // ------------------------------------------------------------------
    // verification
    // ------------------------------------------------------------------

    /// @notice Verify a leaf against an anchored live epoch.
    function verifyEpochRecord(uint64 epoch, bytes32 leaf, bytes32[] calldata proof)
        external
        view
        returns (bool)
    {
        if (epoch >= nextEpoch || epoch < genesisEpoch) return false;
        return _verify(proof, _epochs[epoch].root, leaf, _epochs[epoch].recordCount);
    }

    /// @notice Verify a leaf against an anchored historical batch.
    function verifyHistoricalRecord(uint64 batchId, bytes32 leaf, bytes32[] calldata proof)
        external
        view
        returns (bool)
    {
        if (batchId >= historicalBatchCount) return false;
        return _verify(proof, _historical[batchId].root, leaf, _historical[batchId].recordCount);
    }

    /**
     * @dev Sorted pair hashing over a tree padded to a power of two. Proofs
     *      carry no direction bits.
     *
     * A leaf preimage is a domain tag followed by text. A node preimage is
     * NODE_PREFIX followed by two 32 byte hashes, so it is 65 bytes and begins
     * with a byte no domain tag starts with. Nothing that hashes as a node can
     * be re-presented as a record, and that is a property of the encoding
     * rather than an argument about how hard the collision would be.
     *
     * The proof length is also checked against the tree the root came from. A
     * caller cannot hand in an empty proof and have the root itself accepted
     * as a record. Callers still MUST compute the leaf from the record
     * themselves rather than accepting a bare hash from anyone, which is what
     * the published verifier does.
     */
    function _verify(
        bytes32[] calldata proof,
        bytes32 root,
        bytes32 leaf,
        uint64 recordCount
    ) private pure returns (bool) {
        if (root == bytes32(0) || root == EMPTY_PERIOD || recordCount == 0) return false;
        // Levels are padded to a power of two with EMPTY_LEAF, so every leaf
        // sits at the same depth and the proof length is fixed by the record
        // count. Anything else is a forgery attempt, including handing in the
        // root itself, or an internal node, with a shortened proof.
        if (proof.length != _proofDepth(recordCount)) return false;
        // The filler is not a record. It sits at leaf depth, so its proof has
        // the right length and would otherwise verify in every tree whose leaf
        // count is not a power of two. No record preimage can hash to it, so
        // nothing is exploitable through it, but a caller reading `true` as
        // "these 32 bytes are a committed record" would be wrong, and the
        // documented property here is that nothing which is not a leaf can be
        // presented as one.
        if (leaf == EMPTY_LEAF) return false;

        bytes32 h = leaf;
        for (uint256 i = 0; i < proof.length; ++i) {
            bytes32 p = proof[i];
            h = h <= p
                ? keccak256(abi.encodePacked(NODE_PREFIX, h, p))
                : keccak256(abi.encodePacked(NODE_PREFIX, p, h));
        }
        // The record count is folded in before the comparison, so the anchored
        // value commits to the pair rather than to the tree alone. See
        // COUNT_PREFIX: without this a tree of n leaves and a tree of n + 1
        // whose last leaf repeats the n-th are the same root, and the declared
        // count was a claim nothing could contradict.
        return keccak256(abi.encodePacked(COUNT_PREFIX, h, recordCount)) == root;
    }

    /// @dev Levels in a tree of `n` leaves. Every leaf sits at the same depth,
    ///      so this is the exact proof length.
    ///
    ///      Previously wrapped in `unchecked`, justified by an `n + 1` that
    ///      does not appear here and never did: the comment described an
    ///      earlier implementation, and a reader had to verify that a block
    ///      claiming to be load bearing was in fact dead weight. The halving
    ///      expression is bounded above by its own input and `d` is bounded at
    ///      64, so nothing here can overflow. At most 64 iterations the saving
    ///      was negligible and this is one less thing to check.
    function _proofDepth(uint64 n) private pure returns (uint256 d) {
        while (n > 1) {
            n = (n >> 1) + (n & 1);
            ++d;
        }
    }

    // ------------------------------------------------------------------
    // the leaf rule, as executable code
    // ------------------------------------------------------------------

    /**
     * @notice The leaf hash for a seeded record, computed here rather than
     *         described. Pure, free to call, and the authoritative definition.
     *
     * @dev Publishing the two domain tags and a prose rule was half a rule. A
     *      verifier that knows the tag but not the field order, the separator
     *      or the escaping still has to take the rest from a document, or from
     *      our JavaScript, which is the one thing a proof exists to make
     *      unnecessary. These two functions are that rule as code: hand them a
     *      record and they return the exact 32 bytes the tree was built from,
     *      with no off-chain step in between.
     *
     *      Integers are passed already rendered, because base ten rendering of
     *      an arbitrary integer in Solidity is code with its own failure modes
     *      and no reader would trust it more than they trust their own. The
     *      rendering rule is one line and is in LEAF_RULE: base ten, no
     *      separators, no sign, no exponent.
     *
     *      Field order is FIELDS_SEEDED, published above.
     */
    function leafSeeded(string[9] calldata fields) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(LEAF_DOMAIN_SEEDED, _join(fields)));
    }

    /// @notice The leaf hash for a skill record. Field order is FIELDS_SKILL.
    function leafSkill(string[9] calldata fields) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(LEAF_DOMAIN_SKILL, _join(fields)));
    }

    /**
     * @dev Tab between fields, newline after the last. Both kinds have nine
     *      fields, which is why one helper serves both; the order is what
     *      differs and it is published as FIELDS_SEEDED and FIELDS_SKILL.
     *
     * WHY THIS IS NOT THE abi.encodePacked COLLISION BUG.
     *
     * Static analysis flags this line, and a human assessor applying EEA
     * EthTrust `req-1-no-hashing-consecutive-variable-length-args` will flag it
     * too. Both are right to look. The Solidity manual's example is
     * `abi.encodePacked("a", "bc") == abi.encodePacked("ab", "c")`: with two
     * adjacent variable-length operands and no delimiter, the boundary is not
     * recoverable and a collision is trivial.
     *
     * The delimiter is the documented mitigation for exactly this, and the
     * argument that it works here is two lemmas. Write them out rather than
     * asserting the conclusion, because the conclusion is what everyone
     * asserts and the lemmas are what an assessor has to check.
     *
     *   Let E be the escape map in `_esc`, and
     *     F(f1..f9) = E(f1) ++ 09 ++ E(f2) ++ 09 ++ ... ++ E(f9) ++ 0a
     *
     *   LEMMA A, separator exclusion. For every input f, E(f) contains no raw
     *   0x09 and no raw 0x0a. Immediate from the definition: those are the
     *   only two bytes replaced, and the replacements are 5c 74 and 5c 6e,
     *   which introduce neither. So the eight 0x09 bytes and the one 0x0a in
     *   F are exactly the field boundaries, and a left to right scan recovers
     *   the nine escaped segments uniquely.
     *
     *   LEMMA B, E is injective. E is a prefix-free code with an explicit left
     *   to right decoder D: read bytes; on 0x5c consume the next and emit a
     *   backslash, 0x09 or 0x0a for 5c, 74, 6e; otherwise emit the byte.
     *   D(E(f)) = f for every f.
     *
     *   `_esc` implements E as a SINGLE PASS over the input bytes, with three
     *   mutually exclusive branches. That is stronger than it looks and it is
     *   worth stating: the three cases cannot interfere, so the order they are
     *   written in does not matter and cannot be got wrong. A sequential
     *   implementation is a different matter, and `lib/canonical.js` is one:
     *   there the backslash MUST be replaced first, or a literal backslash-t
     *   in the input and a real tab both become the same two bytes. That file
     *   carries its own note, and the round trip is fuzzed there.
     *
     *   A and B together give F injective. `lib/canonical.js` ships D as
     *   `unescape`, and `test/ledger.test.cjs` fuzzes D(E(f)) == f over
     *   arbitrary byte strings, so Lemma B is executable rather than asserted.
     *
     * The outer call is a separate question and a simpler one. Its two
     * operands are a compile-time `string constant` of fixed length seven and
     * the join, so the precondition of the warning, BOTH operands variable, is
     * not met. The two domain tags are the same length and differ, so the two
     * record kinds cannot collide either.
     *
     * The repeated `abi.encodePacked(out, ...)` reallocates on each of the nine
     * iterations. It is quadratic in a loop bounded at nine, in an `external
     * pure` function nobody pays gas for. Recorded so it is not raised twice.
     */
    function _join(string[9] calldata fields) private pure returns (bytes memory out) {
        for (uint256 i = 0; i < 9; ++i) {
            out = abi.encodePacked(out, _esc(fields[i]), i == 8 ? "\n" : "\t");
        }
    }

    /**
     * @dev The escaping, byte for byte: backslash becomes two backslashes, tab
     *      becomes backslash-t, newline becomes backslash-n.
     *
     *      One pass, three mutually exclusive branches on a single byte, so no
     *      case can see the output of another and the branch order is not
     *      load-bearing. A sequential three-replacement implementation, which
     *      is what `lib/canonical.js` uses, IS order dependent: the backslash
     *      has to go first there or it doubles the backslashes the other two
     *      rules introduce. Both produce the same bytes, and the differential
     *      test in `test/ledger.test.cjs` is what keeps them that way.
     *
     *      Without it a value containing a tab could fake a field delimiter and
     *      two different records could canonicalise to the same bytes.
     */
    function _esc(string calldata field) private pure returns (bytes memory out) {
        bytes calldata b = bytes(field);
        uint256 n = b.length;
        uint256 extra;
        for (uint256 i = 0; i < n; ++i) {
            bytes1 c = b[i];
            if (c == 0x5c || c == 0x09 || c == 0x0a) ++extra;
        }
        out = new bytes(n + extra);
        uint256 j;
        for (uint256 i = 0; i < n; ++i) {
            bytes1 c = b[i];
            if (c == 0x5c)      { out[j++] = 0x5c; out[j++] = 0x5c; }
            else if (c == 0x09) { out[j++] = 0x5c; out[j++] = 0x74; } // \t
            else if (c == 0x0a) { out[j++] = 0x5c; out[j++] = 0x6e; } // \n
            else                { out[j++] = c; }
        }
    }

    // ------------------------------------------------------------------
    // views
    // ------------------------------------------------------------------

    /// @notice The anchor for a period. `anchoredAt == 0` is the sentinel for a
    ///         period that was never anchored: every real anchor records a
    ///         non-zero block timestamp. Do not read a zero `root` as "empty",
    ///         which is what the removed convention meant. Use `isEmptyPeriod`.
    function getEpoch(uint64 epoch) external view returns (Anchor memory) {
        return _epochs[epoch];
    }

    function getHistoricalBatch(uint64 batchId) external view returns (HistoricalBatch memory) {
        return _historical[batchId];
    }

    /// @notice True when the operator anchored this period and stated it had
    ///         no rounds. False both for a period with records and for one
    ///         that was never anchored, which the old zero root conflated.
    function isEmptyPeriod(uint64 epoch) external view returns (bool) {
        return epoch >= genesisEpoch
            && epoch < nextEpoch
            && _epochs[epoch].root == EMPTY_PERIOD;
    }

    function isEpochAnchored(uint64 epoch) external view returns (bool) {
        // Both bounds. nextEpoch starts at genesisEpoch, which is a real hour
        // index near half a million, so testing only the upper bound reports
        // every epoch since 1970 as anchored.
        return epoch >= genesisEpoch && epoch < nextEpoch;
    }

    function totalRecords() external view returns (uint256) {
        return totalLiveRecords + totalHistoricalRecords;
    }

    // ------------------------------------------------------------------
    // administration. none of this can alter an anchored root.
    // ------------------------------------------------------------------

    function setAnchorer(address account, bool allowed) external onlyOwner {
        if (account == address(0)) revert ZeroAddress();
        bool was = isAnchorer[account];
        if (was == allowed) return;
        if (allowed) {
            anchorerCount += 1;
        } else {
            // Removing the last anchorer while an owner is still here is
            // recoverable, so it is allowed. Doing it and then renouncing is
            // not, which is what the guard below refuses.
            anchorerCount -= 1;
            if (hasAnchored[account]) {
                provenAnchorerCount -= 1;
                // Cleared, not merely uncounted. Left set, re-adding the same
                // address later would restore provenAnchorerCount without
                // anyone proving anything, and the renounce guard would pass
                // on a key that was rotated out months earlier. The guard is
                // meant to evidence a live key, so proof does not survive
                // removal: a re-added anchorer must anchor again.
                hasAnchored[account] = false;
            }
        }
        isAnchorer[account] = allowed;
        emit AnchorerSet(account, allowed);
    }

    /**
     * @notice Step one of two. The nominee is not the owner until it accepts.
     *
     * @dev A single step wrote the address immediately, so a mistyped or
     *      unreachable one ended the ability to add or remove an anchorer,
     *      permanently and with no recovery. Nominating again replaces a
     *      standing nomination, which is how one is withdrawn.
     */
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    /// @notice Step two of two, called by the nominee itself. This is what
    ///         proves the address is reachable.
    /// @notice Withdraw a standing nomination without handing the role to
    ///         anyone. `transferOwnership(address(0))` is refused, so without
    ///         this the only way to cancel was to nominate the current owner
    ///         and accept.
    function cancelOwnershipTransfer() external onlyOwner {
        address was = pendingOwner;
        if (was == address(0)) revert ZeroAddress();
        pendingOwner = address(0);
        emit OwnershipTransferCancelled(was);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        emit OwnershipTransferred(owner, msg.sender);
        owner = msg.sender;
        pendingOwner = address(0);
    }

    /// @notice Give up administration permanently. Existing anchorers keep
    /// writing, and the permission set can never change again.
    ///
    /// @dev Refused while there is no anchorer left. Epochs are strictly
    ///      sequential and there is no cursor override, so an ownerless
    ///      contract with an empty anchorer set can never anchor again and the
    ///      ledger is dead: two ordinary administrative calls in the wrong
    ///      order and the audit trail stops for good. Renouncing is meant to
    ///      be the act that proves nothing can be tampered with, not the one
    ///      that ends the record.
    function renounceOwnership() external onlyOwner {
        // Not `anchorerCount`. That counter is satisfied by any address the
        // owner typed in, including one nobody holds the key to, so the guard
        // could be passed while leaving exactly the dead ledger it exists to
        // prevent. An anchorer counts here only once it has actually written
        // to this contract, which no address can do without its key.
        //
        // TWO, not one. After this call `setAnchorer` is dead forever, so a
        // single proven anchorer is a single point of permanent failure in
        // both directions at once: lose the key and the ledger can never
        // advance again, and there is no owner to grant a replacement; have
        // the key stolen and the thief anchors a false root for every future
        // epoch, indefinitely, with nobody able to revoke it. A tamper
        // evidence log that still looks authoritative while being written by
        // an attacker is worse than one that has stopped.
        //
        // A second proven key makes the first recoverable in the compromise
        // direction, through `revokeSelf` below, which is why that function
        // exists and why it survives renouncement.
        if (provenAnchorerCount < MIN_ANCHORERS_TO_RENOUNCE) {
            revert NotEnoughProvenAnchorers(provenAnchorerCount, MIN_ANCHORERS_TO_RENOUNCE);
        }
        emit OwnershipTransferred(owner, address(0));
        owner = address(0);
        pendingOwner = address(0);
    }

    /**
     * @notice An anchorer removing itself. Survives renouncement, which is the
     *         whole point.
     *
     * @dev After the owner has renounced, `setAnchorer` is gone and there is
     *      no path by which a compromised anchorer key can be taken out of the
     *      permission set. This is that path, and only the key holder can walk
     *      it: an attacker in possession of the key gains nothing by burning
     *      it, and the legitimate holder who knows the key is compromised can
     *      stop it writing.
     *
     *      Refused when it would leave the ledger with no proven anchorer, so
     *      it cannot be turned into the denial it exists to prevent. Combined
     *      with the two-anchorer requirement on renouncement, an ownerless
     *      ledger always keeps at least one live writer.
     *
     *      It DOES clear `hasAnchored`, exactly as the removal branch of
     *      `setAnchorer` does and for the same reason: proof is meant to
     *      evidence a live key, so it must not survive the key leaving the
     *      permission set. If the owner is still present and re-adds the
     *      address, `setAnchorer` restores `anchorerCount` but NOT
     *      `provenAnchorerCount`; the re-added address has to anchor once more
     *      to become proven again. An earlier version of this comment claimed
     *      the opposite, which would have sent an operator following a key
     *      rotation runbook into an unexplained `NotEnoughProvenAnchorers`.
     *
     *      Operationally, note what two proven anchorers actually buys after
     *      renouncement: exactly one recovery. Revoke a compromised key and
     *      the count is one, and the remaining key can no longer revoke
     *      itself, because doing so would leave the ledger unwritable forever.
     *      An operator who intends to renounce should configure MORE than two
     *      anchorers and let each anchor once first, so there is a spare per
     *      compromise rather than a single one for the life of the contract.
     */
    function revokeSelf() external {
        if (!isAnchorer[msg.sender]) revert NotAnchorer();
        if (hasAnchored[msg.sender] && provenAnchorerCount <= 1) revert NoAnchorerLeft();
        isAnchorer[msg.sender] = false;
        anchorerCount -= 1;
        if (hasAnchored[msg.sender]) {
            provenAnchorerCount -= 1;
            hasAnchored[msg.sender] = false;
        }
        emit AnchorerSet(msg.sender, false);
    }

    /// @dev Called on every successful anchor. The first write by a permitted
    ///      anchorer is what turns a configured address into a proven one.
    function _markProven() private {
        if (!hasAnchored[msg.sender]) {
            hasAnchored[msg.sender] = true;
            provenAnchorerCount += 1;
        }
    }
}
