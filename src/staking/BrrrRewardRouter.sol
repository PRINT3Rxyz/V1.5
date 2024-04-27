// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import "../libraries/token/IERC20.sol";
import "../libraries/token/SafeTransferLib.sol";
import "../libraries/utils/ReentrancyGuard.sol";

import "./interfaces/IRewardTracker.sol";
import "./interfaces/IBrrrRewardRouter.sol";
import "../tokens/interfaces/IMintable.sol";
import "../tokens/interfaces/IWETH.sol";
import "../core/interfaces/IBrrrManager.sol";
import "../access/Governable.sol";

contract BrrrRewardRouter is IBrrrRewardRouter, ReentrancyGuard, Governable {
    using SafeTransferLib for *;

    bool public isInitialized;

    address public usdc;

    address public brrr; // PRINT3R Liquidity Provider token

    address public override stakedBrrrTracker;

    address public brrrManager;

    event StakeBrrr(address account, uint256 amount);
    event UnstakeBrrr(address account, uint256 amount);

    function initialize(address _usdc, address _brrr, address _stakedBrrrTracker, address _brrrManager)
        external
        override
        onlyGov
    {
        require(!isInitialized, "RewardRouter: already initialized");
        isInitialized = true;
        usdc = _usdc;
        brrr = _brrr;
        stakedBrrrTracker = _stakedBrrrTracker;
        brrrManager = _brrrManager;
    }

    function withdrawToken(address _token, address _account, uint256 _amount) external override onlyGov {
        IERC20(_token).safeTransfer(_account, _amount);
    }

    function mintAndStakeBrrr(uint256 _amount, uint256 _minUsdg, uint256 _minBrrr)
        external
        override
        nonReentrant
        returns (uint256)
    {
        require(_amount > 0, "RewardRouter: invalid _amount");

        address account = msg.sender;
        uint256 brrrAmount =
            IBrrrManager(brrrManager).addLiquidityForAccount(account, account, _amount, _minUsdg, _minBrrr);
        IRewardTracker(stakedBrrrTracker).stakeForAccount(account, account, brrr, brrrAmount);

        emit StakeBrrr(account, brrrAmount);

        return brrrAmount;
    }

    function unstakeAndRedeemBrrr(uint256 _brrrAmount, uint256 _minOut, address _receiver)
        external
        override
        nonReentrant
        returns (uint256)
    {
        require(_brrrAmount > 0, "RewardRouter: invalid _brrrAmount");

        address account = msg.sender;
        IRewardTracker(stakedBrrrTracker).unstakeForAccount(account, brrr, _brrrAmount, account);
        uint256 amountOut =
            IBrrrManager(brrrManager).removeLiquidityForAccount(account, _brrrAmount, _minOut, _receiver);

        emit UnstakeBrrr(account, _brrrAmount);

        return amountOut;
    }

    function claim() external override nonReentrant {
        address account = msg.sender;
        IRewardTracker(stakedBrrrTracker).claimForAccount(account, account);
    }

    function handleRewards() external override nonReentrant {
        address account = msg.sender;
        IRewardTracker(stakedBrrrTracker).claimForAccount(account, account);
    }
}
