// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

interface IBrrrRewardRouter {
    function stakedBrrrTracker() external view returns (address);
    function initialize(address _weth, address _brrr, address _stakedBrrrTracker, address _brrrManager) external;

    function withdrawToken(address _token, address _account, uint256 _amount) external;

    function mintAndStakeBrrr(uint256 _amount, uint256 _minUsdg, uint256 _minBrrr) external returns (uint256);

    function unstakeAndRedeemBrrr(uint256 _brrrAmount, uint256 _minOut, address _receiver) external returns (uint256);

    function claim() external;

    function handleRewards() external;
}
