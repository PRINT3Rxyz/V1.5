// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "lib/forge-std/src/Test.sol";
import {VaultPriceFeed} from "../../../src/core/VaultPriceFeed.sol";
import {FastPriceFeed} from "../../../src/oracle/FastPriceFeed.sol";
import {Vault} from "../../../src/core/Vault.sol";
import {Router} from "../../../src/core/Router.sol";
import {PositionManager} from "../../../src/core/PositionManager.sol";
import {PositionRouter} from "../../../src/core/PositionRouter.sol";
import {OrderBook} from "../../../src/core/OrderBook.sol";
import {BrrrManager} from "../../../src/core/BrrrManager.sol";
import {WBTC} from "../mocks/WBTC.sol";
import {WETH} from "../../../src/tokens/WETH.sol";
import {ReferralStorage} from "../../../src/referrals/ReferralStorage.sol";
import {BrrrRewardRouter} from "../../../src/staking/BrrrRewardRouter.sol";
import {RewardTracker} from "../../../src/staking/RewardTracker.sol";
import {Token} from "../../../src/tokens/Token.sol";
import {PythUtils} from "../../../src/oracle/PythUtils.sol";
import {IPyth} from "@pythnetwork/pyth-sdk-solidity/IPyth.sol";

contract ForkTest is Test {
    address public OWNER = 0x02A2012c36644f4e4b36A14EBe13E23c96f4C5b6;

    VaultPriceFeed priceFeed = VaultPriceFeed(0x3fF64d17B1b65A89D8c7ed0240beD6c4191eda96);
    FastPriceFeed fastPriceFeed = FastPriceFeed(0x569e68F301671680d846bc974C0BBbE5944538Ab);
    Vault vault = Vault(0x742B335B6404a8f1213701F1AA3b075cdDf443e2);
    Router router = Router(0xf834891aAcb4F4228f3E14cECd4d2a16d552FE9a);
    PositionManager positionManager = PositionManager(0x46e59FAb70ab762Df307f03362b923CD95B83515);
    PositionRouter positionRouter = PositionRouter(0x911996327087E75bD6315fbc6D9F78AfD200d723);
    OrderBook orderBook = OrderBook(0xf29De99c6D8Fc2a25d563E9059C956B64F7185F4);
    BrrrManager brrrManager = BrrrManager(0x016200397231c6610c508bd1a0C1F6c215Ed0102);
    ReferralStorage referralStorage = ReferralStorage(0xF178c60D91A35cD5d0b1915Fb390b1fE22E962c6);
    BrrrRewardRouter rewardRouter = BrrrRewardRouter(payable(0x04a34A4c15F11a307266A7fEd5322341E6A7c466));
    RewardTracker rewardTracker = RewardTracker(0xc945A2C8146E26Bc8103B0C2C2e1CD50E499c4F0);
    IPyth pyth = IPyth(0xA2aa501b19aff244D90cc15a4Cf739D2725B5729);

    address public wbtc = 0x078e58065D8F4614956F97703e8CCEA5929c2543;
    address payable weth = payable(0x8e57851FE2141ad6590c45cb27a1de5d3d42AeCA);
    address public usdc = 0x5F1102ca0eD7d01C8D9eDa72062D44E98d22B9d6;

    uint256 public deployerKey;

    uint256 public constant LARGE_AMOUNT = 1e30;
    uint256 public constant DEPOSIT_AMOUNT = 1e22;
    uint256 public constant SMALL_AMOUNT = 1e20;

    bytes[] updateData;

    receive() external payable {}

    function setUp() public {}

    modifier giveUserCurrency() {
        vm.deal(OWNER, LARGE_AMOUNT);
        vm.startPrank(OWNER);
        WBTC(wbtc).mint(OWNER, LARGE_AMOUNT);
        Token(usdc).mint(OWNER, LARGE_AMOUNT);
        vm.stopPrank();

        _;
    }

    function test_deployment() public view {
        console.log("Success");
    }

    function test_requesting_a_position_forked(uint256 _amountIn, uint256 _leverage, bool _isLong)
        public
        giveUserCurrency
    {
        _amountIn = bound(_amountIn, 10e6, 1_000_000_000e6); // 1 - 1 billion usdc
        _leverage = bound(_leverage, 1, 50); // 1 - 50
        vm.startPrank(OWNER);
        router.approvePlugin(address(positionRouter));
        Token(usdc).approve(address(router), _amountIn);
        positionRouter.createIncreasePosition{value: positionRouter.minExecutionFee()}(
            weth,
            _amountIn,
            0,
            _amountIn * _leverage * 1e24, // Conver USDC to USD
            _isLong,
            _isLong ? 3500e30 : 2500e30,
            positionRouter.minExecutionFee(),
            bytes32(0),
            address(0)
        );
        vm.stopPrank();
    }

    function test_executing_a_position_forked(uint256 _amountIn, uint256 _leverage, bool _isLong)
        public
        giveUserCurrency
    {
        _amountIn = bound(_amountIn, 10e6, 100_000e6); // 1 - 100k
        _leverage = bound(_leverage, 1, 40); // 1 - 40
        vm.startPrank(OWNER);
        router.approvePlugin(address(positionRouter));
        Token(usdc).approve(address(router), _amountIn);
        positionRouter.createIncreasePosition{value: positionRouter.minExecutionFee()}(
            weth,
            _amountIn,
            0,
            _amountIn * _leverage * 1e24, // Conver USDC to USD
            _isLong,
            _isLong ? 3500e30 : 2500e30,
            positionRouter.minExecutionFee(),
            bytes32(0),
            address(0)
        );
        vm.stopPrank();

        // Execute the position

        vm.prank(OWNER);
        positionRouter.executeIncreasePositions(1, payable(OWNER));

        // Check the position exists
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

        assertNotEq(size, 0, "Size is 0");
        assertNotEq(collateral, 0, "Collateral is 0");
    }

    function test_liquidation_a_position_that_goes_under_forked(uint256 _liquidationPrice, bool _isLong)
        public
        giveUserCurrency
    {
        if (_isLong) {
            _liquidationPrice = bound(_liquidationPrice, 100, 2500); // 0 - 3000
        } else {
            _liquidationPrice = bound(_liquidationPrice, 4000, 10_000); // 0 - 60000
        }
        vm.startPrank(OWNER);
        router.approvePlugin(address(positionRouter));
        Token(usdc).approve(address(router), 100_000e6);
        positionRouter.createIncreasePosition{value: positionRouter.minExecutionFee()}(
            weth,
            100_000e6,
            0,
            1_000_000e30,
            _isLong,
            _isLong ? 3500e30 : 2500e30,
            positionRouter.minExecutionFee(),
            bytes32(0),
            address(0)
        );
        vm.stopPrank();

        // Execute the position

        vm.prank(OWNER);
        positionRouter.executeIncreasePositions(1, payable(OWNER));
        int64 liqPrice = int64(uint64(_liquidationPrice));

        skip(180);

        // Move the price so that it's liquidatiable
        bytes memory ethPriceData = PythUtils.createPriceFeedUpdateData(
            bytes32(bytes("ETH")), liqPrice, 0, 0, liqPrice, 0, uint64(block.timestamp)
        );
        updateData[0] = ethPriceData;
        pyth.updatePriceFeeds(updateData);

        // Liquidate the position
        vm.prank(OWNER);
        positionManager.liquidatePosition(OWNER, weth, _isLong, OWNER);
    }
}
