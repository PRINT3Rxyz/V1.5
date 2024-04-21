// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import "../libraries/token/IERC20.sol";

import "../libraries/token/SafeTransferLib.sol";
import "../libraries/utils/ReentrancyGuard.sol";

import "../access/Governable.sol";

contract Bridge is ReentrancyGuard, Governable {
    using SafeTransferLib for IERC20;

    address public token;
    address public wToken;

    constructor(address _token, address _wToken) {
        token = _token;
        wToken = _wToken;
    }

    function wrap(uint256 _amount, address _receiver) external nonReentrant {
        IERC20(token).safeTransferFrom(msg.sender, address(this), _amount);
        IERC20(wToken).safeTransfer(_receiver, _amount);
    }

    function unwrap(uint256 _amount, address _receiver) external nonReentrant {
        IERC20(wToken).safeTransferFrom(msg.sender, address(this), _amount);
        IERC20(token).safeTransfer(_receiver, _amount);
    }

    // to help users who accidentally send their tokens to this contract
    function withdrawToken(address _token, address _account, uint256 _amount) external onlyGov {
        IERC20(_token).safeTransfer(_account, _amount);
    }
}
