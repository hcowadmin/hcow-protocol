// Sources flattened with hardhat v2.29.0 https://hardhat.org

// SPDX-License-Identifier: MIT

// File contracts/HCOWLedger.sol

// Original license: SPDX_License_Identifier: MIT
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

    /// @notice Domain separator that every leaf hash must be built with.
    /// Published on chain so verifiers never have to guess the format.
    string public constant LEAF_DOMAIN = "HCOWv1|";

    address public owner;
    mapping(address => bool) public isAnchorer;

    /// @notice Next live epoch expected. Also the count of anchored epochs.
    uint64 public nextEpoch;
    /// @notice Number of historical backfill batches recorded.
    uint64 public historicalBatchCount;
    /// @notice Total records covered by live epochs.
    uint256 public totalLiveRecords;
    /// @notice Total records covered by historical batches.
    uint256 public totalHistoricalRecords;

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
    error EmptyRootWithRecords();
    error RecordsWithEmptyRoot();
    error BadRange();
    error ZeroAddress();

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
        owner = initialOwner;
        emit OwnershipTransferred(address(0), initialOwner);
        if (initialAnchorer != address(0)) {
            isAnchorer[initialAnchorer] = true;
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
        if (root == bytes32(0) && recordCount != 0) revert EmptyRootWithRecords();
        if (root != bytes32(0) && recordCount == 0) revert RecordsWithEmptyRoot();

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
        if (root == bytes32(0) || recordCount == 0) revert RecordsWithEmptyRoot();
        if (coversFrom == 0 || coversTo < coversFrom) revert BadRange();

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
        if (epoch >= nextEpoch) return false;
        return _verify(proof, _epochs[epoch].root, leaf);
    }

    /// @notice Verify a leaf against an anchored historical batch.
    function verifyHistoricalRecord(uint64 batchId, bytes32 leaf, bytes32[] calldata proof)
        external
        view
        returns (bool)
    {
        if (batchId >= historicalBatchCount) return false;
        return _verify(proof, _historical[batchId].root, leaf);
    }

    /**
     * @dev Sorted pair hashing. Proofs carry no direction bits.
     *
     * Leaves are keccak256 over LEAF_DOMAIN followed by text, while internal
     * nodes are keccak256 over two concatenated 32 byte hashes. The two
     * inputs live in different domains, so an internal node cannot be
     * presented as a record. Callers still MUST compute the leaf from the
     * record themselves rather than accepting a bare hash from anyone, which
     * is what the published verifier does.
     */
    function _verify(bytes32[] calldata proof, bytes32 root, bytes32 leaf)
        private
        pure
        returns (bool)
    {
        if (root == bytes32(0)) return false;
        bytes32 h = leaf;
        for (uint256 i = 0; i < proof.length; ++i) {
            bytes32 p = proof[i];
            h = h <= p ? keccak256(abi.encodePacked(h, p)) : keccak256(abi.encodePacked(p, h));
        }
        return h == root;
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
        return epoch < nextEpoch;
    }

    function totalRecords() external view returns (uint256) {
        return totalLiveRecords + totalHistoricalRecords;
    }

    // ------------------------------------------------------------------
    // administration. none of this can alter an anchored root.
    // ------------------------------------------------------------------

    function setAnchorer(address account, bool allowed) external onlyOwner {
        if (account == address(0)) revert ZeroAddress();
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
    function renounceOwnership() external onlyOwner {
        emit OwnershipTransferred(owner, address(0));
        owner = address(0);
    }
}
