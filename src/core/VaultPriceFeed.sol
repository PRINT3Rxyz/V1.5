// SPDX-License-Identifier: MIT

import "../access/Governable.sol";
import "./interfaces/IVaultPriceFeed.sol";
import "../oracle/interfaces/ISecondaryPriceFeed.sol";
import "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";
import "../oracle/PythUtils.sol";

pragma solidity ^0.8.20;

contract VaultPriceFeed is Governable, IVaultPriceFeed {
    using PythUtils for PythStructs.Price;

    uint256 public constant PRICE_PRECISION = 10 ** 30;
    uint256 public constant ONE_USD = PRICE_PRECISION;
    uint256 public constant BASIS_POINTS_DIVISOR = 10000;
    uint256 public constant MAX_SPREAD_BASIS_POINTS = 50;
    uint256 public constant MAX_ADJUSTMENT_INTERVAL = 2 hours;
    uint256 public constant MAX_ADJUSTMENT_BASIS_POINTS = 20;

    IPyth public immutable pyth;

    bool public isSecondaryPriceEnabled = true;
    bool public useV2Pricing = false;
    bool public favorPrimaryPrice = false;
    uint256 public priceSampleSpace = 3;
    uint256 public maxStrictPriceDeviation = 0;
    address public secondaryPriceFeed;
    uint256 public spreadThresholdBasisPoints = 30;

    mapping(address => uint256) public priceDecimals;
    mapping(address => uint256) public spreadBasisPoints;
    // Chainlink can return prices for stablecoins
    // that differs from 1 USD by a larger percentage than stableSwapFeeBasisPoints
    // we use strictStableTokens to cap the price to 1 USD
    // this allows us to configure stablecoins like DAI as being a stableToken
    // while not being a strictStableToken

    mapping(address token => bytes32 pythId) public pythIds;

    mapping(address => bool) public strictStableTokens;

    mapping(address => uint256) public override adjustmentBasisPoints;
    mapping(address => bool) public override isAdjustmentAdditive;
    mapping(address => uint256) public lastAdjustmentTimings;

    constructor(address _pyth) {
        pyth = IPyth(_pyth);
    }

    function setAdjustment(address _token, bool _isAdditive, uint256 _adjustmentBps) external override onlyGov {
        require(
            lastAdjustmentTimings[_token] + MAX_ADJUSTMENT_INTERVAL < block.timestamp,
            "VaultPriceFeed: adjustment frequency exceeded"
        );
        require(_adjustmentBps <= MAX_ADJUSTMENT_BASIS_POINTS, "invalid _adjustmentBps");
        isAdjustmentAdditive[_token] = _isAdditive;
        adjustmentBasisPoints[_token] = _adjustmentBps;
        lastAdjustmentTimings[_token] = block.timestamp;
    }

    function setUseV2Pricing(bool _useV2Pricing) external override onlyGov {
        useV2Pricing = _useV2Pricing;
    }

    function setIsSecondaryPriceEnabled(bool _isEnabled) external override onlyGov {
        isSecondaryPriceEnabled = _isEnabled;
    }

    function setSecondaryPriceFeed(address _secondaryPriceFeed) external onlyGov {
        secondaryPriceFeed = _secondaryPriceFeed;
    }

    function setSpreadBasisPoints(address _token, uint256 _spreadBasisPoints) external override onlyGov {
        require(_spreadBasisPoints <= MAX_SPREAD_BASIS_POINTS, "VaultPriceFeed: invalid _spreadBasisPoints");
        spreadBasisPoints[_token] = _spreadBasisPoints;
    }

    function setSpreadThresholdBasisPoints(uint256 _spreadThresholdBasisPoints) external override onlyGov {
        spreadThresholdBasisPoints = _spreadThresholdBasisPoints;
    }

    function setFavorPrimaryPrice(bool _favorPrimaryPrice) external override onlyGov {
        favorPrimaryPrice = _favorPrimaryPrice;
    }

    function setPriceSampleSpace(uint256 _priceSampleSpace) external override onlyGov {
        require(_priceSampleSpace > 0, "VaultPriceFeed: invalid _priceSampleSpace");
        priceSampleSpace = _priceSampleSpace;
    }

    function setMaxStrictPriceDeviation(uint256 _maxStrictPriceDeviation) external override onlyGov {
        maxStrictPriceDeviation = _maxStrictPriceDeviation;
    }

    function setTokenConfig(address _token, uint256 _priceDecimals, bool _isStrictStable, bytes32 _pythId)
        external
        override
        onlyGov
    {
        priceDecimals[_token] = _priceDecimals;
        strictStableTokens[_token] = _isStrictStable;
        pythIds[_token] = _pythId;
        ISecondaryPriceFeed(secondaryPriceFeed).setPythId(_token, _pythId);
    }

    function getPrice(address _token, bool _maximize, bool /* _useSwapPricing */ )
        public
        view
        override
        returns (uint256)
    {
        uint256 price = useV2Pricing ? getPriceV2(_token, _maximize) : getPriceV1(_token, _maximize);

        uint256 adjustmentBps = adjustmentBasisPoints[_token];
        if (adjustmentBps > 0) {
            bool isAdditive = isAdjustmentAdditive[_token];
            if (isAdditive) {
                price = (price * (BASIS_POINTS_DIVISOR + adjustmentBps)) / BASIS_POINTS_DIVISOR;
            } else {
                price = (price * (BASIS_POINTS_DIVISOR - adjustmentBps)) / BASIS_POINTS_DIVISOR;
            }
        }

        return price;
    }

    function getPriceV1(address _token, bool _maximize) public view returns (uint256) {
        uint256 price = getPrimaryPrice(_token, _maximize);

        if (isSecondaryPriceEnabled) {
            price = getSecondaryPrice(_token, price, _maximize);
        }

        if (strictStableTokens[_token]) {
            uint256 delta = price > ONE_USD ? price - ONE_USD : ONE_USD - price;
            if (delta <= maxStrictPriceDeviation) {
                return ONE_USD;
            }

            // if _maximize and price is e.g. 1.02, return 1.02
            if (_maximize && price > ONE_USD) {
                return price;
            }

            // if !_maximize and price is e.g. 0.98, return 0.98
            if (!_maximize && price < ONE_USD) {
                return price;
            }

            return ONE_USD;
        }

        uint256 _spreadBasisPoints = spreadBasisPoints[_token];

        if (_maximize) {
            return (price * (BASIS_POINTS_DIVISOR + _spreadBasisPoints)) / BASIS_POINTS_DIVISOR;
        }

        return (price * (BASIS_POINTS_DIVISOR - _spreadBasisPoints)) / BASIS_POINTS_DIVISOR;
    }

    function getPriceV2(address _token, bool _maximize) public view returns (uint256) {
        uint256 price = getPrimaryPrice(_token, _maximize);

        if (isSecondaryPriceEnabled) {
            price = getSecondaryPrice(_token, price, _maximize);
        }

        if (strictStableTokens[_token]) {
            uint256 delta = price > ONE_USD ? price - ONE_USD : ONE_USD - price;
            if (delta <= maxStrictPriceDeviation) {
                return ONE_USD;
            }

            // if _maximize and price is e.g. 1.02, return 1.02
            if (_maximize && price > ONE_USD) {
                return price;
            }

            // if !_maximize and price is e.g. 0.98, return 0.98
            if (!_maximize && price < ONE_USD) {
                return price;
            }

            return ONE_USD;
        }

        uint256 _spreadBasisPoints = spreadBasisPoints[_token];

        if (_maximize) {
            return (price * (BASIS_POINTS_DIVISOR + _spreadBasisPoints)) / BASIS_POINTS_DIVISOR;
        }

        return (price * (BASIS_POINTS_DIVISOR - _spreadBasisPoints)) / BASIS_POINTS_DIVISOR;
    }

    function getLatestPrimaryPrice(address _token) public view override returns (uint256) {
        bytes32 priceId = pythIds[_token];
        require(priceId != bytes32(0), "VaultPriceFeed: invalid pyth id");
        PythStructs.Price memory priceData = pyth.getPriceUnsafe(priceId);

        require(priceData.price > 0, "VaultPriceFeed: invalid price");

        return priceData.extractPrice();
    }

    function getPrimaryPrice(address _token, bool _maximize) public view returns (uint256) {
        bytes32 priceId = pythIds[_token];
        require(priceId != bytes32(0), "VaultPriceFeed: invalid pyth id");
        PythStructs.Price memory priceData = pyth.getEmaPriceUnsafe(priceId);

        require(priceData.price > 0, "VaultPriceFeed: invalid price");
        // normalise price precision
        return priceData.extractPrice(_maximize);
    }

    function getSecondaryPrice(address _token, uint256 _referencePrice, bool _maximize) public view returns (uint256) {
        if (secondaryPriceFeed == address(0)) {
            return _referencePrice;
        }
        return ISecondaryPriceFeed(secondaryPriceFeed).getPrice(_token, _referencePrice, _maximize);
    }
}
