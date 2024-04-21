// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../libraries/token/IERC20.sol";
import "../libraries/token/SafeERC20.sol";
import "../libraries/utils/ReentrancyGuard.sol";

import "./interfaces/IVaultPyth.sol";
import "./interfaces/IVaultPriceFeed.sol";
import "./interfaces/IVaultAfterHook.sol";

contract Vault is ReentrancyGuard, IVaultPyth {
    using SafeERC20 for IERC20;

    uint256 public constant BASIS_POINTS_DIVISOR = 10000;
    uint256 public constant FUNDING_RATE_PRECISION = 1000000;
    uint256 public constant PRICE_PRECISION = 10 ** 30;
    uint256 public constant MIN_LEVERAGE = 10000; // 1x
    uint256 public constant USDP_DECIMALS = 18;
    uint256 public constant MAX_FEE_BASIS_POINTS = 500; // 5%
    uint256 public constant MAX_LIQUIDATION_FEE_USD = 100 * PRICE_PRECISION; // 100 USD
    uint256 public constant MIN_FUNDING_RATE_INTERVAL = 1 hours;
    uint256 public constant MAX_FUNDING_RATE_FACTOR = 10000; // 1%

    bool public override isInitialized;
    bool public override isLeverageEnabled;

    address public override gov;

    address public override router;
    address public override priceFeed;

    address public override collateralToken;
    uint256 public override whitelistedTokenCount;

    uint256 public override maxLeverage;

    uint256 public override liquidationFeeUsd;
    uint256 public override taxBasisPoints;
    uint256 public override mintBurnFeeBasisPoints;
    uint256 public override marginFeeBasisPoints;

    uint256 public override minProfitTime;

    uint256 public override fundingInterval;
    uint256 public override fundingRateFactor;

    bool public useSwapPricing;

    uint256 public override maxGasPrice;

    mapping(address => mapping(address => bool)) public override approvedRouters;
    mapping(address => bool) public override isLiquidator;
    address public override brrrManager;

    address[] public override allWhitelistedTokens;

    mapping(address => bool) public override whitelistedTokens;
    mapping(address => uint256) public override tokenDecimals;
    mapping(address => uint256) public override minProfitBasisPoints;
    mapping(address => bool) public override stableTokens;
    mapping(address => bool) public override shortableTokens;

    // tokenBalances is used only to determine _transferIn values
    mapping(address token => uint256 balance) public override tokenBalances;

    // usdpAmount tracks the amount of USDP debt for collateral token
    uint256 public override usdpAmount;

    // maxUsdpAmount allows setting a max amount of USDP debt
    uint256 public override maxUsdpAmount;

    // poolAmount tracks the number of collateral token that can be used for leverage
    // this is tracked separately from tokenBalances to exclude funds that are deposited as margin collateral
    uint256 public override poolAmount;

    // reservedAmounts tracks the number of tokens reserved for open leverage positions
    mapping(address token => mapping(bool isLong => uint256 reserved)) public override reservedAmounts;

    // total reserved amount for open leverage positions
    uint256 public override totalReservedAmount;

    // cumulativeFundingRates tracks the funding rates based on utilization
    mapping(address token => mapping(bool isLong => uint256 cumulativeFundingRate)) public override
        cumulativeFundingRates;
    // lastFundingTimes tracks the last time funding was updated for a token
    mapping(address token => mapping(bool isLong => uint256 lastFundingTime)) public override lastFundingTimes;

    // positions tracks all open positions
    mapping(bytes32 key => Position) public positions;

    // feeReserve tracks the amount of trading fee
    uint256 public override feeReserve;

    mapping(address token => uint256) public override globalShortSizes;
    mapping(address token => uint256) public override globalShortAveragePrices;
    mapping(address token => uint256) public override maxGlobalShortSizes;

    mapping(address token => uint256) public override globalLongSizes;
    mapping(address token => uint256) public override globalLongAveragePrices;
    mapping(address token => uint256) public override maxGlobalLongSizes;

    mapping(uint256 id => string error) public errors;

    address public afterHook;
    mapping(address token => uint256 maxLeverage) public maxLeverages;

    // once the parameters are verified to be working correctly,
    // gov should be set to a timelock contract or a governance contract
    constructor() {
        gov = msg.sender;
    }

    function initialize(
        address _router,
        address _priceFeed,
        address _collateralToken,
        uint256 _liquidationFeeUsd,
        uint256 _fundingRateFactor
    ) external {
        _onlyGov();
        if (isInitialized) revert Vault_AlreadyInitialized();
        if (_liquidationFeeUsd > MAX_LIQUIDATION_FEE_USD) revert Vault_LiquidationFee();
        if (_fundingRateFactor > MAX_FUNDING_RATE_FACTOR) revert Vault_FundingRateFactor();
        isInitialized = true;

        router = _router;
        priceFeed = _priceFeed;

        isLeverageEnabled = true;
        maxLeverage = 50 * 10000; // 50x
        taxBasisPoints = 50; // 0.5%
        mintBurnFeeBasisPoints = 30; // 0.3%
        marginFeeBasisPoints = 10; // 0.1%
        fundingInterval = 1 hours;

        collateralToken = _collateralToken;
        liquidationFeeUsd = _liquidationFeeUsd;
        fundingRateFactor = _fundingRateFactor;
    }

    function allWhitelistedTokensLength() external view override returns (uint256) {
        return allWhitelistedTokens.length;
    }

    function setBrrrManager(address _manager) external override {
        _onlyGov();
        brrrManager = _manager;
    }

    function setLiquidator(address _liquidator, bool _isActive) external override {
        _onlyGov();
        isLiquidator[_liquidator] = _isActive;
    }

    function setIsLeverageEnabled(bool _isLeverageEnabled) external override {
        _onlyGov();
        isLeverageEnabled = _isLeverageEnabled;
    }

    function setMaxGasPrice(uint256 _maxGasPrice) external override {
        _onlyGov();
        maxGasPrice = _maxGasPrice;
    }

    function setPriceFeed(address _priceFeed) external override {
        _onlyGov();
        priceFeed = _priceFeed;
    }

    function setMaxLeverage(uint256 _maxLeverage) external override {
        _onlyGov();
        if (maxLeverage <= MIN_LEVERAGE) revert Vault_MaxLeverage();
        maxLeverage = _maxLeverage;
    }

    function setMaxLeverages(address _token, uint256 _maxLeverage) external {
        _onlyGov();
        if (_maxLeverage <= MIN_LEVERAGE && _maxLeverage != 0) revert Vault_MaxLeverage();
        if (!whitelistedTokens[_token]) revert Vault_TokenNotWhitelisted();
        maxLeverages[_token] = _maxLeverage;
    }

    function setMaxGlobalSize(address _token, uint256 _longAmount, uint256 _shortAmount) external override {
        _onlyGov();
        maxGlobalLongSizes[_token] = _longAmount;
        maxGlobalShortSizes[_token] = _shortAmount;
    }

    function setFees(
        uint256 _taxBasisPoints,
        uint256 _mintBurnFeeBasisPoints,
        uint256 _marginFeeBasisPoints,
        uint256 _liquidationFeeUsd,
        uint256 _minProfitTime
    ) external override {
        _onlyGov();
        if (_taxBasisPoints > MAX_FEE_BASIS_POINTS) revert Vault_TaxBasisPoints();
        if (_mintBurnFeeBasisPoints > MAX_FEE_BASIS_POINTS) revert Vault_MintBurnFeeBasisPoints();
        if (_marginFeeBasisPoints > MAX_FEE_BASIS_POINTS) revert Vault_MarginFeeBasisPoints();
        if (_liquidationFeeUsd > MAX_LIQUIDATION_FEE_USD) revert Vault_LiquidationFee();
        taxBasisPoints = _taxBasisPoints;
        mintBurnFeeBasisPoints = _mintBurnFeeBasisPoints;
        marginFeeBasisPoints = _marginFeeBasisPoints;
        liquidationFeeUsd = _liquidationFeeUsd;
        minProfitTime = _minProfitTime;
    }

    function setFundingRate(uint256 _fundingInterval, uint256 _fundingRateFactor) external override {
        _onlyGov();
        if (_fundingInterval < MIN_FUNDING_RATE_INTERVAL) revert Vault_FundingInterval();
        if (_fundingRateFactor > MAX_FUNDING_RATE_FACTOR) revert Vault_FundingRateFactor();
        fundingInterval = _fundingInterval;
        fundingRateFactor = _fundingRateFactor;
    }

    function setMaxUsdpAmounts(uint256 _maxUsdpAmounts) external override {
        _onlyGov();
        maxUsdpAmount = _maxUsdpAmounts;
    }

    function setTokenConfig(
        address _token,
        uint256 _tokenDecimals,
        uint256 _minProfitBps,
        bool _isStable,
        bool _isShortable
    ) external override {
        _onlyGov();
        // increment token count for the first time
        if (!whitelistedTokens[_token]) {
            whitelistedTokenCount += 1;
            allWhitelistedTokens.push(_token);
        }

        whitelistedTokens[_token] = true;
        tokenDecimals[_token] = _tokenDecimals;
        minProfitBasisPoints[_token] = _minProfitBps;
        stableTokens[_token] = _isStable;
        shortableTokens[_token] = _isShortable;

        // validate price feed
        getMaxPrice(_token);
    }

    function clearTokenConfig(address _token) external {
        _onlyGov();
        require(_token != collateralToken, "Vault: Cannot clear collateralToken");
        if (!whitelistedTokens[_token]) revert Vault_TokenNotWhitelisted();
        delete whitelistedTokens[_token];
        delete tokenDecimals[_token];
        delete minProfitBasisPoints[_token];
        delete stableTokens[_token];
        delete shortableTokens[_token];
        whitelistedTokenCount -= 1;
    }

    function withdrawFees(address _receiver) external override returns (uint256) {
        _onlyGov();
        uint256 amount = feeReserve;
        if (amount == 0) {
            return 0;
        }
        feeReserve = 0;
        _transferOut(amount, _receiver);
        return amount;
    }

    function addRouter(address _router) external {
        approvedRouters[msg.sender][_router] = true;
    }

    function removeRouter(address _router) external {
        approvedRouters[msg.sender][_router] = false;
    }

    function setUsdpAmount(uint256 _amount) external override {
        _onlyGov();
        uint256 _usdpAmount = usdpAmount;
        if (_amount > _usdpAmount) {
            _increaseUsdpAmount(_amount - _usdpAmount);
            return;
        }

        _decreaseUsdpAmount(_usdpAmount - _amount);
    }

    // deposit into the pool without minting USDP tokens
    // useful in allowing the pool to become over-collaterised
    function directPoolDeposit() external override nonReentrant {
        uint256 tokenAmount = _transferIn(collateralToken);
        if (tokenAmount == 0) revert Vault_ZeroAmount();
        _increasePoolAmount(tokenAmount);
        emit DirectPoolDeposit(tokenAmount);
    }

    function estimateUSDPOut(uint256 _amount) external view override returns (uint256) {
        if (_amount == 0) revert Vault_ZeroAmount();

        uint256 price = getMinPrice(collateralToken);

        uint256 feeBasisPoints = mintBurnFeeBasisPoints;

        uint256 afterFeeAmount = (_amount * (BASIS_POINTS_DIVISOR - feeBasisPoints)) / BASIS_POINTS_DIVISOR;

        uint256 mintAmount = (afterFeeAmount * price) / PRICE_PRECISION;
        mintAmount = _adjustForRawDecimals(mintAmount, tokenDecimals[collateralToken], USDP_DECIMALS);

        return mintAmount;
    }

    function estimateTokenIn(uint256 _usdpAmount) external view override returns (uint256) {
        if (_usdpAmount == 0) revert Vault_ZeroAmount();

        uint256 price = getMinPrice(collateralToken);

        _usdpAmount = _adjustForRawDecimals(_usdpAmount, USDP_DECIMALS, tokenDecimals[collateralToken]);

        uint256 amountAfterFees = (_usdpAmount * PRICE_PRECISION) / price;
        uint256 feeBasisPoints = mintBurnFeeBasisPoints;

        return (amountAfterFees * BASIS_POINTS_DIVISOR) / (BASIS_POINTS_DIVISOR - feeBasisPoints);
    }

    function addLiquidity() external override nonReentrant returns (uint256) {
        _validateBrrrManager();

        address _collateralToken = collateralToken;
        useSwapPricing = true;

        uint256 tokenAmount = _transferIn(_collateralToken);
        if (tokenAmount == 0) revert Vault_ZeroAmount();

        uint256 price = getMinPrice(_collateralToken);

        uint256 feeBasisPoints = mintBurnFeeBasisPoints;

        uint256 amountAfterFees = (tokenAmount * (BASIS_POINTS_DIVISOR - feeBasisPoints)) / BASIS_POINTS_DIVISOR;

        uint256 mintAmount = (amountAfterFees * price) / PRICE_PRECISION;

        mintAmount = _adjustForRawDecimals(mintAmount, tokenDecimals[_collateralToken], USDP_DECIMALS);
        if (mintAmount == 0) revert Vault_ZeroAmount();

        _increaseUsdpAmount(mintAmount);
        _increasePoolAmount(tokenAmount);

        emit LiquidityAdded(tokenAmount, mintAmount, feeBasisPoints);

        useSwapPricing = false;
        return mintAmount;
    }

    function removeLiquidity(address _receiver, uint256 _usdpAmount) external override nonReentrant returns (uint256) {
        _validateBrrrManager();
        useSwapPricing = true;

        if (_usdpAmount == 0) revert Vault_ZeroAmount();

        uint256 redemptionAmount = getRedemptionAmount(_usdpAmount);

        if (redemptionAmount == 0) revert Vault_ZeroAmount();

        uint256 feeBasisPoints = mintBurnFeeBasisPoints;

        uint256 amountOut = (redemptionAmount * (BASIS_POINTS_DIVISOR - feeBasisPoints)) / BASIS_POINTS_DIVISOR;

        _decreaseUsdpAmount(_usdpAmount);
        _decreasePoolAmount(amountOut);

        if (amountOut == 0) revert Vault_ZeroAmount();

        _transferOut(amountOut, _receiver);

        emit LiquidityRemoved(_usdpAmount, amountOut, feeBasisPoints);

        useSwapPricing = false;
        return amountOut;
    }

    function increasePosition(address _account, address _indexToken, uint256 _sizeDelta, bool _isLong)
        external
        override
        nonReentrant
    {
        if (!isLeverageEnabled) revert Vault_LeverageDisabled();
        _validateGasPrice();
        _validateRouter(_account);
        _validateTokens(_indexToken, _isLong);
        address _collateralToken = collateralToken;

        updateCumulativeFundingRate(_indexToken, _isLong);

        bytes32 key = getPositionKey(_account, _indexToken, _isLong);
        Position storage position = positions[key];

        uint256 price = _isLong ? getMaxPrice(_indexToken) : getMinPrice(_indexToken);

        if (position.size == 0) {
            position.averagePrice = price;
        }

        if (position.size > 0 && _sizeDelta > 0) {
            position.averagePrice = getNextAveragePrice(
                _indexToken,
                position.size,
                position.averagePrice,
                _isLong,
                price,
                _sizeDelta,
                position.lastIncreasedTime
            );
        }

        uint256 fee =
            _collectMarginFees(_account, _indexToken, _isLong, _sizeDelta, position.size, position.entryFundingRate);
        uint256 collateralDelta = _transferIn(_collateralToken);
        uint256 collateralDeltaUsd = tokenToUsdMin(_collateralToken, collateralDelta);

        position.collateral = position.collateral + collateralDeltaUsd;

        if (position.collateral < fee) revert Vault_InsufficientCollateral();

        position.collateral -= fee;
        position.entryFundingRate = getEntryFundingRate(_indexToken, _isLong);
        position.size += _sizeDelta;
        position.lastIncreasedTime = block.timestamp;

        if (position.size == 0) revert Vault_ZeroSize();
        _validatePosition(position.size, position.collateral);
        validateLiquidation(_account, _indexToken, _isLong, true);

        // reserve token to pay profits on the position
        uint256 reserveDelta = usdToCollateralTokenMax(_sizeDelta);
        position.reserveAmount += reserveDelta;
        _increaseReservedAmount(_indexToken, _isLong, reserveDelta);

        if (_isLong) {
            if (globalLongSizes[_indexToken] == 0) {
                globalLongAveragePrices[_indexToken] = price;
            } else {
                globalLongAveragePrices[_indexToken] = getNextGlobalLongAveragePrice(_indexToken, price, _sizeDelta);
            }

            _increaseGlobalLongSize(_indexToken, _sizeDelta);
        } else {
            if (globalShortSizes[_indexToken] == 0) {
                globalShortAveragePrices[_indexToken] = price;
            } else {
                globalShortAveragePrices[_indexToken] = getNextGlobalShortAveragePrice(_indexToken, price, _sizeDelta);
            }

            _increaseGlobalShortSize(_indexToken, _sizeDelta);
        }

        _handleAfterTrade(_account, _sizeDelta);

        emit IncreasePosition(key, _account, _indexToken, collateralDeltaUsd, _sizeDelta, _isLong, price, fee);
        emit UpdatePosition(
            key,
            position.size,
            position.collateral,
            position.averagePrice,
            position.entryFundingRate,
            position.reserveAmount,
            position.realisedPnl,
            price
        );
    }

    function decreasePosition(
        address _account,
        address _indexToken,
        uint256 _collateralDelta,
        uint256 _sizeDelta,
        bool _isLong,
        address _receiver
    ) external override nonReentrant returns (uint256) {
        _validateGasPrice();
        _validateRouter(_account);
        return _decreasePosition(_account, _indexToken, _collateralDelta, _sizeDelta, _isLong, _receiver);
    }

    function _decreasePosition(
        address _account,
        address _indexToken,
        uint256 _collateralDelta,
        uint256 _sizeDelta,
        bool _isLong,
        address _receiver
    ) private returns (uint256) {
        _validateAddr(_receiver);
        updateCumulativeFundingRate(_indexToken, _isLong);

        bytes32 key = getPositionKey(_account, _indexToken, _isLong);
        Position storage position = positions[key];
        if (position.size == 0) revert Vault_ZeroSize();
        if (position.size < _sizeDelta) revert Vault_InsufficientSize();
        if (position.collateral < _collateralDelta) revert Vault_InsufficientCollateral();

        // scrop variables to avoid stack too deep errors
        {
            uint256 reserveDelta = (position.reserveAmount * _sizeDelta) / position.size;
            position.reserveAmount -= reserveDelta;
            _decreaseReservedAmount(_indexToken, _isLong, reserveDelta);
        }

        (uint256 usdOut, uint256 usdOutAfterFee) =
            _reduceCollateral(_account, _indexToken, _collateralDelta, _sizeDelta, _isLong);

        if (position.size != _sizeDelta) {
            position.entryFundingRate = getEntryFundingRate(_indexToken, _isLong);
            position.size -= _sizeDelta;

            _validatePosition(position.size, position.collateral);
            validateLiquidation(_account, _indexToken, _isLong, true);

            uint256 price = _isLong ? getMinPrice(_indexToken) : getMaxPrice(_indexToken);
            emit DecreasePosition(
                key, _account, _indexToken, _collateralDelta, _sizeDelta, _isLong, price, usdOut - usdOutAfterFee
            );
            emit UpdatePosition(
                key,
                position.size,
                position.collateral,
                position.averagePrice,
                position.entryFundingRate,
                position.reserveAmount,
                position.realisedPnl,
                price
            );
        } else {
            uint256 price = _isLong ? getMinPrice(_indexToken) : getMaxPrice(_indexToken);
            emit DecreasePosition(
                key, _account, _indexToken, _collateralDelta, _sizeDelta, _isLong, price, usdOut - usdOutAfterFee
            );
            emit ClosePosition(
                key,
                position.size,
                position.collateral,
                position.averagePrice,
                position.entryFundingRate,
                position.reserveAmount,
                position.realisedPnl
            );

            delete positions[key];
        }

        if (!_isLong) {
            _decreaseGlobalShortSize(_indexToken, _sizeDelta);
        } else {
            _decreaseGlobalLongSize(_indexToken, _sizeDelta);
        }

        _handleAfterTrade(_account, _sizeDelta);

        if (usdOut > 0) {
            uint256 amountOutAfterFees = usdToCollateralTokenMin(usdOutAfterFee);
            _transferOut(amountOutAfterFees, _receiver);
            return amountOutAfterFees;
        }

        return 0;
    }

    function liquidatePosition(address _account, address _indexToken, bool _isLong, address _feeReceiver)
        external
        override
        nonReentrant
    {
        if (!isLiquidator[msg.sender]) revert Vault_NotLiquidator();

        updateCumulativeFundingRate(_indexToken, _isLong);

        bytes32 key = getPositionKey(_account, _indexToken, _isLong);
        Position memory position = positions[key];
        if (position.size == 0) revert Vault_ZeroSize();

        (uint256 liquidationState, uint256 marginFees) = validateLiquidation(_account, _indexToken, _isLong, false);
        if (liquidationState == 0) revert Vault_NotLiquidatable();
        if (liquidationState == 2) {
            // max leverage exceeded but there is collateral remaining after deducting losses so decreasePosition instead
            _decreasePosition(_account, _indexToken, 0, position.size, _isLong, _account);

            return;
        }

        uint256 feeTokens = usdToCollateralTokenMin(marginFees);
        feeReserve += feeTokens;
        emit CollectMarginFees(marginFees, feeTokens);

        _decreaseReservedAmount(_indexToken, _isLong, position.reserveAmount);

        uint256 markPrice = _isLong ? getMinPrice(_indexToken) : getMaxPrice(_indexToken);
        emit LiquidatePosition(
            key,
            _account,
            _indexToken,
            _isLong,
            position.size,
            position.collateral,
            position.reserveAmount,
            position.realisedPnl,
            markPrice
        );

        if (marginFees < position.collateral) {
            uint256 remainingCollateral = position.collateral - marginFees;
            _increasePoolAmount(usdToCollateralTokenMin(remainingCollateral));
        }

        if (!_isLong) {
            _decreaseGlobalShortSize(_indexToken, position.size);
        } else {
            _decreaseGlobalLongSize(_indexToken, position.size);
        }

        delete positions[key];

        // pay the fee receiver using the pool, we assume that in general the liquidated amount should be sufficient to cover
        // the liquidation fees
        _decreasePoolAmount(usdToCollateralTokenMin(liquidationFeeUsd));
        _transferOut(usdToCollateralTokenMin(liquidationFeeUsd), _feeReceiver);
    }

    // validateLiquidation returns (state, fees)
    function validateLiquidation(address _account, address _indexToken, bool _isLong, bool _raise)
        public
        view
        override
        returns (uint256, uint256)
    {
        (uint256 size, uint256 collateral, uint256 averagePrice, uint256 entryFundingRate,,,, uint256 lastIncreasedTime)
        = getPosition(_account, _indexToken, _isLong);

        (bool hasProfit, uint256 delta) = getDelta(_indexToken, size, averagePrice, _isLong, lastIncreasedTime);
        uint256 marginFees = getFundingFee(_account, _indexToken, _isLong, size, entryFundingRate);
        marginFees += getPositionFee(_account, _indexToken, _isLong, size);

        if (!hasProfit && collateral < delta) {
            if (_raise) {
                revert Vault_LossesExceedCollateral();
            }
            return (1, marginFees);
        }

        uint256 remainingCollateral = collateral;
        if (!hasProfit) {
            remainingCollateral = collateral - delta;
        }

        if (remainingCollateral < marginFees) {
            if (_raise) {
                revert Vault_FeesExceedCollateral();
            }
            // cap the fees to the remainingCollateral
            return (1, remainingCollateral);
        }

        if (remainingCollateral < marginFees + liquidationFeeUsd) {
            if (_raise) {
                revert Vault_LiquidationFeesExceedCollateral();
            }
            return (1, marginFees);
        }

        uint256 _maxLeverage = getMaxLeverage(_indexToken);
        if (remainingCollateral * _maxLeverage < size * BASIS_POINTS_DIVISOR) {
            if (_raise) {
                revert Vault_MaxLeverageExceeded();
            }
            return (2, marginFees);
        }

        return (0, marginFees);
    }

    function getMaxPrice(address _token) public view override returns (uint256) {
        return IVaultPriceFeed(priceFeed).getPrice(_token, true, useSwapPricing);
    }

    function getMinPrice(address _token) public view override returns (uint256) {
        return IVaultPriceFeed(priceFeed).getPrice(_token, false, useSwapPricing);
    }

    function getRedemptionAmount(uint256 _usdpAmount) public view override returns (uint256) {
        address _token = collateralToken;
        uint256 price = getMaxPrice(_token);
        uint256 redemptionAmount = (_usdpAmount * PRICE_PRECISION) / price;
        return _adjustForRawDecimals(redemptionAmount, USDP_DECIMALS, tokenDecimals[_token]);
    }

    function adjustForDecimals(uint256 _amount, address _tokenDiv, address _tokenMul) public view returns (uint256) {
        return _adjustForRawDecimals(_amount, tokenDecimals[_tokenDiv], tokenDecimals[_tokenMul]);
    }

    function tokenToUsdMin(address _token, uint256 _tokenAmount) public view override returns (uint256) {
        if (_tokenAmount == 0) {
            return 0;
        }
        uint256 price = getMinPrice(_token);
        uint256 decimals = tokenDecimals[_token];
        return (_tokenAmount * price) / (10 ** decimals);
    }

    function usdToCollateralTokenMax(uint256 _usdAmount) public view returns (uint256) {
        if (_usdAmount == 0) {
            return 0;
        }
        return usdToToken(collateralToken, _usdAmount, getMinPrice(collateralToken));
    }

    function usdToCollateralTokenMin(uint256 _usdAmount) public view returns (uint256) {
        if (_usdAmount == 0) {
            return 0;
        }
        return usdToToken(collateralToken, _usdAmount, getMaxPrice(collateralToken));
    }

    function usdToToken(address _token, uint256 _usdAmount, uint256 _price) public view returns (uint256) {
        if (_usdAmount == 0) {
            return 0;
        }
        uint256 decimals = tokenDecimals[_token];
        return (_usdAmount * (10 ** decimals)) / _price;
    }

    function getPosition(address _account, address _indexToken, bool _isLong)
        public
        view
        override
        returns (uint256, uint256, uint256, uint256, uint256, uint256, bool, uint256)
    {
        bytes32 key = getPositionKey(_account, _indexToken, _isLong);
        Position memory position = positions[key];
        uint256 realisedPnl = position.realisedPnl > 0 ? uint256(position.realisedPnl) : uint256(-position.realisedPnl);
        return (
            position.size, // 0
            position.collateral, // 1
            position.averagePrice, // 2
            position.entryFundingRate, // 3
            position.reserveAmount, // 4
            realisedPnl, // 5
            position.realisedPnl >= 0, // 6
            position.lastIncreasedTime // 7
        );
    }

    function getPositionKey(address _account, address _indexToken, bool _isLong) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(_account, _indexToken, _isLong));
    }

    function updateCumulativeFundingRate(address _indexToken, bool _isLong) public {
        address indexToken = _indexToken;
        bool isLong = _isLong;

        if (lastFundingTimes[indexToken][isLong] == 0) {
            lastFundingTimes[indexToken][isLong] = (block.timestamp / fundingInterval) * fundingInterval;
            return;
        }

        if (lastFundingTimes[indexToken][isLong] + fundingInterval > block.timestamp) {
            return;
        }

        uint256 fundingRate = getNextFundingRate(indexToken, isLong);
        cumulativeFundingRates[indexToken][isLong] += fundingRate;
        lastFundingTimes[indexToken][isLong] = (block.timestamp / fundingInterval) * fundingInterval;

        emit UpdateFundingRate(indexToken, isLong, cumulativeFundingRates[indexToken][isLong]);
    }

    function getNextFundingRate(address _token, bool _isLong) public view override returns (uint256) {
        if (lastFundingTimes[_token][_isLong] + fundingInterval > block.timestamp) {
            return 0;
        }

        uint256 intervals = (block.timestamp - lastFundingTimes[_token][_isLong]) / fundingInterval;
        if (poolAmount == 0) {
            return 0;
        }

        return (fundingRateFactor * reservedAmounts[_token][_isLong] * intervals) / poolAmount;
    }

    function getUtilisation(address _token, bool _isLong) public view returns (uint256) {
        if (poolAmount == 0) {
            return 0;
        }

        return (reservedAmounts[_token][_isLong] * FUNDING_RATE_PRECISION) / poolAmount;
    }

    function getPositionLeverage(address _account, address _indexToken, bool _isLong) public view returns (uint256) {
        bytes32 key = getPositionKey(_account, _indexToken, _isLong);
        Position memory position = positions[key];
        if (position.collateral == 0) revert Vault_ZeroCollateral();
        return (position.size * BASIS_POINTS_DIVISOR) / position.collateral;
    }

    // for longs: nextAveragePrice = (nextPrice * nextSize)/ (nextSize + delta)
    // for shorts: nextAveragePrice = (nextPrice * nextSize) / (nextSize - delta)
    function getNextAveragePrice(
        address _indexToken,
        uint256 _size,
        uint256 _averagePrice,
        bool _isLong,
        uint256 _nextPrice,
        uint256 _sizeDelta,
        uint256 _lastIncreasedTime
    ) public view returns (uint256) {
        (bool hasProfit, uint256 delta) = getDelta(_indexToken, _size, _averagePrice, _isLong, _lastIncreasedTime);
        uint256 nextSize = _size + _sizeDelta;
        uint256 divisor;
        if (_isLong) {
            divisor = hasProfit ? nextSize + delta : nextSize - delta;
        } else {
            divisor = hasProfit ? nextSize - delta : nextSize + delta;
        }
        return (_nextPrice * nextSize) / divisor;
    }

    // for longs: nextAveragePrice = (nextPrice * nextSize)/ (nextSize + delta)
    // for shorts: nextAveragePrice = (nextPrice * nextSize) / (nextSize - delta)
    function getNextGlobalShortAveragePrice(address _indexToken, uint256 _nextPrice, uint256 _sizeDelta)
        public
        view
        returns (uint256)
    {
        uint256 size = globalShortSizes[_indexToken];
        uint256 averagePrice = globalShortAveragePrices[_indexToken];
        uint256 priceDelta = averagePrice > _nextPrice ? averagePrice - _nextPrice : _nextPrice - averagePrice;
        uint256 delta = (size * priceDelta) / averagePrice;
        bool hasProfit = averagePrice > _nextPrice;

        uint256 nextSize = size + _sizeDelta;
        uint256 divisor = hasProfit ? nextSize - delta : nextSize + delta;

        return (_nextPrice * nextSize) / divisor;
    }

    function getNextGlobalLongAveragePrice(address _indexToken, uint256 _nextPrice, uint256 _sizeDelta)
        public
        view
        returns (uint256)
    {
        uint256 size = globalLongSizes[_indexToken];
        uint256 averagePrice = globalLongAveragePrices[_indexToken];
        uint256 priceDelta = averagePrice > _nextPrice ? averagePrice - _nextPrice : _nextPrice - averagePrice;
        uint256 delta = (size * priceDelta) / averagePrice;
        bool hasProfit = averagePrice < _nextPrice;

        uint256 nextSize = size + _sizeDelta;
        uint256 divisor = hasProfit ? nextSize + delta : nextSize - delta;

        return (_nextPrice * nextSize) / divisor;
    }

    function getGlobalShortDelta(uint256 _tokenPrice, address _token) external view returns (bool, uint256) {
        uint256 size = globalShortSizes[_token];
        if (size == 0) {
            return (false, 0);
        }

        uint256 nextPrice = _tokenPrice;
        uint256 averagePrice = globalShortAveragePrices[_token];
        uint256 priceDelta = averagePrice > nextPrice ? averagePrice - nextPrice : nextPrice - averagePrice;
        uint256 delta = (size * priceDelta) / averagePrice;
        bool hasProfit = averagePrice > nextPrice;

        return (hasProfit, delta);
    }

    function getPositionDelta(address _account, address _indexToken, bool _isLong)
        public
        view
        returns (bool, uint256)
    {
        bytes32 key = getPositionKey(_account, _indexToken, _isLong);
        Position memory position = positions[key];
        return getDelta(_indexToken, position.size, position.averagePrice, _isLong, position.lastIncreasedTime);
    }

    function getDelta(
        address _indexToken,
        uint256 _size,
        uint256 _averagePrice,
        bool _isLong,
        uint256 _lastIncreasedTime
    ) public view override returns (bool, uint256) {
        if (_averagePrice == 0) revert Vault_AveragePriceZero();
        uint256 price = _isLong ? getMinPrice(_indexToken) : getMaxPrice(_indexToken);
        uint256 priceDelta = _averagePrice > price ? _averagePrice - price : price - _averagePrice;
        uint256 delta = (_size * priceDelta) / _averagePrice;

        bool hasProfit = _isLong ? price > _averagePrice : _averagePrice > price;

        // if the minProfitTime has passed then there will be no min profit threshold
        // the min profit threshold helps to prevent front-running issues
        uint256 minBps = block.timestamp > _lastIncreasedTime + minProfitTime ? 0 : minProfitBasisPoints[_indexToken];
        if (hasProfit && delta * BASIS_POINTS_DIVISOR <= _size * minBps) {
            delta = 0;
        }

        return (hasProfit, delta);
    }

    function getDeltaAtPrice(
        uint256 _markPrice,
        address _indexToken,
        uint256 _size,
        uint256 _averagePrice,
        bool _isLong,
        uint256 _lastIncreasedTime
    ) public view override returns (bool, uint256) {
        if (_averagePrice == 0) revert Vault_AveragePriceZero();
        uint256 price = _markPrice;
        uint256 priceDelta = _averagePrice > price ? _averagePrice - price : price - _averagePrice;
        uint256 delta = (_size * priceDelta) / _averagePrice;

        bool hasProfit = _isLong ? price > _averagePrice : _averagePrice > price;

        // if the minProfitTime has passed then there will be no min profit threshold
        // the min profit threshold helps to prevent front-running issues
        uint256 minBps = block.timestamp > _lastIncreasedTime + minProfitTime ? 0 : minProfitBasisPoints[_indexToken];
        if (hasProfit && delta * BASIS_POINTS_DIVISOR <= _size * minBps) {
            delta = 0;
        }

        return (hasProfit, delta);
    }

    function getEntryFundingRate(address _indexToken, bool _isLong) public view returns (uint256) {
        return cumulativeFundingRates[_indexToken][_isLong];
    }

    function getFundingFee(
        address, /* _account */
        address _indexToken,
        bool _isLong,
        uint256 _size,
        uint256 _entryFundingRate
    ) public view returns (uint256) {
        if (_size == 0) {
            return 0;
        }

        uint256 fundingRate = cumulativeFundingRates[_indexToken][_isLong] - _entryFundingRate;
        if (fundingRate == 0) {
            return 0;
        }

        return (_size * fundingRate) / FUNDING_RATE_PRECISION;
    }

    function getPositionFee(address, /* _account */ address, /* _indexToken */ bool, /* _isLong */ uint256 _sizeDelta)
        public
        view
        returns (uint256)
    {
        if (_sizeDelta == 0) {
            return 0;
        }
        uint256 afterFeeUsd = (_sizeDelta * (BASIS_POINTS_DIVISOR - marginFeeBasisPoints)) / BASIS_POINTS_DIVISOR;
        return _sizeDelta - afterFeeUsd;
    }

    function _reduceCollateral(
        address _account,
        address _indexToken,
        uint256 _collateralDelta,
        uint256 _sizeDelta,
        bool _isLong
    ) private returns (uint256, uint256) {
        bytes32 key = getPositionKey(_account, _indexToken, _isLong);
        Position storage position = positions[key];

        uint256 fee =
            _collectMarginFees(_account, _indexToken, _isLong, _sizeDelta, position.size, position.entryFundingRate);
        bool hasProfit;
        uint256 adjustedDelta;

        // scope variables to avoid stack too deep errors
        {
            (bool _hasProfit, uint256 delta) =
                getDelta(_indexToken, position.size, position.averagePrice, _isLong, position.lastIncreasedTime);
            hasProfit = _hasProfit;
            // get the proportional change in pnl
            adjustedDelta = (_sizeDelta * delta) / position.size;
        }

        uint256 usdOut;
        // transfer profits out
        if (hasProfit && adjustedDelta > 0) {
            usdOut = adjustedDelta;
            position.realisedPnl = position.realisedPnl + int256(adjustedDelta);

            // pay out realised profits from the pool amount for positions
            uint256 tokenAmount = usdToCollateralTokenMin(adjustedDelta);
            _decreasePoolAmount(tokenAmount);
        }

        if (!hasProfit && adjustedDelta > 0) {
            position.collateral -= adjustedDelta;

            // transfer realised losses to the pool for positions
            // realised losses for long positions are not transferred here as
            // _increasePoolAmount was already called in increasePosition for longs
            uint256 tokenAmount = usdToCollateralTokenMin(adjustedDelta);
            _increasePoolAmount(tokenAmount);

            position.realisedPnl -= int256(adjustedDelta);
        }

        // reduce the position's collateral by _collateralDelta
        // transfer _collateralDelta out
        if (_collateralDelta > 0) {
            usdOut += _collateralDelta;
            position.collateral -= _collateralDelta;
        }

        // if the position will be closed, then transfer the remaining collateral out
        if (position.size == _sizeDelta) {
            usdOut += position.collateral;
            position.collateral = 0;
        }

        // if the usdOut is more than the fee then deduct the fee from the usdOut directly
        // else deduct the fee from the position's collateral
        uint256 usdOutAfterFee = usdOut;
        if (usdOut > fee) {
            usdOutAfterFee = usdOut - fee;
        } else {
            position.collateral -= fee;
        }

        emit UpdatePnl(key, hasProfit, adjustedDelta);

        return (usdOut, usdOutAfterFee);
    }

    function _validatePosition(uint256 _size, uint256 _collateral) private pure {
        if (_size == 0) {
            if (_collateral != 0) revert Vault_NonZeroCollateral();
            return;
        }
        if (_size < _collateral) revert Vault_CollateralExceedsSize();
    }

    function _validateRouter(address _account) private view {
        if (msg.sender == _account) {
            return;
        }
        if (msg.sender == router) {
            return;
        }
        if (!approvedRouters[_account][msg.sender]) revert Vault_UnapprovedRouter();
    }

    function _validateTokens(address _indexToken, bool isLong) private view {
        if (!whitelistedTokens[_indexToken]) revert Vault_TokenNotWhitelisted();
        if (!shortableTokens[_indexToken]) revert Vault_TokenNotShortable();
        if (!isLong) {
            if (stableTokens[_indexToken]) revert Vault_TokenNotShortable();
        }
    }

    function _collectMarginFees(
        address _account,
        address _indexToken,
        bool _isLong,
        uint256 _sizeDelta,
        uint256 _size,
        uint256 _entryFundingRate
    ) private returns (uint256) {
        uint256 feeUsd = getPositionFee(_account, _indexToken, _isLong, _sizeDelta);

        uint256 fundingFee = getFundingFee(_account, _indexToken, _isLong, _size, _entryFundingRate);
        feeUsd += fundingFee;

        uint256 feeTokens = usdToCollateralTokenMin(feeUsd);
        feeReserve += feeTokens;

        emit CollectMarginFees(feeUsd, feeTokens);
        return feeUsd;
    }

    function _transferIn(address _token) private returns (uint256) {
        uint256 prevBalance = tokenBalances[_token];
        uint256 nextBalance = IERC20(_token).balanceOf(address(this));
        tokenBalances[_token] = nextBalance;

        return nextBalance - prevBalance;
    }

    function _transferOut(uint256 _amount, address _receiver) private {
        _validateAddr(_receiver);
        address _token = collateralToken;
        IERC20(_token).safeTransfer(_receiver, _amount);
        tokenBalances[_token] = IERC20(_token).balanceOf(address(this));
    }

    function _updateTokenBalance(address _token) private {
        uint256 nextBalance = IERC20(_token).balanceOf(address(this));
        tokenBalances[_token] = nextBalance;
    }

    function _increasePoolAmount(uint256 _amount) private {
        poolAmount += _amount;
        uint256 balance = IERC20(collateralToken).balanceOf(address(this));
        if (poolAmount > balance) revert Vault_PoolAmount();
        emit IncreasePoolAmount(_amount);
    }

    function _decreasePoolAmount(uint256 _amount) private {
        require(poolAmount >= _amount, "Vault: poolAmount exceeded");
        poolAmount -= _amount;
        if (totalReservedAmount > poolAmount) revert Vault_ReservedAmount();
        emit DecreasePoolAmount(_amount);
    }

    function _increaseUsdpAmount(uint256 _amount) private {
        usdpAmount += _amount;
        if (maxUsdpAmount != 0) {
            if (usdpAmount > maxUsdpAmount) revert Vault_MaxUsdpAmount();
        }
        emit IncreaseUsdpAmount(_amount);
    }

    function _decreaseUsdpAmount(uint256 _amount) private {
        uint256 value = usdpAmount;
        // it is possible for the USDP debt to be less than zero
        // the USDP debt is capped to zero for this case
        if (value <= _amount) {
            usdpAmount = 0;
            emit DecreaseUsdpAmount(value);
            return;
        }
        usdpAmount = value - _amount;
        emit DecreaseUsdpAmount(_amount);
    }

    function _increaseReservedAmount(address _token, bool _isLong, uint256 _amount) private {
        reservedAmounts[_token][_isLong] += _amount;
        totalReservedAmount += _amount;
        if (totalReservedAmount > poolAmount) revert Vault_ReservedAmount();
        emit IncreaseReservedAmount(_token, _isLong, _amount);
    }

    function _decreaseReservedAmount(address _token, bool _isLong, uint256 _amount) private {
        require(reservedAmounts[_token][_isLong] >= _amount, "Vault: insufficient reserve");
        totalReservedAmount -= _amount;
        reservedAmounts[_token][_isLong] -= _amount;
        emit DecreaseReservedAmount(_token, _isLong, _amount);
    }

    function _increaseGlobalLongSize(address _token, uint256 _amount) internal {
        globalLongSizes[_token] += _amount;

        uint256 maxSize = maxGlobalLongSizes[_token];
        if (maxSize != 0) {
            require(globalLongSizes[_token] <= maxSize, "Vault: max longs exceeded");
        }
    }

    function _decreaseGlobalLongSize(address _token, uint256 _amount) private {
        uint256 size = globalLongSizes[_token];
        if (_amount > size) {
            globalLongSizes[_token] = 0;
            return;
        }

        globalLongSizes[_token] = size - _amount;
    }

    function _increaseGlobalShortSize(address _token, uint256 _amount) internal {
        globalShortSizes[_token] += _amount;

        uint256 maxSize = maxGlobalShortSizes[_token];
        if (maxSize != 0) {
            require(globalShortSizes[_token] <= maxSize, "Vault: max shorts exceeded");
        }
    }

    function _decreaseGlobalShortSize(address _token, uint256 _amount) private {
        uint256 size = globalShortSizes[_token];
        if (_amount > size) {
            globalShortSizes[_token] = 0;
            return;
        }

        globalShortSizes[_token] = size - _amount;
    }

    // we have this validation as a function instead of a modifier to reduce contract size
    function _onlyGov() private view {
        if (msg.sender != gov) revert Vault_OnlyGov();
    }

    // we have this validation as a function instead of a modifier to reduce contract size
    function _validateAddr(address addr) private pure {
        require(addr != address(0), "Vault: zero addr");
    }

    // we have this validation as a function instead of a modifier to reduce contract size
    function _validateBrrrManager() private view {
        if (msg.sender != brrrManager) revert Vault_OnlyBrrrManager();
    }

    // we have this validation as a function instead of a modifier to reduce contract size
    function _validateGasPrice() private view {
        if (maxGasPrice == 0) {
            return;
        }
        if (tx.gasprice > maxGasPrice) revert Vault_MaxGasPrice();
    }

    function _adjustForRawDecimals(uint256 _amount, uint256 _decimalsDiv, uint256 _decimalsMul)
        internal
        pure
        returns (uint256)
    {
        return (_amount * (10 ** _decimalsMul)) / (10 ** _decimalsDiv);
    }

    function setAfterHook(address _afterHook) external {
        _onlyGov();
        afterHook = _afterHook;
    }

    function getMaxLeverage(address token) public view override returns (uint256 _maxLeverage) {
        if (maxLeverages[token] != 0) {
            return maxLeverages[token];
        }
        return maxLeverage;
    }

    function _handleAfterTrade(address user, uint256 volume) internal {
        if (afterHook != address(0)) {
            IVaultAfterHook(afterHook).afterTrade(user, volume);
        }
    }
}
