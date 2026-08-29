// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;
import {Test} from "forge-std/Test.sol";
import {HCOWLedger} from "../contracts/HCOWLedger.sol";

/// The leaf/node separation is by the first byte and is unconditional.
contract LeafSeparation is Test {
    HCOWLedger internal l;
    function setUp() public { l = new HCOWLedger(address(this), address(this)); }

    function test_everyLeafPreimageStartsWithTheDomainTagNotANodePrefix() public view {
        bytes memory a = bytes(l.LEAF_DOMAIN_SEEDED());
        bytes memory b = bytes(l.LEAF_DOMAIN_SKILL());
        assertEq(a[0], bytes1("H"));
        assertEq(b[0], bytes1("H"));
        assertTrue(a[0] != l.NODE_PREFIX());
        assertTrue(a[0] != l.COUNT_PREFIX());
        assertTrue(b[0] != l.NODE_PREFIX());
        assertTrue(b[0] != l.COUNT_PREFIX());
    }

    /// And the length argument the old comment used really is false: a leaf
    /// preimage of exactly 65 bytes, the length of a node preimage, is an
    /// ordinary record. It still cannot collide, because of the first byte.
    function test_aSixtyFiveBytePreimageIsReachableAndStillCannotCollide() public view {
        string[9] memory f;
        f[0] = "abcdefg";          // 7
        for (uint256 i = 1; i < 9; ++i) f[i] = "abcdef";   // 6 x 8 = 48, total 55
        // 7 domain + 55 values + 8 tabs + 1 newline = 71; trim to hit 65
        f[0] = "a";
        for (uint256 i = 1; i < 9; ++i) f[i] = "abcde";    // 1 + 40 = 41
        // 7 + 41 + 9 = 57. Add 8 more bytes.
        f[1] = "abcdefghijkl";                              // +7 -> 48
        f[2] = "abcdef";                                    // +1 -> 49
        uint256 vals;
        for (uint256 i = 0; i < 9; ++i) vals += bytes(f[i]).length;
        assertEq(7 + vals + 9, 65, "a 65 byte leaf preimage is an ordinary record");
        // it hashes, and it is not a node hash, because the domains differ
        assertTrue(l.leafSeeded(f) != keccak256(abi.encodePacked(l.NODE_PREFIX(), bytes32(0), bytes32(0))));
    }
}
