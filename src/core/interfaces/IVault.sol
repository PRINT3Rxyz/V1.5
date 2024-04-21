// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IVault {
    struct Position {
        uint256 size;
        uint256 collateral;
        uint256 averagePrice;
        uint256 entryFundingRate;
        uint256 reserveAmount;
        int256 realisedPnl;
        uint256 lastIncreasedTime;
    }

    event LiquidityAdded(uint256 tokenAmount, uint256 usdpAmount, uint256 feeBasisPoints);
    event LiquidityRemoved(uint256 usdpAmount, uint256 tokenAmount, uint256 feeBasisPoints);

    event IncreasePosition(
        bytes32 key,
        address account,
        address indexToken,
        uint256 collateralDelta,
        uint256 sizeDelta,
        bool isLong,
        uint256 price,
        uint256 fee
    );
    event DecreasePosition(
        bytes32 key,
        address account,
        address indexToken,
        uint256 collateralDelta,
        uint256 sizeDelta,
        bool isLong,
        uint256 price,
        uint256 fee
    );
    event LiquidatePosition(
        bytes32 key,
        address account,
        address indexToken,
        bool isLong,
        uint256 size,
        uint256 collateral,
        uint256 reserveAmount,
        int256 realisedPnl,
        uint256 markPrice
    );
    event UpdatePosition(
        bytes32 key,
        uint256 size,
        uint256 collateral,
        uint256 averagePrice,
        uint256 entryFundingRate,
        uint256 reserveAmount,
        int256 realisedPnl,
        uint256 markPrice
    );
    event ClosePosition(
        bytes32 key,
        uint256 size,
        uint256 collateral,
        uint256 averagePrice,
        uint256 entryFundingRate,
        uint256 reserveAmount,
        int256 realisedPnl
    );

    event UpdateFundingRate(address indexed token, bool indexed isLong, uint256 fundingRate);
    event UpdatePnl(bytes32 key, bool hasProfit, uint256 delta);

    event CollectMarginFees(uint256 feeUsd, uint256 feeTokens);

    event DirectPoolDeposit(uint256 amount);
    event IncreasePoolAmount(uint256 amount);
    event DecreasePoolAmount(uint256 amount);
    event IncreaseUsdpAmount(uint256 amount);
    event DecreaseUsdpAmount(uint256 amount);
    event IncreaseReservedAmount(address indexed token, bool indexed isLong, uint256 amount);
    event DecreaseReservedAmount(address indexed token, bool indexed isLong, uint256 amount);

    error Vault_AlreadyInitialized();
    error Vault_LiquidationFee();
    error Vault_FundingRateFactor();
    error Vault_MaxLeverage();
    error Vault_TokenNotWhitelisted();
    error Vault_TaxBasisPoints();
    error Vault_MintBurnFeeBasisPoints();
    error Vault_MarginFeeBasisPoints();
    error Vault_FundingInterval();
    error Vault_ZeroAmount();
    error Vault_ZeroSize();
    error Vault_InsufficientCollateral();
    error Vault_InsufficientSize();
    error Vault_LossesExceedCollateral();
    error Vault_FeesExceedCollateral();
    error Vault_LiquidationFeesExceedCollateral();
    error Vault_MaxLeverageExceeded();
    error Vault_NotLiquidator();
    error Vault_NotLiquidatable();
    error Vault_LeverageDisabled();
    error Vault_ZeroCollateral();
    error Vault_AveragePriceZero();
    error Vault_NonZeroCollateral();
    error Vault_OnlyGov();
    error Vault_OnlyBrrrManager();
    error Vault_MaxGasPrice();
    error Vault_CollateralExceedsSize();
    error Vault_UnapprovedRouter();
    error Vault_TokenNotShortable();
    error Vault_PoolAmount();
    error Vault_ReservedAmount();
    error Vault_MaxUsdpAmount();

    function isInitialized() external view returns (bool);

    function isLeverageEnabled() external view returns (bool);

    function router() external view returns (address);

    function gov() external view returns (address);

    function collateralToken() external view returns (address);

    function whitelistedTokenCount() external view returns (uint256);

    function maxLeverage() external view returns (uint256);

    function minProfitTime() external view returns (uint256);

    function fundingInterval() external view returns (uint256);

    function maxGasPrice() external view returns (uint256);

    function approvedRouters(address _account, address _router) external view returns (bool);

    function isLiquidator(address _account) external view returns (bool);

    function brrrManager() external view returns (address);

    function minProfitBasisPoints(address _token) external view returns (uint256);

    function tokenBalances(address _token) external view returns (uint256);

    function lastFundingTimes(address _token, bool _isLong) external view returns (uint256);

    function estimateUSDPOut(uint256 _amount) external view returns (uint256);

    function estimateTokenIn(uint256 _usdpAmount) external view returns (uint256);

    function setMaxLeverage(uint256 _maxLeverage) external;

    function setBrrrManager(address _manager) external;

    function setIsLeverageEnabled(bool _isLeverageEnabled) external;

    function setMaxGasPrice(uint256 _maxGasPrice) external;

    function setUsdpAmount(uint256 _amount) external;

    function setMaxGlobalSize(address _token, uint256 _longAmount, uint256 _shortAmount) external;

    function setLiquidator(address _liquidator, bool _isActive) external;

    function setFundingRate(uint256 _fundingInterval, uint256 _fundingRateFactor) external;

    function setFees(
        uint256 _taxBasisPoints,
        uint256 _mintBurnFeeBasisPoints,
        uint256 _marginFeeBasisPoints,
        uint256 _liquidationFeeUsd,
        uint256 _minProfitTime
    ) external;

    function setMaxUsdpAmounts(uint256 _maxUsdpAmounts) external;

    function setTokenConfig(
        address _token,
        uint256 _tokenDecimals,
        uint256 _minProfitBps,
        bool _isStable,
        bool _isShortable
    ) external;
    function clearTokenConfig(address _token) external;

    function setPriceFeed(address _priceFeed) external;

    function withdrawFees(address _receiver) external returns (uint256);

    function directPoolDeposit() external;

    function addLiquidity() external returns (uint256);

    function removeLiquidity(address _receiver, uint256 _usdpAmount) external returns (uint256);

    function increasePosition(address _account, address _indexToken, uint256 _sizeDelta, bool _isLong) external;

    function decreasePosition(
        address _account,
        address _indexToken,
        uint256 _collateralDelta,
        uint256 _sizeDelta,
        bool _isLong,
        address _receiver
    ) external returns (uint256);

    function validateLiquidation(address _account, address _indexToken, bool _isLong, bool _raise)
        external
        view
        returns (uint256, uint256);

    function liquidatePosition(address _account, address _indexToken, bool _isLong, address _feeReceiver) external;

    function tokenToUsdMin(address _token, uint256 _tokenAmount) external view returns (uint256);

    function priceFeed() external view returns (address);

    function fundingRateFactor() external view returns (uint256);

    function cumulativeFundingRates(address _token, bool _isLong) external view returns (uint256);

    function getNextFundingRate(address _token, bool _isLong) external view returns (uint256);

    function liquidationFeeUsd() external view returns (uint256);

    function taxBasisPoints() external view returns (uint256);

    function mintBurnFeeBasisPoints() external view returns (uint256);

    function marginFeeBasisPoints() external view returns (uint256);

    function allWhitelistedTokensLength() external view returns (uint256);

    function allWhitelistedTokens(uint256) external view returns (address);

    function whitelistedTokens(address _token) external view returns (bool);

    function stableTokens(address _token) external view returns (bool);

    function shortableTokens(address _token) external view returns (bool);

    function feeReserve() external view returns (uint256);

    function globalShortSizes(address _token) external view returns (uint256);

    function globalLongSizes(address _token) external view returns (uint256);

    function globalShortAveragePrices(address _token) external view returns (uint256);

    function globalLongAveragePrices(address _token) external view returns (uint256);

    function maxGlobalShortSizes(address _token) external view returns (uint256);

    function maxGlobalLongSizes(address _token) external view returns (uint256);

    function tokenDecimals(address _token) external view returns (uint256);

    function poolAmount() external view returns (uint256);

    function reservedAmounts(address _token, bool _isLong) external view returns (uint256);

    function totalReservedAmount() external view returns (uint256);

    function usdpAmount() external view returns (uint256);

    function maxUsdpAmount() external view returns (uint256);

    function getRedemptionAmount(uint256 _usdpAmount) external view returns (uint256);

    function getMaxPrice(address _token) external view returns (uint256);

    function getMinPrice(address _token) external view returns (uint256);

    function getDelta(
        address _indexToken,
        uint256 _size,
        uint256 _averagePrice,
        bool _isLong,
        uint256 _lastIncreasedTime
    ) external view returns (bool, uint256);

    function getPosition(address _account, address _indexToken, bool _isLong)
        external
        view
        returns (uint256, uint256, uint256, uint256, uint256, uint256, bool, uint256);
}
