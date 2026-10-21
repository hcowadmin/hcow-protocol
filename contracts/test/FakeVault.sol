// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// Test double. Answers HCOWProfitShare's vault checks with whatever it was
/// built with, so the constructor's refusal of each wrong answer can be shown.
contract FakeVault {
    address public hcow;
    address public staking;
    constructor(address hcow_, address staking_) {
        hcow = hcow_;
        staking = staking_;
    }
}
