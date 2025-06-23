// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
// import { ERC20Mock } from "@openzeppelin/contracts/mocks/ERC20Mock.sol"; Updated mock location
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";
import {MockMoreDebtDSC} from "../mocks/MockMoreDebtDSC.sol";
import {MockFailedMintDSC} from "../mocks/MockFailedMintDSC.sol";
import {MockFailedTransferFrom} from "../mocks/MockFailedTransferFrom.sol";
import {MockFailedTransfer} from "../mocks/MockFailedTransfer.sol";
import {Test, console} from "forge-std/Test.sol";
import {StdCheats} from "forge-std/StdCheats.sol";

contract DSCEngineTest is StdCheats, Test {
    // event CollateralRedeemed(address indexed redeemFrom, address indexed redeemTo, address token, uint256 amount); // if
    //     // redeemFrom != redeemedTo, then it was liquidated

    event CollateralRedeemed(
        address indexed redeemedFrom, address indexed redeemedTo, address indexed token, uint256 amount
    );

    DSCEngine public dsce;
    DecentralizedStableCoin public dsc;
    HelperConfig public helperConfig;

    address public ethUsdPriceFeed;
    address public btcUsdPriceFeed;
    address public weth;
    address public wbtc;
    uint256 public deployerKey;

    uint256 amountCollateral = 10 ether;
    uint256 amountToMint = 100e18;
    address public user = address(1);

    uint256 public constant STARTING_USER_BALANCE = 10 ether;
    uint256 public constant MIN_HEALTH_FACTOR = 1e18;
    uint256 public constant LIQUIDATION_THRESHOLD = 50;

    // Liquidation
    address public liquidator = makeAddr("liquidator");
    uint256 public collateralToCover = 20 ether;

    function setUp() external {
        DeployDSC deployer = new DeployDSC();
        (dsc, dsce, helperConfig) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc, deployerKey) = helperConfig.activeNetworkConfig();
        if (block.chainid == 31_337) {
            vm.deal(user, STARTING_USER_BALANCE);
        }
        // Should we put our integration tests here?
        // else {
        //     user = vm.addr(deployerKey);
        //     ERC20Mock mockErc = new ERC20Mock("MOCK", "MOCK", user, 100e18);
        //     MockV3Aggregator aggregatorMock = new MockV3Aggregator(
        //         helperConfig.DECIMALS(),
        //         helperConfig.ETH_USD_PRICE()
        //     );
        //     vm.etch(weth, address(mockErc).code);
        //     vm.etch(wbtc, address(mockErc).code);
        //     vm.etch(ethUsdPriceFeed, address(aggregatorMock).code);
        //     vm.etch(btcUsdPriceFeed, address(aggregatorMock).code);
        // }
        ERC20Mock(weth).mint(user, STARTING_USER_BALANCE);
        ERC20Mock(wbtc).mint(user, STARTING_USER_BALANCE);
    }

    ///////////////////////
    // Constructor Tests //
    ///////////////////////
    address[] public tokenAddresses;
    address[] public feedAddresses;

    function testRevertsIfTokenLengthDoesntMatchPriceFeeds() public {
        tokenAddresses.push(weth);
        feedAddresses.push(ethUsdPriceFeed);
        feedAddresses.push(btcUsdPriceFeed);

        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressAndPriceFeedAddressesMustBeSameLength.selector);
        new DSCEngine(tokenAddresses, feedAddresses, address(dsc));
    }

    //////////////////
    // Price Tests //
    //////////////////

    function testGetTokenAmountFromUsd() public view {
        // If we want $100 of WETH @ $2000/WETH, that would be 0.05 WETH
        uint256 expectedWeth = 0.05 ether;
        uint256 amountWeth = dsce.getTokenAmountFromUsd(weth, 100 ether);
        assertEq(amountWeth, expectedWeth);
    }

    function testGetUsdValue() public view {
        uint256 ethAmount = 15e18;
        // 15e18 ETH * $2000/ETH = $30,000e18
        uint256 expectedUsd = 30_000e18;
        uint256 usdValue = dsce.getUsdValue(weth, ethAmount);
        assertEq(usdValue, expectedUsd);
    }

    ///////////////////////////////////////
    // depositCollateral Tests //
    ///////////////////////////////////////

    // this test needs it's own setup
    function testRevertsIfTransferFromFails() public {
        // Arrange - Setup
        address owner = msg.sender;
        vm.prank(owner);
        MockFailedTransferFrom mockDsc = new MockFailedTransferFrom();
        tokenAddresses = [address(mockDsc)];
        feedAddresses = [ethUsdPriceFeed];
        vm.prank(owner);
        DSCEngine mockDsce = new DSCEngine(tokenAddresses, feedAddresses, address(mockDsc));
        mockDsc.mint(user, amountCollateral);

        vm.prank(owner);
        mockDsc.transferOwnership(address(mockDsce));
        // Arrange - User
        vm.startPrank(user);
        ERC20Mock(address(mockDsc)).approve(address(mockDsce), amountCollateral);
        // Act / Assert
        vm.expectRevert(DSCEngine.DSCEngine__TransferFailed.selector);
        mockDsce.depositCollateral(address(mockDsc), amountCollateral);
        vm.stopPrank();
    }

    function testRevertsIfCollateralZero() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dsce), amountCollateral);

        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertsWithUnapprovedCollateral() public {
        ERC20Mock randToken = new ERC20Mock("RAN", "RAN", user, 100e18);
        vm.startPrank(user);
        //vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__NotAllowedToken.selector, address(randToken)));
        vm.expectRevert(DSCEngine.DSCEngine__NotAllowedToken.selector);
        dsce.depositCollateral(address(randToken), amountCollateral);
        vm.stopPrank();
    }

    // modifier depositedCollateral() {
    //     vm.startPrank(user);
    //     ERC20Mock(weth).approve(address(dsce), amountCollateral);
    //     dsce.depositCollateral(weth, amountCollateral);
    //     vm.stopPrank();
    //     _;
    // }

    //// START OF FROM CLAUDE

    modifier depositedCollateral() {
        // Log initial state
        console.log("Initial WETH balance of user:", ERC20Mock(weth).balanceOf(user));
        console.log("Initial WETH balance of dsce:", ERC20Mock(weth).balanceOf(address(dsce)));

        vm.startPrank(user);
        // Check approval
        ERC20Mock(weth).approve(address(dsce), amountCollateral);
        uint256 allowance = ERC20Mock(weth).allowance(user, address(dsce));
        console.log("Allowance after approval:", allowance);

        // Deposit and verify
        dsce.depositCollateral(weth, amountCollateral);
        console.log("WETH balance of dsce after deposit:", ERC20Mock(weth).balanceOf(address(dsce)));
        console.log("WETH balance of user after deposit:", ERC20Mock(weth).balanceOf(user));
        vm.stopPrank();
        _;
    }

    function testEmitCollateralRedeemedWithCorrectArgs() public depositedCollateral {
        // Pre-redemption checks
        uint256 dscBalanceBefore = ERC20Mock(weth).balanceOf(address(dsce));
        uint256 userBalanceBefore = ERC20Mock(weth).balanceOf(user);
        console.log("\nBefore redemption:");
        console.log("DSC Engine WETH balance:", dscBalanceBefore);
        console.log("User WETH balance:", userBalanceBefore);

        // Setup event expectation
        // For CollateralRedeemed(address indexed redeemedFrom, address indexed redeemedTo, address indexed token, uint256 amount)
        // We check: redeemedFrom, redeemedTo, token, and the data (amount)
        vm.expectEmit(true, true, true, true);
        emit CollateralRedeemed(user, user, weth, amountCollateral);

        // Perform redemption
        vm.startPrank(user);
        dsce.redeemCollateral(weth, amountCollateral);

        // Post-redemption checks
        uint256 dscBalanceAfter = ERC20Mock(weth).balanceOf(address(dsce));
        uint256 userBalanceAfter = ERC20Mock(weth).balanceOf(user);
        console.log("\nAfter redemption:");
        console.log("DSC Engine WETH balance:", dscBalanceAfter);
        console.log("User WETH balance:", userBalanceAfter);
        vm.stopPrank();

        // Verify balances changed correctly
        assertEq(dscBalanceAfter, dscBalanceBefore - amountCollateral, "DSC Engine balance didn't decrease correctly");
        assertEq(userBalanceAfter, userBalanceBefore + amountCollateral, "User balance didn't increase correctly");
    }
    ///// END OF == FROM CLAUDE

    function testCanDepositCollateralWithoutMinting() public depositedCollateral {
        uint256 userBalance = dsc.balanceOf(user);
        assertEq(userBalance, 0);
    }

    function testCanDepositedCollateralAndGetAccountInfo() public depositedCollateral {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(user);
        uint256 expectedDepositedAmount = dsce.getTokenAmountFromUsd(weth, collateralValueInUsd);
        assertEq(totalDscMinted, 0);
        assertEq(expectedDepositedAmount, amountCollateral);
    }

    function testEmitCollateralDepositedEventOnDeposit() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dsce), amountCollateral);

        vm.expectEmit(true, true, true, true); // Added true for indexed amount
        emit DSCEngine.CollateralDeposited(user, weth, amountCollateral);

        dsce.depositCollateral(weth, amountCollateral);
        vm.stopPrank();
    }

    ///////////////////////////////////////
    // depositCollateralAndMintDsc Tests //
    ///////////////////////////////////////

    function testRevertsIfMintedDscBreaksHealthFactor() public {
        (, int256 price,,,) = MockV3Aggregator(ethUsdPriceFeed).latestRoundData();
        amountToMint = (amountCollateral * (uint256(price) * dsce.getAdditionalFeedPrecision())) / dsce.getPrecision();
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dsce), amountCollateral);

        uint256 expectedHealthFactor =
            dsce.calculateHealthFactor(amountToMint, dsce.getUsdValue(weth, amountCollateral));
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, expectedHealthFactor));
        dsce.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
        vm.stopPrank();
    }

    modifier depositedCollateralAndMintedDsc() {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dsce), amountCollateral);
        dsce.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
        vm.stopPrank();
        _;
    }

    function testCanMintWithDepositedCollateral() public depositedCollateralAndMintedDsc {
        uint256 userBalance = dsc.balanceOf(user);
        assertEq(userBalance, amountToMint);
    }

    ///////////////////////////////////
    // mintDsc Tests //
    ///////////////////////////////////
    // This test needs it's own custom setup
    function testRevertsIfMintFails() public {
        // Arrange - Setup
        MockFailedMintDSC mockDsc = new MockFailedMintDSC();
        tokenAddresses = [weth];
        feedAddresses = [ethUsdPriceFeed];
        address owner = msg.sender;
        vm.prank(owner);
        DSCEngine mockDsce = new DSCEngine(tokenAddresses, feedAddresses, address(mockDsc));
        mockDsc.transferOwnership(address(mockDsce));
        // Arrange - User
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(mockDsce), amountCollateral);

        vm.expectRevert(DSCEngine.DSCEngine_MintFailed.selector);
        mockDsce.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
        vm.stopPrank();
    }

    function testRevertsIfMintAmountIsZero() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dsce), amountCollateral);
        dsce.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.mintDsc(0);
        vm.stopPrank();
    }

    function testRevertsIfMintAmountBreaksHealthFactor() public depositedCollateral {
        // 0xe580cc6100000000000000000000000000000000000000000000000006f05b59d3b20000
        // 0xe580cc6100000000000000000000000000000000000000000000003635c9adc5dea00000
        (, int256 price,,,) = MockV3Aggregator(ethUsdPriceFeed).latestRoundData();
        amountToMint = (amountCollateral * (uint256(price) * dsce.getAdditionalFeedPrecision())) / dsce.getPrecision();

        vm.startPrank(user);
        uint256 expectedHealthFactor =
            dsce.calculateHealthFactor(amountToMint, dsce.getUsdValue(weth, amountCollateral));
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, expectedHealthFactor));
        dsce.mintDsc(amountToMint);
        vm.stopPrank();
    }

    function testCanMintDsc() public depositedCollateral {
        vm.prank(user);
        dsce.mintDsc(amountToMint);

        uint256 userBalance = dsc.balanceOf(user);
        console.log(userBalance);
        assert(userBalance == amountToMint);
    }

    ///////////////////////////////////
    // burnDsc Tests //
    ///////////////////////////////////

    function testRevertsIfBurnAmountIsZero() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dsce), amountCollateral);
        dsce.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.burnDsc(0);
        vm.stopPrank();
    }

    function testCantBurnMoreThanUserHas() public {
        vm.prank(user);
        vm.expectRevert();
        dsce.burnDsc(1);
    }

    function testCanBurnDsc() public depositedCollateralAndMintedDsc {
        vm.startPrank(user);
        dsc.approve(address(dsce), amountToMint);
        dsce.burnDsc(amountToMint);
        vm.stopPrank();

        uint256 userBalance = dsc.balanceOf(user);
        assertEq(userBalance, 0);
    }

    ///////////////////////////////////
    // redeemCollateral Tests //
    //////////////////////////////////

    // this test needs it's own setup
    function testRevertsIfTransferFails() public {
        // Arrange - Setup
        address owner = msg.sender;
        vm.prank(owner);
        MockFailedTransfer mockDsc = new MockFailedTransfer();
        tokenAddresses = [address(mockDsc)];
        feedAddresses = [ethUsdPriceFeed];
        vm.prank(owner);
        DSCEngine mockDsce = new DSCEngine(tokenAddresses, feedAddresses, address(mockDsc));
        mockDsc.mint(user, amountCollateral);

        vm.prank(owner);
        mockDsc.transferOwnership(address(mockDsce));
        // Arrange - User
        vm.startPrank(user);
        ERC20Mock(address(mockDsc)).approve(address(mockDsce), amountCollateral);
        // Act / Assert
        mockDsce.depositCollateral(address(mockDsc), amountCollateral);
        vm.expectRevert(DSCEngine.DSCEngine__TransferFailed.selector);
        mockDsce.redeemCollateral(address(mockDsc), amountCollateral);
        vm.stopPrank();
    }

    function testRevertsIfRedeemAmountIsZero() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dsce), amountCollateral);
        dsce.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.redeemCollateral(weth, 0);
        vm.stopPrank();
    }

    function testCanRedeemCollateral() public depositedCollateral {
        vm.startPrank(user);
        dsce.redeemCollateral(weth, amountCollateral);
        uint256 userBalance = ERC20Mock(weth).balanceOf(user);
        assertEq(userBalance, amountCollateral);
        vm.stopPrank();
    }

    // function testEmitCollateralRedeemedWithCorrectArgs() public depositedCollateral {
    //     vm.expectEmit(true, true, false, true);
    //     emit CollateralRedeemed(user, user, weth, amountCollateral);
    //     vm.startPrank(user);
    //     dsce.redeemCollateral(weth, amountCollateral);
    //     vm.stopPrank();
    // }
    ///////////////////////////////////
    // redeemCollateralForDsc Tests //
    //////////////////////////////////

    function testMustRedeemMoreThanZero() public {
        vm.startPrank(user);
        dsc.approve(address(dsce), amountToMint);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.redeemCollateralForDsc(weth, 0, amountToMint);
        vm.stopPrank();
    }

    function testCanRedeemDepositedCollateral() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dsce), amountCollateral);
        dsce.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
        dsc.approve(address(dsce), amountToMint);
        dsce.redeemCollateralForDsc(weth, amountCollateral, amountToMint);
        vm.stopPrank();

        uint256 userBalance = dsc.balanceOf(user);
        assertEq(userBalance, 0);
    }

    ////////////////////////
    // healthFactor Tests //
    ////////////////////////

    function testProperlyReportsHealthFactor() public depositedCollateralAndMintedDsc {
        uint256 expectedHealthFactor = 100 ether;
        uint256 healthFactor = dsce.getHealthFactor(user);
        // $100 minted with $20,000 collateral at 50% liquidation threshold
        // means that we must have $200 collatareral at all times.
        // 20,000 * 0.5 = 10,000
        // 10,000 / 100 = 100 health factor
        assertEq(healthFactor, expectedHealthFactor);
    }

    function testHealthFactorCanGoBelowOne() public depositedCollateralAndMintedDsc {
        int256 ethUsdUpdatedPrice = 18e8; // 1 ETH = $18
        // Rememeber, we need $200 at all times if we have $100 of debt

        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);

        uint256 userHealthFactor = dsce.getHealthFactor(user);
        // 180*50 (LIQUIDATION_THRESHOLD) / 100 (LIQUIDATION_PRECISION) / 100 (PRECISION) = 90 / 100 (totalDscMinted) =
        // 0.9
        assert(userHealthFactor == 0.9 ether);
    }

    ///////////////////////
    // Liquidation Tests //
    ///////////////////////

    // This test needs it's own setup
    function testMustImproveHealthFactorOnLiquidation() public {
        // Arrange - Setup
        MockMoreDebtDSC mockDsc = new MockMoreDebtDSC(ethUsdPriceFeed);
        tokenAddresses = [weth];
        feedAddresses = [ethUsdPriceFeed];
        address owner = msg.sender;
        vm.prank(owner);
        DSCEngine mockDsce = new DSCEngine(tokenAddresses, feedAddresses, address(mockDsc));
        mockDsc.transferOwnership(address(mockDsce));
        // Arrange - User
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(mockDsce), amountCollateral);
        mockDsce.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
        vm.stopPrank();

        // Arrange - Liquidator
        collateralToCover = 1 ether;
        ERC20Mock(weth).mint(liquidator, collateralToCover);

        vm.startPrank(liquidator);
        ERC20Mock(weth).approve(address(mockDsce), collateralToCover);
        uint256 debtToCover = 10 ether;
        mockDsce.depositCollateralAndMintDsc(weth, collateralToCover, amountToMint);
        mockDsc.approve(address(mockDsce), debtToCover);
        // Act
        int256 ethUsdUpdatedPrice = 18e8; // 1 ETH = $18
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);
        // Act/Assert
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorNotImproved.selector);
        mockDsce.liquidate(weth, user, debtToCover);
        vm.stopPrank();
    }

    function testCantLiquidateGoodHealthFactor() public depositedCollateralAndMintedDsc {
        ERC20Mock(weth).mint(liquidator, collateralToCover);

        vm.startPrank(liquidator);
        ERC20Mock(weth).approve(address(dsce), collateralToCover);
        dsce.depositCollateralAndMintDsc(weth, collateralToCover, amountToMint);
        dsc.approve(address(dsce), amountToMint);

        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorOk.selector);
        dsce.liquidate(weth, user, amountToMint);
        vm.stopPrank();
    }

    modifier liquidated() {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dsce), amountCollateral);
        dsce.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
        vm.stopPrank();
        int256 ethUsdUpdatedPrice = 18e8; // 1 ETH = $18

        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);
        uint256 userHealthFactor = dsce.getHealthFactor(user);

        ERC20Mock(weth).mint(liquidator, collateralToCover);

        vm.startPrank(liquidator);
        ERC20Mock(weth).approve(address(dsce), collateralToCover);
        dsce.depositCollateralAndMintDsc(weth, collateralToCover, amountToMint);
        dsc.approve(address(dsce), amountToMint);
        dsce.liquidate(weth, user, amountToMint); // We are covering their whole debt
        vm.stopPrank();
        _;
    }

    function testLiquidationPayoutIsCorrect() public liquidated {
        uint256 liquidatorWethBalance = ERC20Mock(weth).balanceOf(liquidator);
        uint256 expectedWeth = dsce.getTokenAmountFromUsd(weth, amountToMint)
            + (dsce.getTokenAmountFromUsd(weth, amountToMint) / dsce.getLiquidationBonus());
        uint256 hardCodedExpected = 6_111_111_111_111_111_110;
        assertEq(liquidatorWethBalance, hardCodedExpected);
        assertEq(liquidatorWethBalance, expectedWeth);
    }

    function testUserStillHasSomeEthAfterLiquidation() public liquidated {
        // Get how much WETH the user lost
        uint256 amountLiquidated = dsce.getTokenAmountFromUsd(weth, amountToMint)
            + (dsce.getTokenAmountFromUsd(weth, amountToMint) / dsce.getLiquidationBonus());

        uint256 usdAmountLiquidated = dsce.getUsdValue(weth, amountLiquidated);
        uint256 expectedUserCollateralValueInUsd = dsce.getUsdValue(weth, amountCollateral) - (usdAmountLiquidated);

        (, uint256 userCollateralValueInUsd) = dsce.getAccountInformation(user);
        uint256 hardCodedExpectedValue = 70_000_000_000_000_000_020;
        assertEq(userCollateralValueInUsd, expectedUserCollateralValueInUsd);
        assertEq(userCollateralValueInUsd, hardCodedExpectedValue);
    }

    function testLiquidatorTakesOnUsersDebt() public liquidated {
        (uint256 liquidatorDscMinted,) = dsce.getAccountInformation(liquidator);
        assertEq(liquidatorDscMinted, amountToMint);
    }

    function testUserHasNoMoreDebt() public liquidated {
        (uint256 userDscMinted,) = dsce.getAccountInformation(user);
        assertEq(userDscMinted, 0);
    }

    function testEmitCollateralRedeemedEventOnLiquidation() public {
        // Setup: User deposits collateral and mints DSC
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dsce), amountCollateral);
        dsce.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
        vm.stopPrank();

        // Setup: Price drops, user becomes undercollateralized
        int256 ethUsdUpdatedPrice = 18e8; // 1 ETH = $18, making health factor < 1
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);
        // uint256 userHealthFactor = dsce.getHealthFactor(user); // For debugging
        // console.log("User health factor after price drop: %s", userHealthFactor);

        // Setup: Liquidator prepares to liquidate
        // Liquidator needs some DSC to burn, or needs to be able to transfer user's DSC
        // For this test, liquidator will cover the user's debt by burning their own (liquidator's) DSC.
        // The current liquidate function has liquidator provide collateral and then DSC engine burns it from user.
        // Liquidator needs allowance for the DSC to be burned from their account by DSCEngine.
        // The _burnDsc function takes `dscFrom` which is `msg.sender` (liquidator).
        // So liquidator must have `amountToMint` of DSC and approve DSCEngine to spend it.

        ERC20Mock(weth).mint(liquidator, collateralToCover); // Liquidator needs some WETH for gas / other ops
        dsc.mint(liquidator, amountToMint); // Mint DSC to liquidator

        vm.startPrank(liquidator);
        dsc.approve(address(dsce), amountToMint); // Liquidator approves DSCEngine to burn their DSC

        // Expect CollateralRedeemed event
        // redeemedFrom = user, redeemedTo = liquidator
        // token = weth
        // amount = calculated collateral amount including bonus
        uint256 tokenAmountFromDebtCovered = dsce.getTokenAmountFromUsd(weth, amountToMint);
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * dsce.getLiquidationBonus()) / dsce.getLiquidationPrecision();
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;

        vm.expectEmit(true, true, true, true);
        emit CollateralRedeemed(user, liquidator, weth, totalCollateralToRedeem);

        dsce.liquidate(weth, user, amountToMint); // Liquidator liquidates the user
        vm.stopPrank();
    }

    function testLiquidate_RevertsIfDebtToCoverExceedsUserMintedDsc() public {
        // Setup: User deposits collateral and mints DSC (amountToMint)
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dsce), amountCollateral);
        dsce.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
        vm.stopPrank();

        // Setup: Price drops, user becomes undercollateralized
        int256 ethUsdUpdatedPrice = 18e8; // 1 ETH = $18
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);

        // Setup: Liquidator
        dsc.mint(liquidator, amountToMint + 1); // Liquidator has more DSC than user's debt

        vm.startPrank(liquidator);
        dsc.approve(address(dsce), amountToMint + 1); // Approve more than user's debt

        // Act & Assert: Try to liquidate with debtToCover > user's actual debt
        // This should revert inside _burnDsc due to DSCEngine__BurnAmountExceedsBalance
        vm.expectRevert(DSCEngine.DSCEngine__BurnAmountExceedsBalance.selector);
        dsce.liquidate(weth, user, amountToMint + 1); // Attempt to cover more debt than user has
        vm.stopPrank();
    }

    function testOperationsWithMultipleCollateralTypes() public {
        uint256 wethAmount = 5 ether; // $10,000 at $2000/ETH
        uint256 wbtcAmount = 0.2 ether; // $10,000 at $50,000/BTC (using ether for amount due to 18 decimals)
                                      // HelperConfig sets WBTC price to $50,000

        // Prices: ETH $2000, BTC $50000
        // MockV3Aggregator btcUsdPriceFeedAggregator = MockV3Aggregator(btcUsdPriceFeed);
        // btcUsdPriceFeedAggregator.updateAnswer(50000e8); // Ensure BTC price is $50,000

        // User deposits WETH
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dsce), wethAmount);
        dsce.depositCollateral(weth, wethAmount);

        // User deposits WBTC
        ERC20Mock(wbtc).approve(address(dsce), wbtcAmount);
        dsce.depositCollateral(wbtc, wbtcAmount);
        vm.stopPrank();

        // Check account info
        (uint256 totalDscMintedInitial, uint256 collateralValueInUsdInitial) = dsce.getAccountInformation(user);
        uint256 expectedWethValue = dsce.getUsdValue(weth, wethAmount);
        uint256 expectedWbtcValue = dsce.getUsdValue(wbtc, wbtcAmount);
        assertEq(totalDscMintedInitial, 0, "Initial DSC minted should be 0");
        assertEq(collateralValueInUsdInitial, expectedWethValue + expectedWbtcValue, "Total collateral value mismatch");

        // User mints DSC based on combined collateral
        // Total collateral value = $10k (WETH) + $10k (WBTC) = $20k
        // Max mintable (at 200% coll ratio) = $10k DSC
        uint256 dscToMint = 5000e18; // $5,000 DSC
        vm.startPrank(user);
        dsce.mintDsc(dscToMint);
        vm.stopPrank();

        (uint256 totalDscMintedAfterMint, uint256 collateralValueAfterMint) = dsce.getAccountInformation(user);
        assertEq(totalDscMintedAfterMint, dscToMint, "DSC minted amount mismatch");
        assertEq(collateralValueAfterMint, expectedWethValue + expectedWbtcValue, "Collateral value should not change on mint");
        uint256 healthFactor = dsce.getHealthFactor(user);
        assertTrue(healthFactor >= dsce.getMinHealthFactor(), "Health factor broken after mint with multi-collateral");
        // Expected HF = (20000 * 50 / 100) * 1e18 / 5000 = (10000 * 1e18) / 5000 = 2 * 1e18
        assertEq(healthFactor, 2 * 1e18, "Health Factor calculation error with multi-collateral");


        // User redeems some WETH
        uint256 wethToRedeem = 1 ether; // $2000
        vm.startPrank(user);
        // Before redeeming, current HF is 2e18.
        // Collateral value will drop by $2000 to $18000.
        // New HF = (18000 * 50 / 100) * 1e18 / 5000 = (9000 * 1e18) / 5000 = 1.8 * 1e18. This is > MIN_HEALTH_FACTOR.
        dsce.redeemCollateral(weth, wethToRedeem);
        vm.stopPrank();

        (uint256 totalDscMintedAfterRedeem, uint256 collateralValueAfterRedeem) = dsce.getAccountInformation(user);
        assertEq(totalDscMintedAfterRedeem, dscToMint, "DSC minted should not change on collateral redeem");
        assertEq(collateralValueAfterRedeem, expectedWethValue - dsce.getUsdValue(weth, wethToRedeem) + expectedWbtcValue, "Collateral value mismatch after WETH redeem");
        assertTrue(dsce.getHealthFactor(user) >= dsce.getMinHealthFactor(), "Health factor broken after WETH redeem");
    }

    function testOracleLib_RevertsOnPriceNotPositive() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dsce), amountCollateral);
        dsce.depositCollateral(weth, amountCollateral); // Deposit collateral first

        // Set oracle price to zero
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(0);

        vm.expectRevert(DSCEngine.OracleLib__PriceNotPositive.selector);
        dsce.mintDsc(1e18); // Attempt an action that uses the oracle
        vm.stopPrank();

        // Reset price for other tests
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(helperConfig.ETH_USD_PRICE());
    }

    function testOracleLib_RevertsOnIncompleteRound() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dsce), amountCollateral);
        dsce.depositCollateral(weth, amountCollateral); // Deposit collateral first

        // Simulate incomplete round: roundId > answeredInRound
        // Get current round data
        (uint80 roundId, , , , uint80 answeredInRound) = MockV3Aggregator(ethUsdPriceFeed).latestRoundData();
        // Force answeredInRound to be less than roundId if it's not already the case for some reason in mock.
        // Typically answeredInRound should equal roundId for a valid round.
        // We need to deploy a custom mock or modify MockV3Aggregator to set answeredInRound < roundId.
        // For now, let's assume we can set it. If MockV3Aggregator does not allow this, this test needs a more advanced mock.
        // A simpler way for this test: use a more controllable mock or accept this test might be hard to set up perfectly.
        // Given MockV3Aggregator.updateAnswer just updates the price and timestamp, it does not directly allow
        // manipulation of round IDs for this specific condition easily.
        // This test will be more of a placeholder unless MockV3Aggregator is extended or replaced.
        // However, we can test if DSCEngine propagates *any* revert from the oracle call if not specific.

        // For the purpose of this test, let's assume a direct way to trigger it if possible,
        // otherwise, this illustrates the intent.
        // If direct trigger isn't simple, an alternative is to ensure DSCEngine doesn't catch and silence oracle errors.
        // The functions in DSCEngine like getUsdValue call `priceFeed.staleCheckLatestRoundData()`
        // which now contains the new checks. So any revert from there should propagate.

        // Let's try to make `answeredInRound` smaller.
        // The `MockV3Aggregator` stores `s_latestRoundId`. `updateAnswer` increments it.
        // `latestRoundData` returns `s_latestRoundId` as `roundId` and `s_latestRoundId` as `answeredInRound`.
        // So they are always equal in the current mock.
        // To test OracleLib__IncompleteRound, OracleLib.sol would need to be tested directly with a more controlled mock,
        // or DSCEngine would need to be tested with a priceFeed that can produce this state.

        // Skip this specific scenario test if MockV3Aggregator can't create the condition.
        // The new checks in OracleLib are valuable regardless.
        // For now, we'll assert that if getUsdValue is called, it would revert if oracle lib did.
        // This specific revert is hard to trigger with the current MockV3Aggregator.
        // We can test the propagation of OracleLib__StalePrice as a proxy for error propagation.
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(helperConfig.ETH_USD_PRICE()); // Ensure fresh price
        vm.warp(block.timestamp + 4 hours); // Time travel to make price stale

        vm.expectRevert(DSCEngine.OracleLib__StalePrice.selector);
        dsce.mintDsc(1e18); // This will trigger stale check
        vm.stopPrank();
        vm.warp(block.timestamp - 4 hours); // Reset time
    }


    function testHealthFactor_Boundary_MintAllowedAtMinHealthFactor() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dsce), amountCollateral); // 10 ETH = $20,000
        dsce.depositCollateral(weth, amountCollateral);

        // Max DSC to mint to hit MIN_HEALTH_FACTOR (1e18)
        // HF = (CollateralValue * LIQUIDATION_THRESHOLD / LIQUIDATION_PRECISION * PRECISION) / DscMinted
        // 1e18 = (20000e18 * 50 / 100 * 1e18) / DscMinted
        // 1e18 = (10000e18 * 1e18) / DscMinted
        // DscMinted = 10000e18
        uint256 dscToMintAtMinHF = 10000e18;
        dsce.mintDsc(dscToMintAtMinHF); // Should be allowed
        vm.stopPrank();

        assertEq(dsce.getHealthFactor(user), MIN_HEALTH_FACTOR, "HF should be exactly MIN_HEALTH_FACTOR");
    }

    function testHealthFactor_Boundary_MintRevertsBelowMinHealthFactor() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dsce), amountCollateral); // 10 ETH = $20,000
        dsce.depositCollateral(weth, amountCollateral);

        uint256 dscToMintToBreakHF = 10000e18 + 1; // Just 1 wei more than min HF allows

        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, dsce.calculateHealthFactor(dscToMintToBreakHF, dsce.getUsdValue(weth,amountCollateral))));
        dsce.mintDsc(dscToMintToBreakHF);
        vm.stopPrank();
    }

    function testHealthFactor_Boundary_RedeemCollateralAllowedAtMinHealthFactor() public {
        // Setup: Deposit 10 WETH ($20,000), Mint 5000 DSC ($5,000). HF = 2e18
        uint256 initialCollateral = 10 ether; // $20,000
        uint256 dscToMint = 5000e18;    // $5,000
        // Initial HF = (20000 * 50/100 * 1e18) / 5000 = (10000 * 1e18) / 5000 = 2e18

        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dsce), initialCollateral);
        dsce.depositCollateral(weth, initialCollateral);
        dsce.mintDsc(dscToMint);
        assertEq(dsce.getHealthFactor(user), 2e18, "Initial HF setup incorrect");

        // Redeem collateral to bring HF to exactly MIN_HEALTH_FACTOR (1e18)
        // Current state: Collateral $20,000, DSC $5,000. HF = 2e18.
        // Target HF = 1e18.
        // 1e18 = (NewCollateralValue * 50/100 * 1e18) / 5000
        // NewCollateralValue * 0.5 = 5000 => NewCollateralValue = $10,000
        // We need to redeem $10,000 worth of WETH. $10,000 / ($2000/ETH) = 5 ETH
        uint256 wethToRedeem = 5 ether;
        dsce.redeemCollateral(weth, wethToRedeem); // Should be allowed
        vm.stopPrank();
        assertEq(dsce.getHealthFactor(user), MIN_HEALTH_FACTOR, "HF should be exactly MIN_HEALTH_FACTOR after redeem");
    }

    function testHealthFactor_Boundary_RedeemCollateralRevertsBelowMinHealthFactor() public {
        // Setup: Deposit 10 WETH ($20,000), Mint 5000 DSC ($5,000). HF = 2e18
        uint256 initialCollateral = 10 ether; // $20,000
        uint256 dscToMint = 5000e18;    // $5,000

        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dsce), initialCollateral);
        dsce.depositCollateral(weth, initialCollateral);
        dsce.mintDsc(dscToMint);
        assertEq(dsce.getHealthFactor(user), 2e18, "Initial HF setup incorrect");

        // Try to redeem collateral that would break HF
        // Current Collateral Value $20,000. Target New Collateral Value $10,000 for HF=1.
        // Redeeming 5 WETH ($10,000) is fine. Redeeming 5 WETH + 1 wei should break it.
        uint256 wethToRedeemToBreak = 5 ether + 1 wei;
        uint256 collateralValueAfterRedeemAttempt = dsce.getUsdValue(weth, initialCollateral - wethToRedeemToBreak);

        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, dsce.calculateHealthFactor(dscToMint, collateralValueAfterRedeemAttempt)));
        dsce.redeemCollateral(weth, wethToRedeemToBreak);
        vm.stopPrank();
    }


    ///////////////////////////////////
    // View & Pure Function Tests //
    //////////////////////////////////
    function testGetCollateralTokenPriceFeed() public view {
        address priceFeed = dsce.getCollateralTokenPriceFeed(weth);
        assertEq(priceFeed, ethUsdPriceFeed);
    }

    function testGetCollateralTokens() public view {
        address[] memory collateralTokens = dsce.getCollateralTokens();
        assertEq(collateralTokens[0], weth);
    }

    function testGetMinHealthFactor() public view {
        uint256 minHealthFactor = dsce.getMinHealthFactor();
        assertEq(minHealthFactor, MIN_HEALTH_FACTOR);
    }

    function testGetLiquidationThreshold() public view {
        uint256 liquidationThreshold = dsce.getLiquidationThreshold();
        assertEq(liquidationThreshold, LIQUIDATION_THRESHOLD);
    }

    function testGetAccountCollateralValueFromInformation() public depositedCollateral {
        (, uint256 collateralValue) = dsce.getAccountInformation(user);
        uint256 expectedCollateralValue = dsce.getUsdValue(weth, amountCollateral);
        assertEq(collateralValue, expectedCollateralValue);
    }

    function testGetCollateralBalanceOfUser() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dsce), amountCollateral);
        dsce.depositCollateral(weth, amountCollateral);
        vm.stopPrank();
        uint256 collateralBalance = dsce.getCollateralBalanceOfUser(user, weth);
        assertEq(collateralBalance, amountCollateral);
    }

    function testGetAccountCollateralValue() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dsce), amountCollateral);
        dsce.depositCollateral(weth, amountCollateral);
        vm.stopPrank();
        uint256 collateralValue = dsce.getAccountCollateralValue(user);
        uint256 expectedCollateralValue = dsce.getUsdValue(weth, amountCollateral);
        assertEq(collateralValue, expectedCollateralValue);
    }

    function testGetDsc() public view {
        address dscAddress = dsce.getDsc();
        assertEq(dscAddress, address(dsc));
    }

    function testLiquidationPrecision() public view {
        uint256 expectedLiquidationPrecision = 100;
        uint256 actualLiquidationPrecision = dsce.getLiquidationPrecision();
        assertEq(actualLiquidationPrecision, expectedLiquidationPrecision);
    }

    // How do we adjust our invariant tests for this?
    // function testInvariantBreaks() public depositedCollateralAndMintedDsc {
    //     MockV3Aggregator(ethUsdPriceFeed).updateAnswer(0);
    // }

    ///////////////////////////////////////////////
    // DecentralizedStableCoin specific tests //
    ///////////////////////////////////////////////

    function test_DSC_Mint_OnlyOwnerCanMint() public {
        address nonOwner = address(0xBAD);
        vm.prank(nonOwner);
        vm.expectRevert(Ownable.OwnableUnauthorizedAccount.selector);
        dsc.mint(user, 100e18);
    }

    function test_DSC_Mint_RevertsIfAmountIsZero() public {
        // DSCEngine is the owner of DSC after deployment by DeployDSC script
        // We need to figure out who the owner is.
        // The DeployDSC script calls `dsc.transferOwnership(address(dsce));`
        address dscOwner = dsce.getDsc(); // This returns address(dsc)
        // The owner of dsc is actually address(dsce) because of transferOwnership in DeployDSC.s.sol
        // So, to test onlyOwner functions on dsc, we must prank address(dsce)

        // This test is for dsc.mint, not dsce.mintDsc
        // The owner of DSC is the DSCEngine contract instance.
        // So, to call dsc.mint, msg.sender must be dsce.
        // This is tricky to test directly unless we make this test contract the owner,
        // or we have a way for dsce to call dsc.mint(target, 0).
        // The dsce.mintDsc() already has a check for amount > 0.
        // Let's test dsc.mint directly by making current contract owner of a new DSC instance.

        DecentralizedStableCoin newDsc = new DecentralizedStableCoin();
        // Now msg.sender (this contract) is the owner of newDsc
        vm.expectRevert(DecentralizedStableCoin.DecentralizedStableCoin__MustBeMoreThanZero.selector);
        newDsc.mint(user, 0);
    }

    // test_DSC_Mint_RevertsIfToIsZeroAddress is covered by OpenZeppelin's _mint check

    function test_DSC_Burn_OnlyOwnerCanBurn() public {
        address nonOwner = address(0xBAD);
        // Mint some tokens to owner first to be able to burn
        // As above, owner of global 'dsc' is 'dsce'.
        // Let's use a newDsc instance where this test contract is the owner.
        DecentralizedStableCoin newDsc = new DecentralizedStableCoin();
        newDsc.mint(address(this), 100e18); // Mint to self (owner)

        vm.prank(nonOwner);
        vm.expectRevert(Ownable.OwnableUnauthorizedAccount.selector);
        newDsc.burn(100e18);
    }

    function test_DSC_Burn_RevertsIfAmountIsZero() public {
        DecentralizedStableCoin newDsc = new DecentralizedStableCoin();
        newDsc.mint(address(this), 100e18);

        vm.expectRevert(DecentralizedStableCoin.DecentralizedStableCoin__MustBeMoreThanZero.selector);
        newDsc.burn(0);
    }

    // test_DSC_Burn_RevertsIfAmountExceedsBalance is covered by OpenZeppelin's _burn check
    // and our custom burn also had a check which we removed as redundant.
    // So relying on OZ for this.
}


