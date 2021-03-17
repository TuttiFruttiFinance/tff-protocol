// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

interface IMaster {
    function lock(address, uint256) external;
    function unlock(address, uint256) external;
    function availableForRetirementFund(address) external returns (uint256);
}