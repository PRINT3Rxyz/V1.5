// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IVaultAfterHook {
    function afterTrade(address user, uint256 volume) external;
}
