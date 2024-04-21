// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../access/interfaces/IAdmin.sol";

interface IBasePositionManager is IAdmin {
    function maxGlobalLongSizes(address _token) external view returns (uint256);

    function maxGlobalShortSizes(address _token) external view returns (uint256);
}
