// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

interface IRewardDistributor {
    function rewardToken() external view returns (address);
    function tokensPerInterval() external view returns (uint256);
    function pendingRewards() external view returns (uint256);
    function distribute() external returns (uint256);
    function setTokensPerInterval(uint256 _amount) external;
    function updateLastDistributionTime() external;
}
