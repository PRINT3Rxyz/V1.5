// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {PositionHandler} from "./handler/PositionHandler.sol";

contract TestPositions is Test {
    PositionHandler handler;

    function setUp() public {
        handler = new PositionHandler();
        targetContract(address(handler));
    }

    function invariant_can_always_open_valid_positions() public {}
}
