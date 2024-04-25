// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../access/Governable.sol";
import "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";
import "./interfaces/IFastPriceFeed.sol";
import "./interfaces/ISecondaryPriceFeed.sol";
import "../core/interfaces/IVaultPriceFeed.sol";
import "../core/interfaces/IPositionRouter.sol";
import {SafeTransferLib} from "../libraries/token/SafeTransferLib.sol";
import {PythUtils} from "./PythUtils.sol";

contract FastPriceFeed is IFastPriceFeed, ISecondaryPriceFeed, Governable {
    using PythUtils for PythStructs.Price;

    uint256 public constant PRICE_PRECISION = 10 ** 30;
    uint256 public constant BASIS_POINTS_DIVISOR = 10000;

    event SetMaxTimeDeviation(uint256 maxTimeDeviation);
    event SetHandler(address indexed handler, bool flag);

    IPyth public immutable pyth;
    IVaultPriceFeed public vaultPriceFeed;
    // allowed deviation from primary price
    uint256 public maxDeviationBasisPoints;
    uint256 public maxTimeDeviation = 1 minutes;
    mapping(address => bytes32) private pythIds;
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

    function setPythId(address _token, bytes32 _pythId) external {
        if (msg.sender != address(vaultPriceFeed)) revert FastPriceFeed_OnlyVaultPriceFeed();
        pythIds[_token] = _pythId;
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
            SafeTransferLib.safeTransferETH(refundee, address(this).balance);
        }
    }

    function setPricesAndExecute(
        address _positionRouter,
        bytes[] calldata _priceUpdateData,
        uint256 _endIndexForIncreasePositions,
        uint256 _endIndexForDecreasePositions,
        uint256 _maxIncreasePositions,
        uint256 _maxDecreasePositions
    ) external payable onlyUpdater {
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

    function getPrice(address _token, uint256 _refPrice, bool _maximize) external view override returns (uint256) {
        PythStructs.Price memory price = pyth.getPriceNoOlderThan(pythIds[_token], maxTimeDeviation);

        uint256 pythPrice = price.extractPrice();

        return _getPrice(_refPrice, pythPrice, _maximize);
    }

    function getOffchainPrice(address _token, uint256 _offchainPrice, bool _maximize)
        external
        view
        override
        returns (uint256)
    {
        uint256 primaryPrice = vaultPriceFeed.getPrimaryPrice(_token, _maximize);

        return _getPrice(primaryPrice, _offchainPrice, _maximize);
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