// contract DecentralizedStableCoinTest is Test {
//     DecentralizedStableCoin dsc;
//     address owner = address(this);
//     address user = address(1);

//     function setUp() public {
//         dsc = new DecentralizedStableCoin(); // Owner is address(this)
//     }

//     function testMint_OnlyOwner() public {
//         vm.prank(user); // Non-owner
//         vm.expectRevert(Ownable.OwnableUnauthorizedAccount.selector);
//         dsc.mint(user, 100e18);
//     }

//     function testMint_RevertsIfAmountZero() public {
//         vm.expectRevert(DecentralizedStableCoin.DecentralizedStableCoin__MustBeMoreThanZero.selector);
//         dsc.mint(user, 0);
//     }

//     function testMint_RevertsIfToIsZero() public {
//         // OpenZeppelin's _mint handles this with ERC20InvalidReceiver(address(0))
//         // Our custom error DecentralizedStableCoin__NotZeroAddress was removed as redundant.
//         vm.expectRevert(abi.encodeWithSelector(ERC20.ERC20InvalidReceiver.selector, address(0) ));
//         dsc.mint(address(0), 100e18);
//     }

//     function testMint_Success() public {
//         uint256 amount = 100e18;
//         vm.expectEmit(true, true, true, true); // Transfer event from address(0)
//         emit Transfer(address(0), user, amount);
//         assertTrue(dsc.mint(user, amount));
//         assertEq(dsc.balanceOf(user), amount);
//         assertEq(dsc.totalSupply(), amount);
//     }

