// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "lib/forge-std/src/Test.sol";
import {HelperConfig} from "../../../script/HelperConfig.s.sol";
import {DeployP3} from "../../../script/DeployP3.s.sol";
import {Types} from "../../../script/Types.sol";
import {VaultPriceFeed} from "../../../src/core/VaultPriceFeed.sol";
import {FastPriceEvents} from "../../../src/oracle/FastPriceEvents.sol";
import {FastPriceFeed} from "../../../src/oracle/FastPriceFeed.sol";
import {Vault} from "../../../src/core/Vault.sol";
import {USDP} from "../../../src/tokens/USDP.sol";
import {Router} from "../../../src/core/Router.sol";
import {ShortsTracker} from "../../../src/core/ShortsTracker.sol";
import {PositionManager} from "../../../src/core/PositionManager.sol";
import {PositionRouter} from "../../../src/core/PositionRouter.sol";
import {OrderBook} from "../../../src/core/OrderBook.sol";
import {BRRR} from "../../../src/core/BRRR.sol";
import {BrrrManager} from "../../../src/core/BrrrManager.sol";
import {WBTC} from "../mocks/WBTC.sol";
import {WETH} from "../../../src/tokens/WETH.sol";
import {IERC20} from "../../../src/libraries/token/IERC20.sol";
import {ReferralStorage} from "../../../src/referrals/ReferralStorage.sol";
import {BrrrRewardRouter} from "../../../src/staking/BrrrRewardRouter.sol";
import {RewardTracker} from "../../../src/staking/RewardTracker.sol";
import {RewardDistributor} from "../../../src/staking/RewardDistributor.sol";
import {ReferralReader} from "../../../src/referrals/ReferralReader.sol";
import {Timelock} from "../../../src/peripherals/Timelock.sol";
import {OrderBookReader} from "../../../src/peripherals/OrderBookReader.sol";
import {VaultReader} from "../../../src/peripherals/VaultReader.sol";
import {RewardReader} from "../../../src/peripherals/RewardReader.sol";
import {TransferStakedBrrr} from "../../../src/staking/TransferStakedBrrr.sol";
import {BrrrBalance} from "../../../src/staking/BrrrBalance.sol";
import {Reader} from "../../../src/peripherals/Reader.sol";
import {Token} from "../../../src/tokens/Token.sol";
import {BrrrXpAmplifier} from "../../../src/staking/BrrrXpAmplifier.sol";
import {ShortsTrackerTimelock} from "../../../src/peripherals/ShortsTrackerTimelock.sol";
import {RewardClaimer} from "../../../src/staking/RewardClaimer.sol";

import {MockPyth} from "@pythnetwork/pyth-sdk-solidity/MockPyth.sol";

