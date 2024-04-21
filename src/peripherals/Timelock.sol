// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {ITimelockTarget} from "./interfaces/ITimelockTarget.sol";
import {ITimelock} from "./interfaces/ITimelock.sol";
import {IHandlerTarget} from "./interfaces/IHandlerTarget.sol";
import {IAdmin} from "../access/interfaces/IAdmin.sol";
import {IVault} from "../core/interfaces/IVault.sol";
import {IBrrrManager} from "../core/interfaces/IBrrrManager.sol";
import {IReferralStorage} from "../referrals/interfaces/IReferralStorage.sol";
import {IYieldToken} from "../tokens/interfaces/IYieldToken.sol";
import {IBaseToken} from "../tokens/interfaces/IBaseToken.sol";
import {IMintable} from "../tokens/interfaces/IMintable.sol";
import {IUSDP} from "../tokens/interfaces/IUSDP.sol";
import {IPositionRouter} from "../core/interfaces/IPositionRouter.sol";
import {IPositionManager} from "../core/interfaces/IPositionManager.sol";
import {IERC20} from "../libraries/token/IERC20.sol";

/*
    @dev Governance contract for the following contracts:
    - Vault
    - BrrrManager
    - ReferralStorage
    - USDP
    - Tokens
*/

contract Timelock is ITimelock {
    uint256 public constant PRICE_PRECISION = 10 ** 30;
    uint256 public constant MAX_BUFFER = 5 days;
    uint256 public constant MAX_FUNDING_RATE_FACTOR = 200; // 0.02%
    uint256 public constant MAX_LEVERAGE_VALIDATION = 500000; // 50x

    uint256 public buffer;
    address public admin;

    address public tokenManager;
    address public mintReceiver;
    address public brrrManager;
    uint256 public maxTokenSupply;

    uint256 public override marginFeeBasisPoints;
    uint256 public maxMarginFeeBasisPoints;
    bool public shouldToggleIsLeverageEnabled;

    mapping(bytes32 => uint256) public pendingActions;

    mapping(address => bool) public isHandler;
    mapping(address => bool) public isKeeper;

    event SignalPendingAction(bytes32 action);
    event SignalApprove(address token, address spender, uint256 amount, bytes32 action);
    event SignalWithdrawToken(address target, address token, address receiver, uint256 amount, bytes32 action);
    event SignalMint(address token, address receiver, uint256 amount, bytes32 action);
    event SignalSetGov(address target, address gov, bytes32 action);
    event SignalSetHandler(address target, address handler, bool isActive, bytes32 action);
    event SignalSetPriceFeed(address vault, address priceFeed, bytes32 action);
    event SignalRedeemUsdp(address vault, address token, uint256 amount);
    event SignalVaultSetTokenConfig(
        address vault,
        address token,
        uint256 tokenDecimals,
        uint256 tokenWeight,
        uint256 minProfitBps,
        uint256 maxUsdpAmount,
        bool isStable,
        bool isShortable
    );
    event SignalClearSetTokenConfig(address vault, address token, bytes32 action);
    event ClearAction(bytes32 action);

    modifier onlyAdmin() {
        require(msg.sender == admin, "Timelock: forbidden");
        _;
    }

    modifier onlyHandlerAndAbove() {
        require(msg.sender == admin || isHandler[msg.sender], "Timelock: forbidden");
        _;
    }

    modifier onlyKeeperAndAbove() {
        require(msg.sender == admin || isHandler[msg.sender] || isKeeper[msg.sender], "Timelock: forbidden");
        _;
    }

    modifier onlyTokenManager() {
        require(msg.sender == tokenManager, "Timelock: forbidden");
        _;
    }

    constructor(
        address _admin,
        uint256 _buffer,
        address _tokenManager,
        address _mintReceiver,
        address _brrrManager,
        uint256 _maxTokenSupply,
        uint256 _marginFeeBasisPoints,
        uint256 _maxMarginFeeBasisPoints
    ) {
        require(_buffer <= MAX_BUFFER, "Timelock: invalid _buffer");
        admin = _admin;
        buffer = _buffer;
        tokenManager = _tokenManager;
        mintReceiver = _mintReceiver;
        brrrManager = _brrrManager;
        maxTokenSupply = _maxTokenSupply;

        marginFeeBasisPoints = _marginFeeBasisPoints;
        maxMarginFeeBasisPoints = _maxMarginFeeBasisPoints;
    }

    function setAdmin(address _admin) external override onlyTokenManager {
        admin = _admin;
    }

    function setExternalAdmin(address _target, address _admin) external onlyAdmin {
        require(_target != address(this), "Timelock: invalid _target");
        IAdmin(_target).setAdmin(_admin);
    }

    function setTokenManager(address _tokenManager) external onlyTokenManager {
        tokenManager = _tokenManager;
    }

    function setContractHandler(address _handler, bool _isActive) external onlyAdmin {
        isHandler[_handler] = _isActive;
    }

    function initBrrrManager() external onlyAdmin {
        IBrrrManager _brrrManager = IBrrrManager(brrrManager);

        IMintable brrr = IMintable(_brrrManager.brrr());
        brrr.setMinter(brrrManager, true);

        IUSDP usdp = IUSDP(_brrrManager.brrr());
        usdp.addVault(brrrManager);

        IVault vault = _brrrManager.vault();
        vault.setBrrrManager(brrrManager);
    }

    function setKeeper(address _keeper, bool _isActive) external onlyAdmin {
        isKeeper[_keeper] = _isActive;
    }

    function setBuffer(uint256 _buffer) external onlyAdmin {
        require(_buffer <= MAX_BUFFER, "Timelock: invalid _buffer");
        require(_buffer > buffer, "Timelock: buffer cannot be decreased");
        buffer = _buffer;
    }

    function setMaxLeverage(address _vault, uint256 _maxLeverage) external onlyAdmin {
        require(_maxLeverage > MAX_LEVERAGE_VALIDATION, "Timelock: invalid _maxLeverage");
        IVault(_vault).setMaxLeverage(_maxLeverage);
    }

    function setFundingRate(address _vault, uint256 _fundingInterval, uint256 _fundingRateFactor)
        external
        onlyKeeperAndAbove
    {
        require(_fundingRateFactor < MAX_FUNDING_RATE_FACTOR, "Timelock: invalid _fundingRateFactor");
        IVault(_vault).setFundingRate(_fundingInterval, _fundingRateFactor);
    }

    function setShouldToggleIsLeverageEnabled(bool _shouldToggleIsLeverageEnabled) external onlyHandlerAndAbove {
        shouldToggleIsLeverageEnabled = _shouldToggleIsLeverageEnabled;
    }

    function setMarginFeeBasisPoints(uint256 _marginFeeBasisPoints, uint256 _maxMarginFeeBasisPoints)
        external
        onlyHandlerAndAbove
    {
        marginFeeBasisPoints = _marginFeeBasisPoints;
        maxMarginFeeBasisPoints = _maxMarginFeeBasisPoints;
    }

    function setSwapFees(address _vault, uint256 _taxBasisPoints, uint256 _mintBurnFeeBasisPoints)
        external
        onlyKeeperAndAbove
    {
        IVault vault = IVault(_vault);

        vault.setFees(
            _taxBasisPoints,
            _mintBurnFeeBasisPoints,
            maxMarginFeeBasisPoints,
            vault.liquidationFeeUsd(),
            vault.minProfitTime()
        );
    }

    // assign _marginFeeBasisPoints to this.marginFeeBasisPoints
    // because enableLeverage would update Vault.marginFeeBasisPoints to this.marginFeeBasisPoints
    // and disableLeverage would reset the Vault.marginFeeBasisPoints to this.maxMarginFeeBasisPoints
    function setFees(
        address _vault,
        uint256 _taxBasisPoints,
        uint256 _mintBurnFeeBasisPoints,
        uint256 _marginFeeBasisPoints,
        uint256 _liquidationFeeUsd,
        uint256 _minProfitTime
    ) external onlyKeeperAndAbove {
        marginFeeBasisPoints = _marginFeeBasisPoints;

        IVault(_vault).setFees(
            _taxBasisPoints, _mintBurnFeeBasisPoints, maxMarginFeeBasisPoints, _liquidationFeeUsd, _minProfitTime
        );
    }

    function enableLeverage(address _vault) external override onlyHandlerAndAbove {
        IVault vault = IVault(_vault);

        if (shouldToggleIsLeverageEnabled) {
            vault.setIsLeverageEnabled(true);
        }

        vault.setFees(
            vault.taxBasisPoints(),
            vault.mintBurnFeeBasisPoints(),
            marginFeeBasisPoints,
            vault.liquidationFeeUsd(),
            vault.minProfitTime()
        );
    }

    function disableLeverage(address _vault) external override onlyHandlerAndAbove {
        IVault vault = IVault(_vault);

        if (shouldToggleIsLeverageEnabled) {
            vault.setIsLeverageEnabled(false);
        }

        vault.setFees(
            vault.taxBasisPoints(),
            vault.mintBurnFeeBasisPoints(),
            maxMarginFeeBasisPoints, // marginFeeBasisPoints
            vault.liquidationFeeUsd(),
            vault.minProfitTime()
        );
    }

    function setIsLeverageEnabled(address _vault, bool _isLeverageEnabled) external override onlyHandlerAndAbove {
        IVault(_vault).setIsLeverageEnabled(_isLeverageEnabled);
    }

    function setTokenConfig(address _vault, address _token, uint256 _minProfitBps) external onlyKeeperAndAbove {
        require(_minProfitBps <= 500, "Timelock: invalid _minProfitBps");

        IVault vault = IVault(_vault);
        require(vault.whitelistedTokens(_token), "Timelock: token not yet whitelisted");

        uint256 tokenDecimals = vault.tokenDecimals(_token);
        bool isStable = vault.stableTokens(_token);
        bool isShortable = vault.shortableTokens(_token);

        IVault(_vault).setTokenConfig(_token, tokenDecimals, _minProfitBps, isStable, isShortable);
    }

    function setMaxUsdpAmounts(address _vault, uint256 _maxUsdpAmounts) external onlyKeeperAndAbove {
        IVault(_vault).setMaxUsdpAmounts(_maxUsdpAmounts);
    }

    function setUsdpAmount(address _vault, uint256 _usdpAmount) external onlyKeeperAndAbove {
        IVault(_vault).setUsdpAmount(_usdpAmount);
    }

    function setShortsTrackerAveragePriceWeight(uint256 _shortsTrackerAveragePriceWeight) external onlyAdmin {
        IBrrrManager(brrrManager).setShortsTrackerAveragePriceWeight(_shortsTrackerAveragePriceWeight);
    }

    function setBrrrCooldownDuration(uint256 _cooldownDuration) external onlyAdmin {
        require(_cooldownDuration < 2 hours, "Timelock: invalid _cooldownDuration");
        IBrrrManager(brrrManager).setCooldownDuration(_cooldownDuration);
    }

    function setMaxGlobalSize(address _vault, address _token, uint256 _longAmount, uint256 _shortAmount)
        external
        onlyAdmin
    {
        IVault(_vault).setMaxGlobalSize(_token, _longAmount, _shortAmount);
    }

    function removeAdmin(address _token, address _account) external onlyAdmin {
        IYieldToken(_token).removeAdmin(_account);
    }

    function setTier(address _referralStorage, uint256 _tierId, uint256 _totalRebate, uint256 _discountShare)
        external
        onlyKeeperAndAbove
    {
        IReferralStorage(_referralStorage).setTier(_tierId, _totalRebate, _discountShare);
    }

    function govSetKeeper(address _positionRouter, address _positionManager, address _keeper, bool _isActive)
        external
        onlyAdmin
    {
        IPositionRouter(_positionRouter).setPositionKeeper(_keeper, _isActive);
        IPositionManager(_positionManager).setOrderKeeper(_keeper, _isActive);
        IPositionManager(_positionManager).setLiquidator(_keeper, _isActive);
    }

    function setReferrerTier(address _referralStorage, address _referrer, uint256 _tierId)
        external
        onlyKeeperAndAbove
    {
        IReferralStorage(_referralStorage).setReferrerTier(_referrer, _tierId);
    }

    function govSetCodeOwner(address _referralStorage, bytes32 _code, address _newAccount)
        external
        onlyKeeperAndAbove
    {
        IReferralStorage(_referralStorage).govSetCodeOwner(_code, _newAccount);
    }

    function setMaxGasPrice(address _vault, uint256 _maxGasPrice) external onlyAdmin {
        require(_maxGasPrice > 5000000000, "Invalid _maxGasPrice");
        IVault(_vault).setMaxGasPrice(_maxGasPrice);
    }

    function withdrawFees(address _vault, address _receiver) external onlyAdmin {
        IVault(_vault).withdrawFees(_receiver);
    }

    function batchWithdrawFees(address _vault, address _receiver) external onlyKeeperAndAbove returns (uint256 fee) {
        fee = IVault(_vault).withdrawFees(_receiver);
    }

    function setLiquidator(address _vault, address _liquidator, bool _isActive) external onlyAdmin {
        IVault(_vault).setLiquidator(_liquidator, _isActive);
    }

    function setInPrivateTransferMode(address _token, bool _inPrivateTransferMode) external onlyAdmin {
        IBaseToken(_token).setInPrivateTransferMode(_inPrivateTransferMode);
    }

    function transferIn(address _sender, address _token, uint256 _amount) external onlyAdmin {
        IERC20(_token).transferFrom(_sender, address(this), _amount);
    }

    function signalApprove(address _token, address _spender, uint256 _amount) external onlyAdmin {
        bytes32 action = keccak256(abi.encodePacked("approve", _token, _spender, _amount));
        _setPendingAction(action);
        emit SignalApprove(_token, _spender, _amount, action);
    }

    function approve(address _token, address _spender, uint256 _amount) external onlyAdmin {
        bytes32 action = keccak256(abi.encodePacked("approve", _token, _spender, _amount));
        _validateAction(action);
        _clearAction(action);
        IERC20(_token).approve(_spender, _amount);
    }

    function signalWithdrawToken(address _target, address _token, address _receiver, uint256 _amount)
        external
        onlyAdmin
    {
        bytes32 action = keccak256(abi.encodePacked("withdrawToken", _target, _token, _receiver, _amount));
        _setPendingAction(action);
        emit SignalWithdrawToken(_target, _token, _receiver, _amount, action);
    }

    function withdrawToken(address _target, address _token, address _receiver, uint256 _amount) external onlyAdmin {
        bytes32 action = keccak256(abi.encodePacked("withdrawToken", _target, _token, _receiver, _amount));
        _validateAction(action);
        _clearAction(action);
        IBaseToken(_target).withdrawToken(_token, _receiver, _amount);
    }

    function signalMint(address _token, address _receiver, uint256 _amount) external onlyAdmin {
        bytes32 action = keccak256(abi.encodePacked("mint", _token, _receiver, _amount));
        _setPendingAction(action);
        emit SignalMint(_token, _receiver, _amount, action);
    }

    function processMint(address _token, address _receiver, uint256 _amount) external onlyAdmin {
        bytes32 action = keccak256(abi.encodePacked("mint", _token, _receiver, _amount));
        _validateAction(action);
        _clearAction(action);

        _mint(_token, _receiver, _amount);
    }

    function signalSetGov(address _target, address _gov) external override onlyAdmin {
        bytes32 action = keccak256(abi.encodePacked("setGov", _target, _gov));
        _setPendingAction(action);
        emit SignalSetGov(_target, _gov, action);
    }

    function setGov(address _target, address _gov) external onlyAdmin {
        bytes32 action = keccak256(abi.encodePacked("setGov", _target, _gov));
        _validateAction(action);
        _clearAction(action);
        ITimelockTarget(_target).setGov(_gov);
    }

    function signalSetHandler(address _target, address _handler, bool _isActive) external onlyAdmin {
        bytes32 action = keccak256(abi.encodePacked("setHandler", _target, _handler, _isActive));
        _setPendingAction(action);
        emit SignalSetHandler(_target, _handler, _isActive, action);
    }

    function setHandler(address _target, address _handler, bool _isActive) external onlyAdmin {
        bytes32 action = keccak256(abi.encodePacked("setHandler", _target, _handler, _isActive));
        _validateAction(action);
        _clearAction(action);
        IHandlerTarget(_target).setHandler(_handler, _isActive);
    }

    function signalSetPriceFeed(address _vault, address _priceFeed) external onlyAdmin {
        bytes32 action = keccak256(abi.encodePacked("setPriceFeed", _vault, _priceFeed));
        _setPendingAction(action);
        emit SignalSetPriceFeed(_vault, _priceFeed, action);
    }

    function setPriceFeed(address _vault, address _priceFeed) external onlyAdmin {
        bytes32 action = keccak256(abi.encodePacked("setPriceFeed", _vault, _priceFeed));
        _validateAction(action);
        _clearAction(action);
        IVault(_vault).setPriceFeed(_priceFeed);
    }

    function signalRedeemUsdp(address _vault, address _token, uint256 _amount) external onlyAdmin {
        bytes32 action = keccak256(abi.encodePacked("redeemUsdp", _vault, _token, _amount));
        _setPendingAction(action);
        emit SignalRedeemUsdp(_vault, _token, _amount);
    }

    function signalVaultSetTokenConfig(
        address _vault,
        address _token,
        uint256 _tokenDecimals,
        uint256 _tokenWeight,
        uint256 _minProfitBps,
        uint256 _maxUsdpAmount,
        bool _isStable,
        bool _isShortable
    ) external onlyAdmin {
        bytes32 action = keccak256(
            abi.encodePacked(
                "vaultSetTokenConfig",
                _vault,
                _token,
                _tokenDecimals,
                _tokenWeight,
                _minProfitBps,
                _maxUsdpAmount,
                _isStable,
                _isShortable
            )
        );

        _setPendingAction(action);

        emit SignalVaultSetTokenConfig(
            _vault, _token, _tokenDecimals, _tokenWeight, _minProfitBps, _maxUsdpAmount, _isStable, _isShortable
        );
    }

    function vaultSetTokenConfig(
        address _vault,
        address _token,
        uint256 _tokenDecimals,
        uint256 _minProfitBps,
        bool _isStable,
        bool _isShortable
    ) external onlyAdmin {
        bytes32 action = keccak256(
            abi.encodePacked(
                "vaultSetTokenConfig", _vault, _token, _tokenDecimals, _minProfitBps, _isStable, _isShortable
            )
        );

        _validateAction(action);
        _clearAction(action);

        IVault(_vault).setTokenConfig(_token, _tokenDecimals, _minProfitBps, _isStable, _isShortable);
    }

    function signalVaultClearTokenConfig(address _vault, address _token) external onlyAdmin {
        bytes32 action = keccak256(abi.encodePacked("vaultClearTokenConfig", _vault, _token));

        _setPendingAction(action);

        emit SignalClearSetTokenConfig(_vault, _token, action);
    }

    function vaultClearTokenConfig(address _vault, address _token) external onlyAdmin {
        bytes32 action = keccak256(abi.encodePacked("vaultClearTokenConfig", _vault, _token));

        _validateAction(action);
        _clearAction(action);

        IVault(_vault).clearTokenConfig(_token);
    }

    function cancelAction(bytes32 _action) external onlyAdmin {
        _clearAction(_action);
    }

    function _mint(address _token, address _receiver, uint256 _amount) private {
        IMintable mintable = IMintable(_token);

        mintable.setMinter(address(this), true);

        mintable.mint(_receiver, _amount);
        require(IERC20(_token).totalSupply() <= maxTokenSupply, "Timelock: maxTokenSupply exceeded");

        mintable.setMinter(address(this), false);
    }

    function _setPendingAction(bytes32 _action) private {
        require(pendingActions[_action] == 0, "Timelock: action already signalled");
        pendingActions[_action] = block.timestamp + buffer;
        emit SignalPendingAction(_action);
    }

    function _validateAction(bytes32 _action) private view {
        require(pendingActions[_action] != 0, "Timelock: action not signalled");
        require(pendingActions[_action] < block.timestamp, "Timelock: action time not yet passed");
    }

    function _clearAction(bytes32 _action) private {
        require(pendingActions[_action] != 0, "Timelock: invalid _action");
        delete pendingActions[_action];
        emit ClearAction(_action);
    }
}
