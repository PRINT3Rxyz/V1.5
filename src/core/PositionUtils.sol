// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import "../peripherals/interfaces/ITimelock.sol";

import "./interfaces/IVault.sol";
import "./interfaces/IRouter.sol";
import "./interfaces/IShortsTracker.sol";

library PositionUtils {
    uint256 public constant BASIS_POINTS_DIVISOR = 10000;

    event LeverageDecreased(uint256 collateralDelta, uint256 prevLeverage, uint256 nextLeverage);

    function shouldDeductFee(
        address _vault,
        address _account,
        address[] memory _path,
        uint256 _amountIn,
        address _indexToken,
        bool _isLong,
        uint256 _sizeDelta,
        uint256 _increasePositionBufferBps
    ) external returns (bool) {
        // if the position is a short, do not charge a fee
        if (!_isLong) return false;

        // if the position size is not increasing, this is a collateral deposit
        if (_sizeDelta == 0) return true;

        address collateralToken = _path[_path.length - 1];

        IVault vault = IVault(_vault);
        (uint256 size, uint256 collateral,,,,,,) = vault.getPosition(_account, _indexToken, _isLong);

        // if there is no existing position, do not charge a fee
        if (size == 0) return false;

        uint256 nextSize = size + _sizeDelta;
        uint256 collateralDelta = vault.tokenToUsdMin(collateralToken, _amountIn);
        uint256 nextCollateral = collateral + collateralDelta;

        uint256 prevLeverage = (size * BASIS_POINTS_DIVISOR) / collateral;
        // allow for a maximum of a increasePositionBufferBps decrease since there might be some swap fees taken from the collateral
        uint256 nextLeverage = (nextSize * (BASIS_POINTS_DIVISOR + _increasePositionBufferBps)) / nextCollateral;

        emit LeverageDecreased(collateralDelta, prevLeverage, nextLeverage);

        // deduct a fee if the leverage is decreased
        return nextLeverage < prevLeverage;
    }

    function increasePosition(
        address _vault,
        address _router,
        address _shortsTracker,
        address _account,
        address _indexToken,
        uint256 _sizeDelta,
        bool _isLong,
        uint256 _price
    ) external {
        uint256 markPrice = _isLong ? IVault(_vault).getMaxPrice(_indexToken) : IVault(_vault).getMinPrice(_indexToken);
        if (_isLong) {
            require(markPrice <= _price, "markPrice > price");
        } else {
            require(markPrice >= _price, "markPrice < price");
        }

        address timelock = IVault(_vault).gov();

        // should be called strictly before position is updated in Vault
        IShortsTracker(_shortsTracker).updateGlobalShortData(
            _account, _indexToken, _isLong, _sizeDelta, markPrice, true
        );

        ITimelock(timelock).enableLeverage(_vault);
        IRouter(_router).pluginIncreasePosition(_account, _indexToken, _sizeDelta, _isLong);
        ITimelock(timelock).disableLeverage(_vault);
    }
}
