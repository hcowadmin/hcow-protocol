// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// Local rehearsal only. Answers the two Safe{Wallet} views the mainnet
/// preflight reads, from immutables, so its runtime code can be copied onto a
/// real Safe address on a local node with no storage to carry over.
contract MockSafe {
    address private immutable a;
    address private immutable b;
    address private immutable c;
    uint256 private immutable t;

    constructor(address a_, address b_, address c_, uint256 t_) {
        a = a_; b = b_; c = c_; t = t_;
    }

    function getThreshold() external view returns (uint256) { return t; }

    function getOwners() external view returns (address[] memory o) {
        o = new address[](3);
        o[0] = a; o[1] = b; o[2] = c;
    }
}
