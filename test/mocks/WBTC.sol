// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import "../../src/libraries/token/ERC20.sol";

/// @notice This is a Mock Token for testing purposes only.
contract WBTC is ERC20 {
    constructor() ERC20("Wrapped BTC", "WBTC", 8) {}

    function mint(address account, uint256 amount) public {
        _mint(account, amount);
    }
}
