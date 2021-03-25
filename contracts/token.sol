// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "./libs/ownable.sol";
import "./libs/bep20.sol";

contract TuttiFruttiFinance is BEP20("Tutti Frutti", "TFF"), Ownable {
    bool public initialized;

    function initialize() external onlyOwner {
        require(!initialized, '!initialized');
        _mint(owner(), 950000000000000000000000000); // 950,000,000 TFF
        initialized = true;
    }

    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
}