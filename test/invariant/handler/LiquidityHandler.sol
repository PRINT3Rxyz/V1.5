// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
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
import {WBTC} from "../../mocks/WBTC.sol";
import {WETH} from "../../../src/tokens/WETH.sol";
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

contract LiquidityHandler is Test {
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

    constructor() {
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

    function add_liquidity(uint256 _amount, uint256 _btcPrice, uint256 _ethPrice) public {
        _amount = bound(_amount, 100000, DEPOSIT_AMOUNT);
        _btcPrice = bound(_btcPrice, 1, 100_000);
        _ethPrice = bound(_ethPrice, 1, 10_000);

        Token(usdc).mint(msg.sender, LARGE_AMOUNT);
        vm.deal(msg.sender, LARGE_AMOUNT);

        uint256 usdcBalBefore = Token(usdc).balanceOf(msg.sender);
        uint256 stakedBalBefore = rewardTracker.balanceOf(msg.sender);

        updateData[0] = pyth.createPriceFeedUpdateData(
            bytes32(bytes("ETH")), int64(uint64(_ethPrice)), 0, 0, int64(uint64(_ethPrice)), 0, uint64(block.timestamp)
        );
        updateData[1] = pyth.createPriceFeedUpdateData(
            bytes32(bytes("BTC")), int64(uint64(_btcPrice)), 0, 0, int64(uint64(_btcPrice)), 0, uint64(block.timestamp)
        );
        vm.prank(OWNER);
        pyth.updatePriceFeeds(updateData);

        vm.startPrank(msg.sender);
        Token(usdc).approve(address(brrrManager), _amount);
        rewardRouter.mintAndStakeBrrr(_amount, 0, 0);
        vm.stopPrank();

        uint256 usdcBalAfter = Token(usdc).balanceOf(msg.sender);
        uint256 stakedBalAfter = rewardTracker.balanceOf(msg.sender);
        assertEq(usdcBalBefore - usdcBalAfter, _amount);
        assertGt(stakedBalAfter, stakedBalBefore);
    }

    function remove_liquidity(uint256 _amount, uint256 _btcPrice, uint256 _ethPrice) public {
        uint256 rewardTrackerBalBefore = rewardTracker.balanceOf(msg.sender);
        if (rewardTrackerBalBefore == 0) return;

        _amount = bound(_amount, 1, rewardTrackerBalBefore);
        _btcPrice = bound(_btcPrice, 1, 100_000);
        _ethPrice = bound(_ethPrice, 1, 10_000);

        uint256 usdcBalBefore = Token(usdc).balanceOf(msg.sender);

        updateData[0] = pyth.createPriceFeedUpdateData(
            bytes32(bytes("ETH")), int64(uint64(_ethPrice)), 0, 0, int64(uint64(_ethPrice)), 0, uint64(block.timestamp)
        );
        updateData[1] = pyth.createPriceFeedUpdateData(
            bytes32(bytes("BTC")), int64(uint64(_btcPrice)), 0, 0, int64(uint64(_btcPrice)), 0, uint64(block.timestamp)
        );
        vm.prank(OWNER);
        pyth.updatePriceFeeds(updateData);

        vm.startPrank(msg.sender);
        rewardTracker.approve(address(brrrManager), rewardTrackerBalBefore);
        rewardRouter.unstakeAndRedeemBrrr(_amount, 0, msg.sender);
        vm.stopPrank();

        uint256 usdcBalAfter = Token(usdc).balanceOf(msg.sender);
        uint256 rewardTrackerBalAfter = rewardTracker.balanceOf(msg.sender);
        assertGt(usdcBalAfter, usdcBalBefore);
        assertEq(rewardTrackerBalBefore - rewardTrackerBalAfter, _amount);
    }
}
