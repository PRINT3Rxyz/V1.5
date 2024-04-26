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

contract PositionHandler is Test {
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

    mapping(address user => mapping(address indexToken => bool)) positionCreated;

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

    function create_increase_position(
        uint256 _amountIn,
        uint256 _leverage,
        uint256 _btcPrice,
        uint256 _ethPrice,
        bool _isLong
    ) public {
        _amountIn = bound(_amountIn, 10e6, 1_000_000e6); // 1 - 1 billion usdc
        _leverage = bound(_leverage, 1, 50); // 1 - 50
        Token(usdc).mint(msg.sender, LARGE_AMOUNT);
        vm.deal(msg.sender, LARGE_AMOUNT);
        vm.startPrank(msg.sender);
        router.approvePlugin(address(positionRouter));
        Token(usdc).approve(address(router), _amountIn);
        address indexToken = _amountIn % 2 == 0 ? wbtc : weth;
        // Get the current price --> if is long, add a percentage, if short, subtract a percentage
        uint256 tokenPrice = priceFeed.getPrimaryPrice(indexToken, true);
        positionRouter.createIncreasePosition{value: positionRouter.minExecutionFee()}(
            indexToken,
            _amountIn,
            0,
            _amountIn * _leverage * 1e24, // Convert USDC to USD
            _isLong,
            _isLong ? (tokenPrice * 12) / 10 : (tokenPrice * 8) / 10,
            positionRouter.minExecutionFee(),
            bytes32(0),
            address(0)
        );
        vm.stopPrank();

        positionCreated[msg.sender][indexToken] = true;

        /**
         *  ========= Execution =========
         */
        _btcPrice = bound(_btcPrice, 1, 100_000);
        _ethPrice = bound(_ethPrice, 1, 10_000);
        updateData[0] = pyth.createPriceFeedUpdateData(
            bytes32(bytes("ETH")), int64(uint64(_ethPrice)), 0, 0, int64(uint64(_ethPrice)), 0, uint64(block.timestamp)
        );
        updateData[1] = pyth.createPriceFeedUpdateData(
            bytes32(bytes("BTC")), int64(uint64(_btcPrice)), 0, 0, int64(uint64(_btcPrice)), 0, uint64(block.timestamp)
        );
        vm.prank(OWNER);
        fastPriceFeed.setPricesAndExecute(
            address(positionRouter),
            updateData,
            positionRouter.increasePositionRequestKeysStart() + 100,
            positionRouter.decreasePositionRequestKeysStart() + 100,
            1000,
            1000
        );

        // Assert the position has been opened

        (uint256 size,,,,,,,) = vault.getPosition(msg.sender, indexToken, _isLong);
        assertNotEq(size, 0, "Size is 0");
    }

    function create_decrease_position(
        uint256 _sizeDelta,
        uint256 _btcPrice,
        uint256 _ethPrice,
        bool _isLong,
        bool _isBtc
    ) public {
        // only continue if they have an open position
        address indexToken = _isBtc ? wbtc : weth;
        if (!positionCreated[msg.sender][indexToken]) {
            return;
        }
        // get the position
        (uint256 size,,,,,,,) = vault.getPosition(msg.sender, indexToken, _isLong);
        // bound the size delta
        _sizeDelta = bound(_sizeDelta, 1e30, size);
        // bound prices
        _btcPrice = bound(_btcPrice, 1, 100_000);
        _ethPrice = bound(_ethPrice, 1, 10_000);
        // if > 99% decrease, set to 100%
        if (_sizeDelta > (99 * size) / 100) _sizeDelta = size;
        Token(usdc).mint(msg.sender, LARGE_AMOUNT);
        vm.deal(msg.sender, LARGE_AMOUNT);
        vm.startPrank(msg.sender);
        router.approvePlugin(address(positionRouter));

        uint256 acceptablePrice;
        if (_isLong) {
            if (_isBtc) {
                acceptablePrice = (_btcPrice * 8) / 10;
            } else {
                acceptablePrice = (_ethPrice * 8) / 10;
            }
        } else {
            if (_isBtc) {
                acceptablePrice = (_btcPrice * 12) / 10;
            } else {
                acceptablePrice = (_ethPrice * 12) / 10;
            }
        }
        positionRouter.createDecreasePosition{value: positionRouter.minExecutionFee()}(
            indexToken,
            0,
            _sizeDelta,
            _isLong,
            msg.sender,
            acceptablePrice,
            0,
            positionRouter.minExecutionFee(),
            address(0)
        );

        /**
         *  ========= Execution =========
         */
        updateData[0] = pyth.createPriceFeedUpdateData(
            bytes32(bytes("ETH")), int64(uint64(_ethPrice)), 0, 0, int64(uint64(_ethPrice)), 0, uint64(block.timestamp)
        );
        updateData[1] = pyth.createPriceFeedUpdateData(
            bytes32(bytes("BTC")), int64(uint64(_btcPrice)), 0, 0, int64(uint64(_btcPrice)), 0, uint64(block.timestamp)
        );
        vm.prank(OWNER);
        fastPriceFeed.setPricesAndExecute(
            address(positionRouter),
            updateData,
            positionRouter.increasePositionRequestKeysStart() + 100,
            positionRouter.decreasePositionRequestKeysStart() + 100,
            1000,
            1000
        );

        // Assert the position has been opened
        (uint256 sizeAfter,,,,,,,) = vault.getPosition(msg.sender, indexToken, _isLong);
        assertEq(sizeAfter, size - _sizeDelta, "Size is not correct");
    }
}