contract TestAccounting is Test {
    address public OWNER;
    address public USER = makeAddr("user");

    HelperConfig public helperConfig;
    Types.Contracts contracts;
    VaultPriceFeed priceFeed;
    FastPriceEvents priceEvents;
    FastPriceFeed fastPriceFeed;
    Vault vault;
    USDP usdp;
    Router router;
    ShortsTracker shortsTracker;
    PositionManager positionManager;
    PositionRouter positionRouter;
    OrderBook orderBook;
    BRRR brrr;
    BrrrManager brrrManager;
    ReferralStorage referralStorage;
    BrrrRewardRouter rewardRouter;
    RewardTracker rewardTracker;
    RewardDistributor rewardDistributor;
    Timelock timelock;
    TransferStakedBrrr transferStakedBrrr;
    BrrrBalance brrrBalance;
    OrderBookReader orderBookReader;
    VaultReader vaultReader;
    RewardReader rewardReader;
    ReferralReader referralReader;
    Reader reader;
    BrrrXpAmplifier amplifier;
    ShortsTrackerTimelock shortsTrackerTimelock;
    RewardClaimer rewardClaimer;
    MockPyth pyth;

    address public wbtc;
    address payable weth;
    address public usdc;
    address public wethUsdPriceFeed;
    address public wbtcUsdPriceFeed;
    address public usdcPriceFeed;

    uint256 public deployerKey;

    uint256 public constant LARGE_AMOUNT = 1e30;
    uint256 public constant DEPOSIT_AMOUNT = 1e22;
    uint256 public constant SMALL_AMOUNT = 1e20;

    bytes[] updateData;

    receive() external payable {}

    function setUp() public {
        DeployP3 deployScript = new DeployP3(); // Create a new instance of the DeployP3 script
        contracts = deployScript.run(); // Run the script and store the returned contracts
        OWNER = contracts.deployer;

        vm.deal(OWNER, 1e18 ether);

        vm.startPrank(OWNER);

        priceFeed = contracts.core.vaultPriceFeed;
        priceEvents = contracts.oracle.fastPriceEvents;
        fastPriceFeed = contracts.oracle.fastPriceFeed;
        vault = contracts.core.vault;
        usdp = contracts.tokens.usdp;
        router = contracts.core.router;
        shortsTracker = contracts.core.shortsTracker;
        orderBook = contracts.core.orderBook;
        positionManager = contracts.core.positionManager;
        positionRouter = contracts.core.positionRouter;
        brrr = contracts.core.brrr;
        brrrManager = contracts.core.brrrManager;
        referralStorage = contracts.referral.referralStorage;
        rewardRouter = contracts.staking.brrrRewardRouter;
        rewardTracker = contracts.staking.rewardTracker;
        rewardDistributor = contracts.staking.rewardDistributor;
        timelock = contracts.peripherals.timelock;
        transferStakedBrrr = contracts.staking.transferStakedBrrr;
        brrrBalance = contracts.staking.brrrBalance;
        orderBookReader = contracts.peripherals.orderBookReader;
        vaultReader = contracts.peripherals.vaultReader;
        rewardReader = contracts.peripherals.rewardReader;
        referralReader = contracts.referral.referralReader;
        reader = contracts.peripherals.reader;
        weth = contracts.tokens.weth;
        wbtc = contracts.tokens.wbtc;
        usdc = contracts.tokens.usdc;

        pyth = MockPyth(address(priceFeed.pyth()));

        console.log("Deployed contracts");

        WBTC(wbtc).mint(OWNER, LARGE_AMOUNT);
        WETH(weth).deposit{value: LARGE_AMOUNT}();
        Token(usdc).mint(OWNER, LARGE_AMOUNT);

        Token(usdc).approve(address(brrrManager), type(uint256).max);
        rewardRouter.mintAndStakeBrrr(DEPOSIT_AMOUNT, 0, 0);

        // Set USER to keeper
        positionRouter.setPositionKeeper(USER, true);

        // Create and set pyth prices for each token
        bytes memory ethPrice =
            pyth.createPriceFeedUpdateData(bytes32(bytes("ETH")), 3_000, 0, 0, 3_000, 0, uint64(block.timestamp));
        bytes memory btcPrice =
            pyth.createPriceFeedUpdateData(bytes32(bytes("BTC")), 60_000, 0, 0, 60_000, 0, uint64(block.timestamp));
        bytes memory usdcPrice =
            pyth.createPriceFeedUpdateData(bytes32(bytes("USDC")), 1, 0, 0, 1, 0, uint64(block.timestamp));

        updateData.push(ethPrice);
        updateData.push(btcPrice);
        updateData.push(usdcPrice);

        pyth.updatePriceFeeds(updateData);

        vm.stopPrank();
    }

    modifier giveUserCurrency() {
        vm.deal(OWNER, LARGE_AMOUNT);
        vm.deal(USER, 1e18 ether);
        vm.prank(USER);
        WETH(weth).deposit{value: LARGE_AMOUNT}();
        vm.startPrank(OWNER);
        WBTC(wbtc).mint(USER, LARGE_AMOUNT);
        Token(usdc).mint(USER, LARGE_AMOUNT);
        vm.stopPrank();

        _;
    }

    struct Accounting {
        uint256 feeReserve;
        uint256 tokenBalance;
        uint256 reservedAmount;
        uint256 totalReserved;
        uint256 globalSize;
        uint256 globalAveragePrice;
    }

    function test_vault_accounting_updates_for_positions(uint256 _amountIn, uint256 _leverage, bool _isLong)
        public
        giveUserCurrency
    {
        // store the vault accounting before
        Accounting memory accountingBefore;
        accountingBefore.feeReserve = vault.feeReserve();
        accountingBefore.tokenBalance = vault.tokenBalances(usdc);
        accountingBefore.reservedAmount = vault.reservedAmounts(weth, _isLong);
        accountingBefore.totalReserved = vault.totalReservedAmount();
        accountingBefore.globalSize = _isLong ? vault.globalLongSizes(weth) : vault.globalShortSizes(weth);
        accountingBefore.globalAveragePrice =
            _isLong ? vault.globalLongAveragePrices(weth) : vault.globalShortAveragePrices(weth);

        // create and execute a position
        _amountIn = bound(_amountIn, 10e6, 1_000_000_000e6); // 1 - 1 billion usdc
        _leverage = bound(_leverage, 1, 40); // 1 - 40
        vm.startPrank(OWNER);
        router.approvePlugin(address(positionRouter));
        Token(usdc).approve(address(router), _amountIn);
        uint256 sizeDelta = _amountIn * _leverage * 1e24;
        positionRouter.createIncreasePosition{value: positionRouter.minExecutionFee()}(
            weth,
            _amountIn,
            0,
            sizeDelta, // Convert USDC to USD
            _isLong,
            _isLong ? 3500e30 : 2500e30,
            positionRouter.minExecutionFee(),
            bytes32(0),
            address(0)
        );
        positionRouter.executeIncreasePositions(1, payable(OWNER));
        vm.stopPrank();

        // check the vault accounting after
        Accounting memory accountingAfter;
        accountingAfter.feeReserve = vault.feeReserve();
        accountingAfter.tokenBalance = vault.tokenBalances(usdc);
        accountingAfter.reservedAmount = vault.reservedAmounts(weth, _isLong);
        accountingAfter.totalReserved = vault.totalReservedAmount();
        accountingAfter.globalSize = _isLong ? vault.globalLongSizes(weth) : vault.globalShortSizes(weth);
        accountingAfter.globalAveragePrice =
            _isLong ? vault.globalLongAveragePrices(weth) : vault.globalShortAveragePrices(weth);

        // Get the position
        (
            uint256 size, // 0
            , // 1
            uint256 averagePrice, // 2
            , // 3
            , // 4
            , // 5
            , // 6
                // 7
        ) = vault.getPosition(OWNER, weth, _isLong);

        // Fee reserve should increase
        assertGt(accountingAfter.feeReserve, accountingBefore.feeReserve, "Fee reserve should increase");
        // Token balance should increase
        assertGt(accountingAfter.tokenBalance, accountingBefore.tokenBalance, "Token balance should increase");
        // Reserved amount should increase
        assertGt(accountingAfter.reservedAmount, accountingBefore.reservedAmount, "Reserved amount should increase");
        // Total reserved amount should increase
        assertGt(accountingAfter.totalReserved, accountingBefore.totalReserved, "Total reserved amount should increase");
        // Global size should increase
        assertEq(accountingAfter.globalSize, accountingBefore.globalSize + size, "Global size should increase");
        // Global average price should be updated
        assertEq(accountingAfter.globalAveragePrice, averagePrice, "Global average price should be updated");
    }

    function test_accounting_when_paying_profitable_positions(
        uint256 _amountIn,
        uint256 _leverage,
        uint256 _profitPrice,
        bool _isLong
    ) public giveUserCurrency {
        // create and execute a position
        _amountIn = bound(_amountIn, 10e6, 1_000_000e6); // 1 - 1 million usdc
        _leverage = bound(_leverage, 1, 40); // 1 - 40
        vm.startPrank(OWNER);
        router.approvePlugin(address(positionRouter));
        Token(usdc).approve(address(router), _amountIn);
        uint256 sizeDelta = _amountIn * _leverage * 1e24;
        positionRouter.createIncreasePosition{value: positionRouter.minExecutionFee()}(
            weth,
            _amountIn,
            0,
            sizeDelta, // Convert USDC to USD
            _isLong,
            _isLong ? 3500e30 : 2500e30,
            positionRouter.minExecutionFee(),
            bytes32(0),
            address(0)
        );
        positionRouter.executeIncreasePositions(1, payable(OWNER));
        vm.stopPrank();

        // Get the position
        (
            uint256 size, // 0
            uint256 collateral, // 1
            , // 2
            , // 3
            , // 4
            , // 5
            , // 6
                // 7
        ) = vault.getPosition(OWNER, weth, _isLong);
        // Collateral has 30 Dp --> to convert to USDC need to divide by 1e24
        uint256 collateralUsdc = collateral / 1e24;

        // Move the price so that the position is profitable
        int64 profitPrice;
        if (_isLong) {
            _profitPrice = bound(_profitPrice, 3500, 10_000); // $3500 - $10,000
            profitPrice = int64(uint64(_profitPrice));
        } else {
            _profitPrice = bound(_profitPrice, 1000, 2500); // $100 - $2500
            profitPrice = int64(uint64(_profitPrice));
        }

        skip(180);

        bytes memory ethPriceData = pyth.createPriceFeedUpdateData(
            bytes32(bytes("ETH")), profitPrice, 0, 0, profitPrice, 0, uint64(block.timestamp)
        );

        updateData[0] = ethPriceData;
        pyth.updatePriceFeeds(updateData);

        uint256 balanceBeforeDecrease = IERC20(usdc).balanceOf(OWNER);
        uint256 tokenBalanceBefore = vault.tokenBalances(usdc);

        // Create a decrease position request
        uint256 acceptablePrice = _isLong ? (_profitPrice * 1e30) * 9 / 10 : (_profitPrice * 1e30) * 11 / 10;
        vm.startPrank(OWNER);
        positionRouter.createDecreasePosition{value: positionRouter.minExecutionFee()}(
            weth, 0, size, _isLong, OWNER, acceptablePrice, 0, positionRouter.minExecutionFee(), address(0)
        );
        // Execute the decrease position
        positionRouter.executeDecreasePositions(1, payable(OWNER));
        vm.stopPrank();

        uint256 tokenBalanceAfter = vault.tokenBalances(usdc);
        uint256 balanceDelta = IERC20(usdc).balanceOf(OWNER) - balanceBeforeDecrease;
        // User should receive more than their collateral as a result of profit.
        assertGt(balanceDelta, collateralUsdc);
        assertEq(tokenBalanceBefore - tokenBalanceAfter, balanceDelta);
    }
}
