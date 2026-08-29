// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {HCOWLedger} from "../contracts/HCOWLedger.sol";

/**
 * @title LeafEncodingTest
 * @notice The empirical half of the `_join` injectivity argument.
 *
 * The lemma is written out above `HCOWLedger._join`, and `lib/canonical.js`
 * ships the decoder that makes its second half executable. This is the other
 * thing an assessor expects alongside a proof: a machine trying to find the
 * collision.
 *
 * The shapes fuzzed here are the ones the Solidity manual's own example is
 * built from — moving bytes across a boundary between two adjacent
 * variable-length operands — plus the two the escaping exists for, a delimiter
 * inside a value and an escape character inside a value.
 */
contract LeafEncodingTest is Test {
    HCOWLedger internal c;

    function setUp() public {
        c = new HCOWLedger(address(this), address(this));
    }

    function _f(string memory a, string memory b) internal pure returns (string[9] memory f) {
        f[0] = a; f[1] = b;
        f[2] = "p"; f[3] = "h"; f[4] = "s"; f[5] = "c"; f[6] = "1"; f[7] = "o"; f[8] = "2";
    }

    /// The manual's example, directly: moving bytes from one field to the next
    /// must change the leaf. Without a delimiter, "a"+"bc" and "ab"+"c" collide.
    function test_movingBytesAcrossTheBoundaryChangesTheLeaf() public view {
        assertTrue(
            c.leafSeeded(_f("a", "bc")) != c.leafSeeded(_f("ab", "c")),
            "a field boundary can be moved without changing the leaf"
        );
        assertTrue(
            c.leafSeeded(_f("", "abc")) != c.leafSeeded(_f("abc", "")),
            "an empty field is absorbed by its neighbour"
        );
    }

    /// A delimiter inside a value must not be able to fake a field boundary.
    function test_aDelimiterInsideAValueCannotForgeABoundary() public view {
        assertTrue(
            c.leafSeeded(_f("a\tb", "p")) != c.leafSeeded(_f("a", "b")),
            "a tab inside a value forged a field boundary"
        );
        assertTrue(
            c.leafSeeded(_f("a\nb", "p")) != c.leafSeeded(_f("a", "b")),
            "a newline inside a value forged the terminator"
        );
    }

    /// The escape character itself. Escaping the backslash LAST would send a
    /// literal backslash-t and a real tab to the same two bytes; this is the
    /// assertion that notices if that order is ever changed.
    function test_aLiteralEscapeIsNotARealDelimiter() public view {
        assertTrue(
            c.leafSeeded(_f("a\\tb", "p")) != c.leafSeeded(_f("a\tb", "p")),
            "a literal backslash-t and a real tab produce the same leaf"
        );
        assertTrue(
            c.leafSeeded(_f("\\", "p")) != c.leafSeeded(_f("\\\\", "p")),
            "one backslash and two produce the same leaf"
        );
    }

    /// The two record kinds share the join, so only the domain tag separates
    /// them. Both tags are seven bytes and differ, so no field vector can move
    /// a record from one kind to the other.
    function test_theTwoKindsCannotCollide() public view {
        string[9] memory f = _f("a", "b");
        assertTrue(c.leafSeeded(f) != c.leafSkill(f), "the two record kinds collide");
    }

    /// Anything else the fuzzer can find. Two field vectors that differ must
    /// produce different leaves.
    function testFuzz_differentFieldsDifferentLeaf(
        string calldata a,
        string calldata b,
        string calldata x,
        string calldata y
    ) public view {
        vm.assume(bytes(a).length < 64 && bytes(b).length < 64);
        vm.assume(bytes(x).length < 64 && bytes(y).length < 64);
        if (keccak256(bytes(a)) == keccak256(bytes(x)) && keccak256(bytes(b)) == keccak256(bytes(y))) {
            assertEq(c.leafSeeded(_f(a, b)), c.leafSeeded(_f(x, y)), "equal fields gave different leaves");
        } else {
            assertTrue(
                c.leafSeeded(_f(a, b)) != c.leafSeeded(_f(x, y)),
                "two different field vectors produced the same leaf"
            );
        }
    }

    /// The join is deterministic: the same fields always give the same leaf.
    function testFuzz_deterministic(string calldata a, string calldata b) public view {
        vm.assume(bytes(a).length < 96 && bytes(b).length < 96);
        assertEq(c.leafSeeded(_f(a, b)), c.leafSeeded(_f(a, b)));
    }
}
