// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// Test double for HCOWToken: fixed supply, burnable.
contract MockHCOW is ERC20 {
    constructor() ERC20("HashCow", "HCOW") {
        _mint(msg.sender, 200_000_000e18);
    }
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
}

/// Test double for BSC-USD. 18 decimals, like the real one on BNB Chain.
contract MockUSDT is ERC20 {
    constructor() ERC20("BSC-USD", "USDT") {
        _mint(msg.sender, 100_000_000e18);
    }
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
