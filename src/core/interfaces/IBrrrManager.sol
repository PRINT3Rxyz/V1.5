// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IVault.sol";

interface IBrrrManager {
    function brrr() external view returns (address);

    function vault() external view returns (IVault);

    function collateralToken() external view returns (address);

    function cooldownDuration() external returns (uint256);

    function getAumInUsdp(bool maximise) external view returns (uint256);

    function estimateBrrrOut(uint256 _amount) external view returns (uint256);

    function estimateTokenIn(uint256 _brrrAmount) external view returns (uint256);

    function lastAddedAt(address _account) external returns (uint256);

    function addLiquidity(uint256 _amount, uint256 _minUsdp, uint256 _minBrrr) external returns (uint256);

    function addLiquidityForAccount(
        address _fundingAccount,
        address _account,
        uint256 _amount,
        uint256 _minUsdp,
        uint256 _minBrrr
    ) external returns (uint256);

    function removeLiquidity(uint256 _brrrAmount, uint256 _minOut, address _receiver) external returns (uint256);

    function removeLiquidityForAccount(address _account, uint256 _brrrAmount, uint256 _minOut, address _receiver)
        external
        returns (uint256);

    function setShortsTrackerAveragePriceWeight(uint256 _shortsTrackerAveragePriceWeight) external;

    function setCooldownDuration(uint256 _cooldownDuration) external;
}
