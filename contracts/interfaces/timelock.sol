// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

interface ITimelock {
    function MINIMUM_DELAY() external view returns (uint);
    function MAXIMUM_DELAY() external view returns (uint);
    function delay() external view returns (uint);
}