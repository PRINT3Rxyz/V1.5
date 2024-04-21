// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import "../core/interfaces/IVaultPyth.sol";
import "../core/interfaces/IVaultPriceFeed.sol";
import "../core/interfaces/IBasePositionManager.sol";
import "../peripherals/interfaces/ITimelock.sol";

contract VaultReader {
    uint256 public constant BASIS_POINTS_DIVISOR = 10000;
    uint256 public constant FUNDING_RATE_PRECISION = 1000000;

    function getVaultTokenInfo(address _vault, address _positionManager, address _weth, address[] memory _tokens)
        public
        view
        returns (uint256[] memory amounts, uint256 poolAmount, uint256 usdpAmount, uint256 maxUsdpAmount)
    {
        uint256 propsLength = 6;

        IVaultPyth vault = IVaultPyth(_vault);
        IBasePositionManager positionManager = IBasePositionManager(_positionManager);

        poolAmount = vault.poolAmount();
        usdpAmount = vault.usdpAmount();
        maxUsdpAmount = vault.maxUsdpAmount();

        amounts = new uint256[](_tokens.length * propsLength);
        for (uint256 i = 0; i < _tokens.length; i++) {
            address token = _tokens[i];
            if (token == address(0)) {
                token = _weth;
            }

            amounts[i * propsLength] = vault.reservedAmounts(token, true);
            amounts[i * propsLength + 1] = vault.reservedAmounts(token, false);
            amounts[i * propsLength + 2] = vault.globalShortSizes(token);
            amounts[i * propsLength + 3] = vault.globalLongSizes(token);
            amounts[i * propsLength + 4] = positionManager.maxGlobalShortSizes(token);
            amounts[i * propsLength + 5] = positionManager.maxGlobalLongSizes(token);
        }
    }

    function validateLiquidationAtPrice(
        uint256 _markPrice,
        address _vault,
        address _account,
        address _indexToken,
        bool _isLong
    ) external view returns (uint256) {
        IVaultPyth vault = IVaultPyth(_vault);

        address indexToken = _indexToken;
        uint256 markPrice = _markPrice;
        bool isLong = _isLong;
        (
            uint256 size,
            uint256 collateral,
            uint256 averagePrice,
            uint256 entryFundingRate, /* reserveAmount */ /* realisedPnl */ /* hasProfit */
            ,
            ,
            ,
            uint256 lastIncreasedTime
        ) = vault.getPosition(_account, indexToken, _isLong);

        if (size == 0 || averagePrice == 0) return 0;

        (bool hasProfit, uint256 delta) =
            vault.getDeltaAtPrice(markPrice, indexToken, size, averagePrice, isLong, lastIncreasedTime);

        if (!hasProfit && collateral < delta) {
            return 1;
        }

        uint256 marginFees;

        {
            uint256 fundingRate = vault.cumulativeFundingRates(indexToken, isLong)
                + vault.getNextFundingRate(indexToken, isLong) - entryFundingRate;

            if (fundingRate != 0) {
                marginFees = (size * fundingRate) / FUNDING_RATE_PRECISION;
            }
        }

        uint256 afterFeeUsd = (
            size * (BASIS_POINTS_DIVISOR - ITimelock(Ownable(address(vault)).owner()).marginFeeBasisPoints())
        ) / BASIS_POINTS_DIVISOR;
        marginFees += size - afterFeeUsd;

        {
            uint256 remainingCollateral = collateral;
            if (!hasProfit) {
                remainingCollateral = collateral - delta;
            }

            if (remainingCollateral < marginFees + vault.liquidationFeeUsd()) {
                return 1;
            }

            uint256 maxLeverage = vault.getMaxLeverage(indexToken);
            if (remainingCollateral * maxLeverage < size * BASIS_POINTS_DIVISOR) {
                return 2;
            }
        }

        return 0;
    }
}
