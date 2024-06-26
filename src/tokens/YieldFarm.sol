// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import "../libraries/token/IERC20.sol";
import "../libraries/token/SafeTransferLib.sol";
import "../libraries/utils/ReentrancyGuard.sol";

import "./YieldToken.sol";

contract YieldFarm is YieldToken, ReentrancyGuard {
    using SafeTransferLib for IERC20;

    address public stakingToken;

    constructor(string memory _name, string memory _symbol, address _stakingToken) YieldToken(_name, _symbol, 0) {
        stakingToken = _stakingToken;
    }

    function stake(uint256 _amount) external nonReentrant {
        IERC20(stakingToken).safeTransferFrom(msg.sender, address(this), _amount);
        _mint(msg.sender, _amount);
    }

    function unstake(uint256 _amount) external nonReentrant {
        _burn(msg.sender, _amount);
        IERC20(stakingToken).safeTransfer(msg.sender, _amount);
    }
}
