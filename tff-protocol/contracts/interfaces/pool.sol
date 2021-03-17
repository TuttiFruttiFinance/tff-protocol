// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

interface IPool {
    function depositFor(address account, uint256 amount) external;
    function setPaused(bool _paused) external;
    function setStakingToken(address _stakingToken) external;
    function notifyRewardAmount(uint256 reward) external;
    function setRewardsDuration(uint256 _rewardsDuration) external;
}