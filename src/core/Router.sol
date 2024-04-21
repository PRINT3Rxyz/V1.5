// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../libraries/token/IERC20.sol";
import "../libraries/token/SafeERC20.sol";
import "../access/Governable.sol";

import "./interfaces/IVault.sol";
import "./interfaces/IRouter.sol";

contract Router is Governable, IRouter {
    using SafeERC20 for IERC20;

    address public collateralToken;
    address public vault;

    mapping(address => bool) public plugins;
    mapping(address => mapping(address => bool)) public approvedPlugins;

    constructor(address _vault, address _collateralToken) {
        vault = _vault;
        collateralToken = _collateralToken;
    }

    function addPlugin(address _plugin) external override onlyGov {
        plugins[_plugin] = true;
    }

    function removePlugin(address _plugin) external onlyGov {
        plugins[_plugin] = false;
    }

    function approvePlugin(address _plugin) external {
        approvedPlugins[msg.sender][_plugin] = true;
    }

    function denyPlugin(address _plugin) external {
        approvedPlugins[msg.sender][_plugin] = false;
    }

    function pluginTransfer(address _token, address _account, address _receiver, uint256 _amount) external override {
        _validatePlugin(_account);
        IERC20(_token).safeTransferFrom(_account, _receiver, _amount);
    }

    function pluginIncreasePosition(address _account, address _indexToken, uint256 _sizeDelta, bool _isLong)
        external
        override
    {
        _validatePlugin(_account);
        IVault(vault).increasePosition(_account, _indexToken, _sizeDelta, _isLong);
    }

    function pluginDecreasePosition(
        address _account,
        address _indexToken,
        uint256 _collateralDelta,
        uint256 _sizeDelta,
        bool _isLong,
        address _receiver
    ) external override returns (uint256) {
        _validatePlugin(_account);
        return IVault(vault).decreasePosition(_account, _indexToken, _collateralDelta, _sizeDelta, _isLong, _receiver);
    }

    function directPoolDeposit(uint256 _amount) external {
        IERC20(collateralToken).safeTransferFrom(msg.sender, vault, _amount);
        IVault(vault).directPoolDeposit();
    }

    function _validatePlugin(address _account) private view {
        require(plugins[msg.sender], "Router: invalid plugin");
        require(approvedPlugins[_account][msg.sender], "Router: plugin not approved");
    }
}
