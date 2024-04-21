// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../access/Governable.sol";
import "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";
import "./interfaces/IFastPriceFeed.sol";
import "./interfaces/ISecondaryPriceFeed.sol";
import "../core/interfaces/IVaultPriceFeed.sol";
import "../core/interfaces/IPositionRouter.sol";

contract FastPriceFeed is IFastPriceFeed, ISecondaryPriceFeed, Governable {
    uint256 public constant PRICE_PRECISION = 10 ** 30;
    uint256 public constant BASIS_POINTS_DIVISOR = 10000;

    event SetMaxTimeDeviation(uint256 maxTimeDeviation);
    event SetHandler(address indexed handler, bool flag);

    IPyth public immutable pyth;
    IVaultPriceFeed public vaultPriceFeed;
    // allowed deviation from primary price
    uint256 public maxDeviationBasisPoints;
    uint256 public maxTimeDeviation = 1 minutes;
    mapping(address => bytes32) public override pythIds;
    mapping(address => bool) public isUpdater;

    modifier onlyUpdater() {
        require(isUpdater[msg.sender], "FastPriceFeed: forbidden (updater)");
        _;
    }

    constructor(address _pyth, address _vaultPriceFeed, uint256 _maxDeviationBasisPoints) {
        pyth = IPyth(_pyth);
        maxDeviationBasisPoints = _maxDeviationBasisPoints;
        vaultPriceFeed = IVaultPriceFeed(_vaultPriceFeed);
    }

    function setPythIds(address[] calldata _tokens, bytes32[] calldata _pythIds) external onlyGov {
        uint256 len = _tokens.length;
        require(len == _pythIds.length, "FastPriceFeed: invalid lengths");

        for (uint256 i; i < len;) {
            pythIds[_tokens[i]] = _pythIds[i];
            unchecked {
                ++i;
            }
        }
    }

    function setVaultPriceFeed(address _vaultPriceFeed) external onlyGov {
        vaultPriceFeed = IVaultPriceFeed(_vaultPriceFeed);
    }

    function setMaxTimeDeviation(uint256 _maxTimeDeviation) external onlyGov {
        maxTimeDeviation = _maxTimeDeviation;

        emit SetMaxTimeDeviation(_maxTimeDeviation);
    }

    function setMaxDeviationBasisPoints(uint256 _maxDeviationBasisPoints) external onlyGov {
        maxDeviationBasisPoints = _maxDeviationBasisPoints;
    }

    function setUpdater(address _account, bool _isActive) external override onlyGov {
        isUpdater[_account] = _isActive;
    }

    function getUpdateFee(bytes[] calldata priceUpdateData) external view override returns (uint256 fee) {
        fee = pyth.getUpdateFee(priceUpdateData);
    }

    function updatePriceFeeds(bytes[] calldata priceUpdateData, address refundee)
        external
        payable
        override
        onlyUpdater
    {
        uint256 fee = pyth.getUpdateFee(priceUpdateData);
        pyth.updatePriceFeeds{value: fee}(priceUpdateData);

        if (address(this).balance != 0) {
            (bool success,) = refundee.call{value: address(this).balance}("");
            require(success, "FastPriceFeed: Refund failed");
        }
    }

    function setPricesAndExecute(
        address _positionRouter,
        bytes[] calldata _priceUpdateData,
        uint256 _endIndexForIncreasePositions,
        uint256 _endIndexForDecreasePositions,
        uint256 _maxIncreasePositions,
        uint256 _maxDecreasePositions
    ) external onlyUpdater {
        uint256 fee = pyth.getUpdateFee(_priceUpdateData);
        pyth.updatePriceFeeds{value: fee}(_priceUpdateData);

        if (address(this).balance != 0) {
            (bool success,) = payable(msg.sender).call{value: address(this).balance}("");
            require(success, "FastPriceFeed: Refund failed");
        }

        IPositionRouter positionRouter = IPositionRouter(_positionRouter);
        uint256 maxEndIndexForIncrease = positionRouter.increasePositionRequestKeysStart() + _maxIncreasePositions;
        uint256 maxEndIndexForDecrease = positionRouter.decreasePositionRequestKeysStart() + _maxDecreasePositions;

        if (_endIndexForIncreasePositions > maxEndIndexForIncrease) {
            _endIndexForIncreasePositions = maxEndIndexForIncrease;
        }

        if (_endIndexForDecreasePositions > maxEndIndexForDecrease) {
            _endIndexForDecreasePositions = maxEndIndexForDecrease;
        }

        positionRouter.executeIncreasePositions(_endIndexForIncreasePositions, payable(msg.sender));
        positionRouter.executeDecreasePositions(_endIndexForDecreasePositions, payable(msg.sender));
    }

    function getPrice(
        address _token,
        uint256 _refPrice, // redstone price
        bool _maximise
    ) external view override returns (uint256) {
        PythStructs.Price memory price = pyth.getPriceNoOlderThan(pythIds[_token], maxTimeDeviation);

        uint256 pythPrice = (uint256(uint64(price.price)) * PRICE_PRECISION) / (10 ** uint32(-price.expo));

        return _getPrice(_refPrice, pythPrice, _maximise);
    }

    function getOffchainPrice(address _token, uint256 _offchainPrice, bool _maximise)
        external
        view
        override
        returns (uint256)
    {
        uint256 primaryPrice = vaultPriceFeed.getPrimaryPrice(_token);

        return _getPrice(primaryPrice, _offchainPrice, _maximise);
    }

    function _getPrice(uint256 primaryPrice, uint256 secondaryPrice, bool maximise) internal view returns (uint256) {
        uint256 diffBasisPoints =
            primaryPrice > secondaryPrice ? primaryPrice - secondaryPrice : secondaryPrice - primaryPrice;
        diffBasisPoints = (diffBasisPoints * BASIS_POINTS_DIVISOR) / primaryPrice;

        // create a spread between the primaryPrice and the p if the maxDeviationBasisPoints is exceeded
        // or if watchers have flagged an issue with the pyth price
        if (diffBasisPoints > maxDeviationBasisPoints) {
            // return the higher of the two prices
            if (maximise) {
                return primaryPrice > secondaryPrice ? primaryPrice : secondaryPrice;
            }

            // return the lower of the two prices
            return primaryPrice < secondaryPrice ? primaryPrice : secondaryPrice;
        }

        return secondaryPrice;
    }
}
