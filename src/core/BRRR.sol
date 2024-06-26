// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import "../tokens/MintableBaseToken.sol";

contract BRRR is MintableBaseToken {
    constructor() MintableBaseToken("BRRR-LP", "BRRR-LP", 0) {}

    function id() external pure returns (string memory _name) {
        return "BRRR-LP";
    }
}
