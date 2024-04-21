// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

interface IPositionRouter {
    function increasePositionRequestKeysStart() external returns (uint256);

    function decreasePositionRequestKeysStart() external returns (uint256);

    function executeIncreasePositions(uint256 _count, address payable _executionFeeReceiver) external;

    function executeDecreasePositions(uint256 _count, address payable _executionFeeReceiver) external;

    function executeIncreasePosition(bytes32 _key, address payable _executionFeeReceiver) external returns (bool);

    function cancelIncreasePosition(bytes32 _key, address payable _executionFeeReceiver) external returns (bool);

    function executeDecreasePosition(bytes32 _key, address payable _executionFeeReceiver) external returns (bool);

    function cancelDecreasePosition(bytes32 _key, address payable _executionFeeReceiver) external returns (bool);

    function setPositionKeeper(address _account, bool _isActive) external;

    function getRequestQueueLengths() external view returns (uint256, uint256, uint256, uint256);

    function increasePositionRequestKeys(uint256 index) external view returns (bytes32);

    function decreasePositionRequestKeys(uint256 index) external view returns (bytes32);
}
