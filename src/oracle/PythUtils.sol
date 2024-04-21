// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {PythStructs} from "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";

library PythUtils {
    uint8 private constant PRICE_DECIMALS = 30;

    function extractPrice(PythStructs.Price memory _priceData) internal pure returns (uint256 price) {
        (price,) = _getPriceAndConfidence(_priceData);
    }

    function extractPrice(PythStructs.Price memory _priceData, bool _maximize) internal pure returns (uint256) {
        (uint256 price, uint256 confidence) = _getPriceAndConfidence(_priceData);
        return _maximize ? price + confidence : price - confidence;
    }

    function createPriceFeedUpdateData(
        bytes32 id,
        int64 price,
        uint64 conf,
        int32 expo,
        int64 emaPrice,
        uint64 emaConf,
        uint64 publishTime
    ) public pure returns (bytes memory priceFeedData) {
        PythStructs.PriceFeed memory priceFeed;

        priceFeed.id = id;

        priceFeed.price.price = price;
        priceFeed.price.conf = conf;
        priceFeed.price.expo = expo;
        priceFeed.price.publishTime = publishTime;

        priceFeed.emaPrice.price = emaPrice;
        priceFeed.emaPrice.conf = emaConf;
        priceFeed.emaPrice.expo = expo;
        priceFeed.emaPrice.publishTime = publishTime;

        priceFeedData = abi.encode(priceFeed);
    }

    function _getPriceAndConfidence(PythStructs.Price memory _priceData)
        private
        pure
        returns (uint256 price, uint256 confidence)
    {
        uint256 absPrice = _priceData.price > 0 ? uint64(_priceData.price) : uint64(-_priceData.price);
        uint256 absExponent = _priceData.expo > 0 ? uint32(_priceData.expo) : uint32(-_priceData.expo);
        price = absPrice * (10 ** (PRICE_DECIMALS - absExponent));
        confidence = _priceData.conf * (10 ** (PRICE_DECIMALS - absExponent));
    }
}
