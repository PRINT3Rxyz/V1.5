// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import "../libraries/token/IERC20.sol";
import "../libraries/token/SafeTransferLib.sol";
import "../libraries/utils/ReentrancyGuard.sol";
import "../access/Governable.sol";

import "./interfaces/IRouter.sol";
import "./interfaces/IVault.sol";
import "./interfaces/IShortsTracker.sol";
import "./interfaces/IOrderBook.sol";
import "./interfaces/IBasePositionManager.sol";
import "../peripherals/interfaces/ITimelock.sol";
import "../referrals/interfaces/IReferralStorage.sol";

contract BasePositionManager is IBasePositionManager, ReentrancyGuard, Governable {
    using SafeTransferLib for *;

    uint256 public constant BASIS_POINTS_DIVISOR = 10000;

    address public admin;

    address public vault;
    address public shortsTracker;
    address public router;
    address public collateralToken;

    // to prevent using the deposit and withdrawal of collateral as a zero fee swap,
    // there is a small depositFee charged if a collateral deposit results in the decrease
    // of leverage for an existing position
    // increasePositionBufferBps allows for a small amount of decrease of leverage
    uint256 public depositFee;
    uint256 public increasePositionBufferBps;

    address public referralStorage;

    uint256 public feeReserve;

    mapping(address => uint256) public override maxGlobalLongSizes;
    mapping(address => uint256) public override maxGlobalShortSizes;
    mapping(address => bool) public isHandler;

    event SetHandler(address indexed handler, bool isHandler);
    event SetDepositFee(uint256 depositFee);
    event SetIncreasePositionBufferBps(uint256 increasePositionBufferBps);
    event SetReferralStorage(address referralStorage);
    event SetAdmin(address admin);
    event WithdrawFees(address indexed receiver, uint256 amount);

    event SetMaxGlobalSizes(address[] tokens, uint256[] longSizes, uint256[] shortSizes);

    event IncreasePositionReferral(
        address account, uint256 sizeDelta, uint256 marginFeeBasisPoints, bytes32 referralCode, address referrer
    );

    event DecreasePositionReferral(
        address account, uint256 sizeDelta, uint256 marginFeeBasisPoints, bytes32 referralCode, address referrer
    );

    modifier onlyAdmin() {
        require(msg.sender == admin, "BasePositionManager: forbidden");
        _;
    }

    modifier onlyHandlerAndAbove() {
        require(msg.sender == admin || isHandler[msg.sender], "BasePositionManager: forbidden");
        _;
    }

    constructor(
        address _vault,
        address _router,
        address _collateralToken,
        address _shortsTracker,
        uint256 _depositFee
    ) {
        vault = _vault;
        router = _router;
        // require(_depositFee < BASIS_POINTS_DIVISOR, "BasePositionManager: invalid deposit fee");
        depositFee = _depositFee;
        shortsTracker = _shortsTracker;
        collateralToken = _collateralToken;
        admin = msg.sender;

        increasePositionBufferBps = 100;
    }

    function setAdmin(address _admin) external onlyGov {
        admin = _admin;
        emit SetAdmin(_admin);
    }

    function setDepositFee(uint256 _depositFee) external onlyAdmin {
        require(_depositFee < BASIS_POINTS_DIVISOR, "BasePositionManager: invalid deposit fee");
        depositFee = _depositFee;
        emit SetDepositFee(_depositFee);
    }

    function setHandler(address _account, bool _isActive) external onlyAdmin {
        isHandler[_account] = _isActive;
        emit SetHandler(_account, _isActive);
    }

    function setIncreasePositionBufferBps(uint256 _increasePositionBufferBps) external onlyAdmin {
        increasePositionBufferBps = _increasePositionBufferBps;
        emit SetIncreasePositionBufferBps(_increasePositionBufferBps);
    }

    function setReferralStorage(address _referralStorage) external onlyAdmin {
        referralStorage = _referralStorage;
        emit SetReferralStorage(_referralStorage);
    }

    function setMaxGlobalSizes(address[] memory _tokens, uint256[] memory _longSizes, uint256[] memory _shortSizes)
        external
        onlyHandlerAndAbove
    {
        for (uint256 i = 0; i < _tokens.length; i++) {
            address token = _tokens[i];
            maxGlobalLongSizes[token] = _longSizes[i];
            maxGlobalShortSizes[token] = _shortSizes[i];
        }

        emit SetMaxGlobalSizes(_tokens, _longSizes, _shortSizes);
    }

    function withdrawFees(address _receiver) external onlyHandlerAndAbove {
        uint256 amount = feeReserve;
        if (amount == 0) {
            return;
        }

        feeReserve = 0;
        IERC20(collateralToken).safeTransfer(_receiver, amount);

        emit WithdrawFees(_receiver, amount);
    }

    function approve(address _token, address _spender, uint256 _amount) external onlyGov {
        IERC20(_token).approve(_spender, _amount);
    }

    function sendValue(address payable _receiver, uint256 _amount) external onlyGov {
        _receiver.safeTransferETH(_amount);
    }

    function _validateMaxGlobalSize(address _indexToken, bool _isLong, uint256 _sizeDelta) internal view {
        if (_sizeDelta == 0) {
            return;
        }

        if (_isLong) {
            uint256 maxGlobalLongSize = maxGlobalLongSizes[_indexToken];
            if (maxGlobalLongSize > 0 && IVault(vault).globalLongSizes(_indexToken) + _sizeDelta > maxGlobalLongSize) {
                revert("BasePositionManager: max global longs exceeded");
            }
        } else {
            uint256 maxGlobalShortSize = maxGlobalShortSizes[_indexToken];
            if (maxGlobalShortSize > 0 && IVault(vault).globalShortSizes(_indexToken) + _sizeDelta > maxGlobalShortSize)
            {
                revert("BasePositionManager: max global shorts exceeded");
            }
        }
    }

    function _increasePosition(address _account, address _indexToken, uint256 _sizeDelta, bool _isLong, uint256 _price)
        internal
    {
        address _vault = vault;

        uint256 markPrice = _isLong ? IVault(_vault).getMaxPrice(_indexToken) : IVault(_vault).getMinPrice(_indexToken);
        if (_isLong) {
            require(markPrice <= _price, "BasePositionManager: mark price higher than limit");
        } else {
            require(markPrice >= _price, "BasePositionManager: mark price lower than limit");
        }

        _validateMaxGlobalSize(_indexToken, _isLong, _sizeDelta);

        address timelock = IVault(_vault).gov();

        // should be called strictly before position is updated in Vault
        IShortsTracker(shortsTracker).updateGlobalShortData(_account, _indexToken, _isLong, _sizeDelta, markPrice, true);

        ITimelock(timelock).enableLeverage(_vault);
        IRouter(router).pluginIncreasePosition(_account, _indexToken, _sizeDelta, _isLong);
        ITimelock(timelock).disableLeverage(_vault);

        _emitIncreasePositionReferral(_account, _sizeDelta);
    }

    function _decreasePosition(
        address _account,
        address _indexToken,
        uint256 _collateralDelta,
        uint256 _sizeDelta,
        bool _isLong,
        address _receiver,
        uint256 _price
    ) internal returns (uint256) {
        address _vault = vault;

        uint256 markPrice = _isLong ? IVault(_vault).getMinPrice(_indexToken) : IVault(_vault).getMaxPrice(_indexToken);
        if (_isLong) {
            require(markPrice >= _price, "BasePositionManager: mark price lower than limit");
        } else {
            require(markPrice <= _price, "BasePositionManager: mark price higher than limit");
        }

        address timelock = IVault(_vault).gov();

        // should be called strictly before position is updated in Vault
        IShortsTracker(shortsTracker).updateGlobalShortData(
            _account, _indexToken, _isLong, _sizeDelta, markPrice, false
        );

        ITimelock(timelock).enableLeverage(_vault);
        uint256 amountOut = IRouter(router).pluginDecreasePosition(
            _account, _indexToken, _collateralDelta, _sizeDelta, _isLong, _receiver
        );
        ITimelock(timelock).disableLeverage(_vault);

        _emitDecreasePositionReferral(_account, _sizeDelta);

        return amountOut;
    }

    function _emitIncreasePositionReferral(address _account, uint256 _sizeDelta) internal {
        address _referralStorage = referralStorage;
        if (_referralStorage == address(0)) {
            return;
        }

        (bytes32 referralCode, address referrer) = IReferralStorage(_referralStorage).getTraderReferralInfo(_account);
        emit IncreasePositionReferral(
            _account, _sizeDelta, IVault(vault).marginFeeBasisPoints(), referralCode, referrer
        );
    }

    function _emitDecreasePositionReferral(address _account, uint256 _sizeDelta) internal {
        address _referralStorage = referralStorage;
        if (_referralStorage == address(0)) {
            return;
        }

        (bytes32 referralCode, address referrer) = IReferralStorage(_referralStorage).getTraderReferralInfo(_account);

        if (referralCode == bytes32(0)) {
            return;
        }

        emit DecreasePositionReferral(
            _account, _sizeDelta, IVault(vault).marginFeeBasisPoints(), referralCode, referrer
        );
    }

    function _transferOutETH(uint256 _amountOut, address payable _receiver) internal {
        (bool success,) = _receiver.call{value: _amountOut}("");
        require(success, "BasePositionManager: eth transfer failed");
    }

    function _collectFees(address _account, uint256 _amountIn, address _indexToken, bool _isLong, uint256 _sizeDelta)
        internal
        returns (uint256)
    {
        bool shouldDeductFee = _shouldDeductFee(_account, _amountIn, _indexToken, _isLong, _sizeDelta);

        if (shouldDeductFee) {
            uint256 afterFeeAmount = (_amountIn * (BASIS_POINTS_DIVISOR - depositFee)) / BASIS_POINTS_DIVISOR;
            uint256 feeAmount = _amountIn - afterFeeAmount;
            feeReserve = feeReserve + feeAmount;
            return afterFeeAmount;
        }

        return _amountIn;
    }

    function _shouldDeductFee(
        address _account,
        uint256 _amountIn,
        address _indexToken,
        bool _isLong,
        uint256 _sizeDelta
    ) internal view returns (bool) {
        // if the position is a short, do not charge a fee
        if (!_isLong) {
            return false;
        }

        // if the position size is not increasing, this is a collateral deposit
        if (_sizeDelta == 0) {
            return true;
        }

        IVault _vault = IVault(vault);
        (uint256 size, uint256 collateral,,,,,,) = _vault.getPosition(_account, _indexToken, _isLong);

        // if there is no existing position, do not charge a fee
        if (size == 0) {
            return false;
        }

        uint256 nextSize = size + _sizeDelta;
        uint256 collateralDelta = _vault.tokenToUsdMin(collateralToken, _amountIn);
        uint256 nextCollateral = collateral + collateralDelta;

        uint256 prevLeverage = (size * BASIS_POINTS_DIVISOR) / collateral;
        uint256 nextLeverage = (nextSize * (BASIS_POINTS_DIVISOR + increasePositionBufferBps)) / nextCollateral;

        // deduct a fee if the leverage is decreased
        return nextLeverage < prevLeverage;
    }

    uint256[50] private __gap;
}