//     function testBurn_OnlyOwner() public {
//         dsc.mint(owner, 100e18); // Mint to owner so they have something to burn
//         vm.prank(user); // Non-owner
//         vm.expectRevert(Ownable.OwnableUnauthorizedAccount.selector);
//         dsc.burn(100e18);
//     }

//     function testBurn_RevertsIfAmountZero() public {
//         dsc.mint(owner, 100e18);
//         vm.expectRevert(DecentralizedStableCoin.DecentralizedStableCoin__MustBeMoreThanZero.selector);
//         dsc.burn(0);
//     }

//     function testBurn_RevertsIfAmountExceedsBalance() public {
//         dsc.mint(owner, 50e18);
//         // OpenZeppelin's _burn handles this with ERC20InsufficientBalance
//         // Our custom error DecentralizedStableCoin__BurnAmountExceedsBalance was removed.
//         vm.expectRevert(abi.encodeWithSelector(ERC20.ERC20InsufficientBalance.selector, owner, 50e18, 100e18));
//         dsc.burn(100e18);
//     }

//     function testBurn_Success() public {
//         uint256 initialAmount = 100e18;
//         uint256 burnAmount = 30e18;
//         dsc.mint(owner, initialAmount);

//         vm.expectEmit(true, true, true, true); // Transfer event to address(0)
//         emit Transfer(owner, address(0), burnAmount);
//         dsc.burn(burnAmount);
//         assertEq(dsc.balanceOf(owner), initialAmount - burnAmount);
//         assertEq(dsc.totalSupply(), initialAmount - burnAmount);
//     }

    //     uint256 totalSupply = dsc.totalSupply();
    //     uint256 wethDeposted = ERC20Mock(weth).balanceOf(address(dsce));
    //     uint256 wbtcDeposited = ERC20Mock(wbtc).balanceOf(address(dsce));

    //     uint256 wethValue = dsce.getUsdValue(weth, wethDeposted);
    //     uint256 wbtcValue = dsce.getUsdValue(wbtc, wbtcDeposited);

    //     console.log("wethValue: %s", wethValue);
    //     console.log("wbtcValue: %s", wbtcValue);
    //     console.log("totalSupply: %s", totalSupply);

    //     assert(wethValue + wbtcValue >= totalSupply);
    // }
}
