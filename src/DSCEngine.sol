//SPDX-License-Identifier:MIT

pragma solidity ^0.8.19;

/**
 * @title  DSCEngine
 * @author Samer Abi Faraj
 *
 * The system is designed to be as minimal as possible, and have the tokens maintain a 1 token == $1 peg
 * This stablecoin has the properties:
 *  - Exogenous Collateral
 *  - Dollar Pegged
 *  - Algorithically Stable
 *
 * It is similar to DAI if DAI had no goverance, no fees and was only backed by WETH and WBTC.
 *
 * Our DSC system should always be "overcollateralized". At no point, should the value of all collateral <= the $ backed value of all the DSC
 *   //Threshold to let's say 150%
 *     //Initially:
 *     //$100 ETH Collateral
 *     //$50 DSC so i will mint you $50 DAI
 *     //If Price of ETH tanks to $74, this will mean that now you are undercollateralized !! so you let someone else by your DSC at discount
 *     // i'll pay back the $50 of DSC --> get all your collateral
 *     // hence this new guy paid the $50 DSC and got your $74 collaeral!
 *
 * @notice This contract is the core of the DSC system. It handles all the logic for mining and redeeming of DSC, as well as depositiing & withdrawing collateral.
 * @notice This contract is VERY loosely based on the MakerDAO DSS (DAI) system
 */
import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol"; //When working with external contracts best practice to use the nonReentrant modifier within this contract
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

