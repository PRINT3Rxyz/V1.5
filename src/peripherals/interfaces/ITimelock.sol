// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import "../../access/interfaces/IAdmin.sol";

interface ITimelock is IAdmin {
    function marginFeeBasisPoints() external view returns (uint256);

    function enableLeverage(address _vault) external;

    function disableLeverage(address _vault) external;

    function setIsLeverageEnabled(address _vault, bool _isLeverageEnabled) external;

    function signalSetGov(address _target, address _gov) external;
}
