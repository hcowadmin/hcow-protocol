// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

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
 *   epoch n-1. A period with no rounds is still anchored, with a zero root
 *   and a zero count, so the sequence can never contain a silent hole.
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

    /// @notice Prefix on every internal node hash. Leaf preimages begin with a
    ///         domain tag and are not 65 bytes, so no node preimage can ever
    ///         be read as a leaf preimage. This makes the separation
    ///         structural rather than a statement about how hard it would be
    ///         to steer two keccak outputs into a valid record layout.
    /// Public for the same reason the two leaf domains are: an independent
    /// verifier must be able to read every part of the hashing rule off the
    /// chain rather than take it from a document that could be edited.
    bytes1 public constant NODE_PREFIX = 0x01;

    /// @notice Length of one period, in seconds. An epoch may only be anchored
    ///         once the period it covers has finished.
    uint64 public constant EPOCH_SECONDS = 3600;

    /// @notice First epoch this deployment will accept. Set at construction to
    ///         the current period, so the anchoring worker, which derives the
    ///         period from the wall clock, has the same origin the contract
    ///         does. A deployment starting at zero would need one catch up
    ///         transaction for every hour since 1970 before it could anchor
    ///         the current one, and there is no path to skip them.
    uint64 public immutable genesisEpoch;

    address public owner;
    mapping(address => bool) public isAnchorer;
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
     * Deliberately NOT written by anchorHistorical. Live epochs are strictly
     * sequential with no way to move the cursor, so anything that can make the
     * next epoch's root unusable stops the ledger for good. Backfilling an
     * hour historically and then anchoring it live is an ordinary operational
     * sequence, and an unsequenced historical write would also let a stolen
     * key poison a pending live root by front running it. Two live epochs
     * cannot honestly share a root anyway: round ids differ, so their leaf
     * sets differ, and empty periods are excluded below.
     */
    mapping(bytes32 => bool) public rootAnchored;

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
     * @param root   Merkle root, or bytes32(0) if the period had no rounds.
     * @param recordCount Number of leaves. Must be 0 exactly when root is 0.
     */
    function anchorEpoch(uint64 epoch, bytes32 root, uint64 recordCount) external onlyAnchorer {
        if (epoch != nextEpoch) revert WrongEpoch(nextEpoch, epoch);
        if (root == bytes32(0) && recordCount != 0) revert RecordsWithoutRoot();
        if (root != bytes32(0) && recordCount == 0) revert RootWithoutRecords();

        // An epoch may only be anchored once its period has ended. Without
        // this a stolen anchorer key could burn a year of future periods for
        // pocket change, and revoking the key would not give them back.
        uint64 endsAt = (epoch + 1) * EPOCH_SECONDS;
        if (block.timestamp < endsAt) revert EpochNotFinished(endsAt);

        if (root != bytes32(0)) {
            if (rootAnchored[root]) revert RootAlreadyAnchored(root);
            rootAnchored[root] = true;
        }

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
        if (root == bytes32(0)) revert RecordsWithoutRoot();
        if (recordCount == 0) revert RootWithoutRecords();
        if (coversFrom == 0 || coversTo < coversFrom) revert BadRange();
        // A backfill covers the past by definition.
        if (coversTo > block.timestamp) revert BadRange();

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
     * @dev Sorted pair hashing. Proofs carry no direction bits.
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
        if (root == bytes32(0) || recordCount == 0) return false;
        // An odd node is paired with itself rather than promoted, so every
        // leaf sits at the same depth and the proof length is fixed by the
        // record count. Anything else is a forgery attempt, including handing
        // in the root itself, or an internal node, with a shortened proof.
        if (proof.length != _proofDepth(recordCount)) return false;

        bytes32 h = leaf;
        for (uint256 i = 0; i < proof.length; ++i) {
            bytes32 p = proof[i];
            h = h <= p
                ? keccak256(abi.encodePacked(NODE_PREFIX, h, p))
                : keccak256(abi.encodePacked(NODE_PREFIX, p, h));
        }
        return h == root;
    }

    /// @dev Levels in a tree of `n` leaves. An odd node is paired with itself,
    ///      so every leaf sits at the same depth and this is the exact proof
    ///      length. Unchecked because `n + 1` would overflow at
    ///      type(uint64).max and a view documented to return false must not
    ///      panic on a number it was simply handed.
    function _proofDepth(uint64 n) private pure returns (uint256 d) {
        unchecked {
            while (n > 1) {
                n = (n >> 1) + (n & 1);
                ++d;
            }
        }
    }

    // ------------------------------------------------------------------
    // views
    // ------------------------------------------------------------------

    function getEpoch(uint64 epoch) external view returns (Anchor memory) {
        return _epochs[epoch];
    }

    function getHistoricalBatch(uint64 batchId) external view returns (HistoricalBatch memory) {
        return _historical[batchId];
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
        }
        isAnchorer[account] = allowed;
        emit AnchorerSet(account, allowed);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
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
        if (anchorerCount == 0) revert NoAnchorerLeft();
        emit OwnershipTransferred(owner, address(0));
        owner = address(0);
    }
}
