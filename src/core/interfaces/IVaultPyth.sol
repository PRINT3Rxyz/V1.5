// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IVault} from "./IVault.sol";

interface IVaultPyth is IVault {
    function getDeltaAtPrice(
        uint256 _markPrice,
        address _indexToken,
        uint256 _size,
        uint256 _averagePrice,
        bool _isLong,
        uint256 _lastIncreasedTime
    ) external view returns (bool, uint256);

    function getMaxLeverage(address token) external view returns (uint256 _maxLeverage);
}
