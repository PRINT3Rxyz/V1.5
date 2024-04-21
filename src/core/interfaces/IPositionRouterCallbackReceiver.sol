// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

interface IPositionRouterCallbackReceiver {
    function print3rPositionCallback(bytes32 positionKey, bool isExecuted, bool isIncrease) external;
}
