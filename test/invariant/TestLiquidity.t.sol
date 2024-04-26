// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {LiquidityHandler} from "./handler/LiquidityHandler.sol";

contract TestLiquidity is Test {
    LiquidityHandler handler;

    function setUp() public {
        handler = new LiquidityHandler();
        targetContract(address(handler));
    }

    function invariant_can_always_add_and_remove_liquidity() public {}
}
