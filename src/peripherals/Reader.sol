// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "../libraries/token/IERC20.sol";

import "../core/interfaces/IVaultPyth.sol";

contract Reader {
    uint256 public constant POSITION_PROPS_LENGTH = 9;

    function getFees(address _vault) public view returns (uint256) {
        return IVault(_vault).feeReserve();
    }

    function getFundingRates(address _vault, address _weth, address[] memory _tokens)
        public
        view
        returns (uint256[] memory)
    {
        uint256 propsLength = 4;
        uint256[] memory fundingRates = new uint256[](_tokens.length * propsLength);
        IVault vault = IVault(_vault);

        uint256 poolAmount = vault.poolAmount();
        uint256 fundingRateFactor = vault.fundingRateFactor();

        for (uint256 i; i < _tokens.length; i++) {
            address token = _tokens[i];
            if (token == address(0)) {
                token = _weth;
            }

            uint256 reservedAmountLong = vault.reservedAmounts(token, true);
            uint256 reservedAmountShort = vault.reservedAmounts(token, false);

            if (poolAmount > 0) {
                fundingRates[i * propsLength] = (fundingRateFactor * reservedAmountLong) / poolAmount;
                fundingRates[i * propsLength + 1] = (fundingRateFactor * reservedAmountShort) / poolAmount;
            }

            if (vault.cumulativeFundingRates(token, true) > 0) {
                uint256 nextRate = vault.getNextFundingRate(token, true);
                uint256 baseRate = vault.cumulativeFundingRates(token, true);
                fundingRates[i * propsLength + 2] = baseRate + nextRate;
            }

            if (vault.cumulativeFundingRates(token, false) > 0) {
                uint256 nextRate = vault.getNextFundingRate(token, false);
                uint256 baseRate = vault.cumulativeFundingRates(token, false);
                fundingRates[i * propsLength + 3] = baseRate + nextRate;
            }
        }

        return fundingRates;
    }

    function getTokenSupply(IERC20 _token, address[] memory _excludedAccounts) public view returns (uint256) {
        uint256 supply = _token.totalSupply();
        for (uint256 i; i < _excludedAccounts.length; i++) {
            address account = _excludedAccounts[i];
            uint256 balance = _token.balanceOf(account);
            supply -= balance;
        }
        return supply;
    }

    function getTotalBalance(IERC20 _token, address[] memory _accounts) public view returns (uint256) {
        uint256 totalBalance = 0;
        for (uint256 i = 0; i < _accounts.length; i++) {
            address account = _accounts[i];
            uint256 balance = _token.balanceOf(account);
            totalBalance += balance;
        }
        return totalBalance;
    }

    function getTokenBalances(address _account, address[] memory _tokens) public view returns (uint256[] memory) {
        uint256[] memory balances = new uint256[](_tokens.length);
        for (uint256 i = 0; i < _tokens.length; i++) {
            address token = _tokens[i];
            if (token == address(0)) {
                balances[i] = _account.balance;
                continue;
            }
            balances[i] = IERC20(token).balanceOf(_account);
        }
        return balances;
    }

    function getTokenBalancesWithSupplies(address _account, address[] memory _tokens)
        public
        view
        returns (uint256[] memory)
    {
        uint256 propsLength = 2;
        uint256[] memory balances = new uint256[](_tokens.length * propsLength);
        for (uint256 i = 0; i < _tokens.length; i++) {
            address token = _tokens[i];
            if (token == address(0)) {
                balances[i * propsLength] = _account.balance;
                balances[i * propsLength + 1] = 0;
                continue;
            }
            balances[i * propsLength] = IERC20(token).balanceOf(_account);
            balances[i * propsLength + 1] = IERC20(token).totalSupply();
        }
        return balances;
    }

    function getPositions(address _vault, address _account, address[] memory _indexTokens, bool[] memory _isLong)
        public
        view
        returns (uint256[] memory)
    {
        uint256[] memory amounts = new uint256[](_indexTokens.length * POSITION_PROPS_LENGTH);

        for (uint256 i = 0; i < _indexTokens.length; i++) {
            {
                (
                    uint256 size,
                    uint256 collateral,
                    uint256 averagePrice,
                    uint256 entryFundingRate,
                    /* reserveAmount */
                    ,
                    uint256 realisedPnl,
                    bool hasRealisedProfit,
                    uint256 lastIncreasedTime
                ) = IVault(_vault).getPosition(_account, _indexTokens[i], _isLong[i]);

                amounts[i * POSITION_PROPS_LENGTH] = size;
                amounts[i * POSITION_PROPS_LENGTH + 1] = collateral;
                amounts[i * POSITION_PROPS_LENGTH + 2] = averagePrice;
                amounts[i * POSITION_PROPS_LENGTH + 3] = entryFundingRate;
                amounts[i * POSITION_PROPS_LENGTH + 4] = hasRealisedProfit ? 1 : 0;
                amounts[i * POSITION_PROPS_LENGTH + 5] = realisedPnl;
                amounts[i * POSITION_PROPS_LENGTH + 6] = lastIncreasedTime;
            }

            uint256 size = amounts[i * POSITION_PROPS_LENGTH];
            uint256 averagePrice = amounts[i * POSITION_PROPS_LENGTH + 2];
            uint256 lastIncreasedTime = amounts[i * POSITION_PROPS_LENGTH + 6];
            if (averagePrice > 0) {
                (bool hasProfit, uint256 delta) =
                    IVault(_vault).getDelta(_indexTokens[i], size, averagePrice, _isLong[i], lastIncreasedTime);
                amounts[i * POSITION_PROPS_LENGTH + 7] = hasProfit ? 1 : 0;
                amounts[i * POSITION_PROPS_LENGTH + 8] = delta;
            }
        }

        return amounts;
    }
}
