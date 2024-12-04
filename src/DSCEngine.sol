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

    ////////////////////////////
    ///  STATE VARIABLES  ////////////
    ///////////////////////////
    mapping(address token => address priceFeed) private s_priceFeeds; //tokenToPriceFee
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amountDscMinted) private s_DSCMinted;

    address[] private s_collateralTokens;
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;

    DecentralizedStableCoin private immutable i_dsc;

    ////////////////////////////
    ///     DEVENTS  //////////
    ///////////////////////////
    // Always use events when anything updates the state of the chain or state variables !!

    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);

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
    function depositCollateralAndMintDsc() external {}

    /**
     * @notice follows CEI
     * @param tokenCollateralAddress:  The address of the token to deposit as collateral
     * @param amountCollateral: The amount of collateral to deposit
     */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        external
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

    function redeemCollateralForDsc() external {}

    function redeemCollateral() external {}

    // $200 ETH they can mint 20 DSC
    //once we deposit collateral (ie: depositCollateral function) than we should mint the DSC token
    /**
     * @notice Follows CEI  (Check, Execute , Interaction)
     * @param amountDscToMint  The amount of decentralized stablecoin to mint
     * @notice  They must have more collateral value than the minimum threshold
     */
    function mintDsc(uint256 amountDscToMint) external moreThanZero(amountDscToMint) nonReentrant {
        s_DSCMinted[msg.sender] += amountDscToMint;
        //if they minted too much ($150 DSC for $100ETH)
        revertIfHealthFactorIsBroken(msg.sender);
    }

    function burnDsc() external {}

    function liquidate() external {} // when the eth tanks user should be out of the system

    function getHealthFactor() external view {}

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

    ////////////////////////////
    ///  Private and Internal biew FUNCTIONS  ///
    ///////////////////////////

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
    }

    function revertIfHealthFactorIsBroken(address user) internal view {
        //1. Check health factor (do they have enough collateral?)
        //2. Revert if they dont
    }
}
