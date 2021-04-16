// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "./libs/ownable.sol";
import "./libs/bep20.sol";

contract TuttiFruttiFinance is BEP20("Tutti Frutti", "TFF"), Ownable {
    bool public initialized;

    uint256 private constant REWARDS_PERCENTAGE = 30;
    uint256 private constant FOUNDATION_PERCENTAGE = 30;
    uint256 private constant MARKETING_PERCENTAGE = 20;
    uint256 private constant ECOSYSTEM_PERCENTAGE = 10;
    uint256 private constant AIRDROP_PERCENTAGE = 10;
    uint256 private constant BASE_PERCENTAGE = 100;

    function initialize(
        address rewards, 
        address foundation,
        address marketing,
        address ecosystem,
        address airdrop
    ) external onlyOwner {
        require(!initialized, '!initialized');
        uint256 max_supply = 950000000000000000000000000; // 950,000,000 TFF
        _mint(rewards, max_supply.mul(REWARDS_PERCENTAGE).div(BASE_PERCENTAGE));
        _mint(foundation, max_supply.mul(FOUNDATION_PERCENTAGE).div(BASE_PERCENTAGE));
        _mint(marketing, max_supply.mul(MARKETING_PERCENTAGE).div(BASE_PERCENTAGE));
        _mint(ecosystem, max_supply.mul(ECOSYSTEM_PERCENTAGE).div(BASE_PERCENTAGE));
        _mint(airdrop, max_supply.mul(AIRDROP_PERCENTAGE).div(BASE_PERCENTAGE));
        initialized = true;
    }

    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
}