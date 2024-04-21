// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IFastPriceFeed {
    function pythIds(address token) external view returns (bytes32);

    function getUpdateFee(bytes[] calldata priceUpdateData) external view returns (uint256 fee);

    function updatePriceFeeds(bytes[] calldata priceUpdateData, address refundee) external payable;

    function getOffchainPrice(address _token, uint256 _offchainPrice, bool _maximise) external view returns (uint256);

    function setUpdater(address _account, bool _isActive) external;

    function setPricesAndExecute(
        address _positionRouter,
        bytes[] calldata _priceUpdateData,
        uint256 _endIndexForIncreasePositions,
        uint256 _endIndexForDecreasePositions,
        uint256 _maxIncreasePositions,
        uint256 _maxDecreasePositions
    ) external;
}
