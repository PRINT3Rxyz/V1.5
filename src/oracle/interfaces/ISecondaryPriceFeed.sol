// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

interface ISecondaryPriceFeed {
    function getPrice(address _token, uint256 _referencePrice, bool _maximise) external view returns (uint256);
    function setPythId(address _token, bytes32 _pythId) external;
}
