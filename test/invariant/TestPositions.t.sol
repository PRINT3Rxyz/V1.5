// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {Handler} from "./handler/Handler.sol";

contract TestPositions is Test {
    Handler handler;

    function setUp() public {
        handler = new Handler();
        targetContract(address(handler));
    }

    function invariant_can_always_open_valid_positions() public {}
}