contract DSCEngine is ReentrancyGuard {
    ////////////////////////////
    ///  ERRORS  ////////////
    ///////////////////////////
    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenAddressAndPriceFeedAddressesMustBeSameLength();
    error DSCEngine__NotAllowedToken();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor(uint256 healthFactor);
    error DSCEngine_MintFailed();
    error DSCEngine__HealthFactorok();
    error DSCEngine__HealthFactorNotImproved();

    ////////////////////////////
    ///  STATE VARIABLES  ////////////
    ///////////////////////////
    mapping(address token => address priceFeed) private s_priceFeeds; //tokenToPriceFee
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amountDscMinted) private s_DSCMinted;

    address[] private s_collateralTokens;
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // 200% overcollateralized
    uint256 private constant LIQUIDATION_PRECISION = 100; //
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10; // means a 10% bonus

    DecentralizedStableCoin private immutable i_dsc;

    ////////////////////////////
    ///     EVENTS  //////////
    ///////////////////////////
    // Always use events when anything updates the state of the chain or state variables !!

    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(
        address indexed redeemedFrom, address indexed redeemedTo, address indexed token, uint256 amount
    );
    ////////////////////////////
    ///  MODIFIERS  ////////////
    ///////////////////////////

    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine__NeedsMoreThanZero();
        }
        _;
    }

    modifier isAllowToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__NotAllowedToken();
        }
        _;
    }

    ////////////////////////////
    ///  FUNCTIONS  ////////////
    ///////////////////////////

    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress) {
        //USD Price Feeds  (ex: ETH/USD,  BTC/USD, MKR/USD, ETC....)
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressAndPriceFeedAddressesMustBeSameLength();
        }

        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i]; //The address of Token "i" will map to the address of Price Feed "i"
            s_collateralTokens.push(tokenAddresses[i]);
        }

        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    ////////////////////////////
    ///  EXTERNAL FUNCTIONS  ////////////
    ///////////////////////////

    /**
     *
     * @param tokenCollateralAddress  The address of the token to deposidt as collateral
     * @param amountCollateral The amount of collateral to deposit
     * @param amountDscToMint The amount of decentralized stablecoin to mint
     * @notice this function will deposit your collateral and mint DSC in one transaction
     */
    function depositCollateralAndMintDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountDscToMint);
    }

    /**
     * @notice follows CEI
     * @param tokenCollateralAddress:  The address of the token to deposit as collateral
     * @param amountCollateral: The amount of collateral to deposit
     */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        isAllowToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);

        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) {
            //Transferring from user(ie: msg.sender) to this contract (ie:address(this)) with the amount of ammountCollateral
            revert DSCEngine__TransferFailed();
        }
    }

    /*
     * @param tokenCollateralAddress   The Token collateral address to redeem
     * @param amountCollateral  The amount of Token collateral to redeem
     * @param amountOfDscToBurn  The amount of the DSC decentralized stablecoin to burn
     * 
     * This function burns DSC and redeems underlying collateral in one transaction
     */

    function redeemCollateralForDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToBurn)
        external
        moreThanZero(amountCollateral)
        nonReentrant
    {
        burnDsc(amountDscToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
        // redeemCollateral already checks the healthfactor
    }

    // In order to redeem collateral
    //  1. The health factor must be over 1 AFTER collateral is pulled out
    // DRY: Dont repeat yourself therefore we weill refactor it after
    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        nonReentrant
    {
        _redeemCollateral(msg.sender, msg.sender, tokenCollateralAddress, amountCollateral);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    // $200 ETH they can mint 20 DSC
    //once we deposit collateral (ie: depositCollateral function) than we should mint the DSC token
    /**
     * @notice Follows CEI  (Check, Effects , Interactions)
     * @param amountDscToMint  The amount of decentralized stablecoin to mint
     * @notice  They must have more collateral value than the minimum threshold
     */
    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant {
        s_DSCMinted[msg.sender] += amountDscToMint;
        //if they minted too much ($150 DSC for $100ETH)
        _revertIfHealthFactorIsBroken(msg.sender);

        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!minted) {
            revert DSCEngine_MintFailed();
        }
    }

    function burnDsc(uint256 amount) public moreThanZero(amount) {
        _burnDsc(amount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender); // I dont think this will ever hit ! but we include it just incase
    }

    // If initially you deposited $100 ETH for $50 DSC
    // If ETH drops to $20 ETH we still have $50 DSC which is now under $1 (20/50) // WE DONT WANT IT TO GET TO THIS POINT!
    //Therefore we need to remove ppl position when they reach this point

    // As the price goes down to $75 which is backing the $50 DSC
    // We will let a liquidator take the $75 backing and burns off the $50 DSC

    // If someone is almost undercollateralized, we wil pay you to liquidate them!!

    /**
     * @param collateral  The erc20 collateral address to liquidate from the user
     * @param user  The user who has broken the health factor, There _healtherFactor should be below the MIN_HEALTH_FACTOR
     * @param debtToCover The amount of DSC you want to burn to improve the users health factor
     *
     * @notice You can partially liquidate a user
     * @notice You will get a liquidation bonus for taking the users funds
     * @notice This function working assumes the protocal will be roughtly 200% overcollateralized in order for this to work
     * @notice A known bug would be if the protocol were 100% or less collateralized, then we wouldn't be able to incentivize the liquidators.
     *      For Example: If the price of the collateral plummeted before anyone could be liquidated.
     */
    function liquidate(
        address collateral,
        address user,
        uint256 debtToCover // when the eth tanks user should be out of the system
    ) external moreThanZero(debtToCover) nonReentrant {
        //need to check health factor of the user
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorok();
        }

        //We want to burn their DSC "debt"
        //And take their collateral
        //Bad user example: If user has $140 of ETH for $100 DSC (ie: less than 1)
        // then we want to cover debtToCover = $100,
        // What we want then is how much is $100 DSC in ETH???
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);
        // And give them a 10% bonus
        // So we are giving the liquidator $110 of WETH for 100 DSC
        // We should implement a feature to liquidate in the event the protocol is insolvent
        // and sweep extra amounts into a treasury (This part will not be implmented but should be)

        // 0.05 eth * 0.1 = 0.005 .. getting 0.055
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;

        _redeemCollateral(user, msg.sender, collateral, totalCollateralToRedeem);
        _burnDsc(debtToCover, user, msg.sender); //now burn the dsc // the user is the one we are liquidating and the msg.sender is the one paying off the debt of the user

        uint256 endingUserHealthFactor = _healthFactor(user);
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }

        _revertIfHealthFactorIsBroken(msg.sender); //Checks to ensure the person paying off the debt is not comprimised now after paying of the users debt
    }

    function getHealthFactor() external view {}

    function getTokenAmountFromUsd(address collateralToken, uint256 usdAmountInWei) public view returns (uint256) {
        //Math logic
        //Price of Eth (Token)
        //$/ETH ETH ??
        // $2000 / ETH. $1000 = 0.5 ETH
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[collateralToken]);
        (, int256 price,,,) = priceFeed.latestRoundData();

        return (usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }

    function getAccountCollateralValue(address user) public view returns (uint256) {
        // loop through each collateral token, get the amount they have deposited, and map it to the
        // price, to get the USD value.
        uint256 totalCollateralValueInUsd = 0;

        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += getUsdValue(token, amount);
        }
        return totalCollateralValueInUsd;
    }

    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        // 1 ETH = $1000
        // The returned value from CL will be 1000 * 1e8;
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION; //(100*1e8)
    }

    function getAccountInformation(address user)
        external
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        (totalDscMinted, collateralValueInUsd) = _getAccountInformation(user);
    }

    ////////////////////////////
    ///  Private and Internal biew FUNCTIONS  ///
    ///////////////////////////
    /**
     * @dev Low-Level internal function, do not call unless the function calling it is checking for health factors being broken
     */
    function _burnDsc(uint256 amountDscToBurn, address onBehalfOf, address dscFrom) private {
        s_DSCMinted[onBehalfOf] -= amountDscToBurn;

        bool success = i_dsc.transferFrom(dscFrom, address(this), amountDscToBurn); //First transfer the amount from the sender to the contract then execute the burn
        if (!success) {
            revert DSCEngine__TransferFailed();
        }

        i_dsc.burn(amountDscToBurn); //Now burn the amount from the contract
    }

    function _redeemCollateral(address from, address to, address tokenCollateralAddress, uint256 amountCollateral)
        private
    {
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral; //Decrease the collateral by the amountCollateral
        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);

        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        totalDscMinted = s_DSCMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);
    }

    /**
     * Returns how close to liquidation a user is
     * If a user goes below 1, then they can get liquidated
     */
    function _healthFactor(address user) private view returns (uint256) {
        // Need to get the Total DSC minted
        // total collateral VALUE
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);

        //ex: 1000 ETH * 50 = 50,000/100 = 500
        //ex: $150 Eth * 50 = 7500 = (7500/100)v== since solidity does not have decials 75 would mean that we are undercollateralized now
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;

        //ex: $1000 ETH  and  100 DSC
        // collateralAdjustedForThreshold = $1000*50 / 100 ==> 500
        // return:  500*1e18/100 ==> 5*1e18  (which is greather than 1 meaning this person is good and overcollaterized)
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

    //1. Check health factor (do they have enough collateral?)
    //2. Revert if they dont
    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
        }
    }
}
