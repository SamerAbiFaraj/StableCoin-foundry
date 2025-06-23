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
 * Our DSC system should always be "overcollateralized". At no point, should the value of all collateral <= the $ backed
 * value of all the DSC
 *   //Threshold to let's say 150%
 *     //Initially:
 *     //$100 ETH Collateral
 *     //$50 DSC so i will mint you $50 DAI
 *     //If Price of ETH tanks to $74, this will mean that now you are undercollateralized !! so you let someone else by
 * your DSC at discount
 *     // i'll pay back the $50 of DSC --> get all your collateral
 *     // hence this new guy paid the $50 DSC and got your $74 collaeral!
 *
 * @notice This contract is the core of the DSC system. It handles all the logic for mining and redeeming of DSC, as
 * well as depositiing & withdrawing collateral.
 * @notice This contract is VERY loosely based on the MakerDAO DSS (DAI) system
 */
import { DecentralizedStableCoin } from "./DecentralizedStableCoin.sol";
//import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol"; //When working with external
// contracts best practice to use the nonReentrant modifier within this contract
import { ReentrancyGuard } from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { AggregatorV3Interface } from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import { console } from "forge-std/console.sol";
import { OracleLib } from "./libraries/OracleLib.sol";

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
    error DSCEngine__HealthFactorOk();
    error DSCEngine__HealthFactorNotImproved();
    error DSCEngine__BurnAmountExceedsBalance();

    ////////////////////////////
    ///  TYPE  ////////////
    ///////////////////////////
    using OracleLib for AggregatorV3Interface;

    ////////////////////////////
    ///  STATE VARIABLES  ////////////
    ///////////////////////////

    /** @dev Mapping from token address to its Chainlink price feed address. */
    mapping(address token => address priceFeed) private s_priceFeeds;
    /** @dev Mapping from user address to their deposited collateral (token address => amount). */
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    /** @dev Mapping from user address to the amount of DSC they have minted. */
    mapping(address user => uint256 amountDscMinted) private s_DSCMinted;
    /** @dev Array of allowed collateral token addresses. */
    address[] private s_collateralTokens;

    /** @dev Precision for Chainlink price feeds (e.g., ETH/USD has 8 decimals, this brings it to 18). */
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    /** @dev Standard precision for calculations (18 decimals). */
    uint256 private constant PRECISION = 1e18;
    /** @dev Collateralization ratio threshold for liquidation (e.g., 50 means 150% collateralization required -> (100+50)/100).
     *   Actually, this seems to be used as (collateralValue * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION.
     *   If LIQUIDATION_THRESHOLD is 50, and LIQUIDATION_PRECISION is 100, it means health factor calculation uses 50% of collateral value.
     *   This implies that to be above MIN_HEALTH_FACTOR (1e18), collateralValue * 0.5 / totalDscMinted >= 1.
     *   So, collateralValue must be >= 2 * totalDscMinted. This is a 200% collateralization ratio.
     */
    uint256 private constant LIQUIDATION_THRESHOLD = 50;
    /** @dev Denominator for LIQUIDATION_THRESHOLD calculations. */
    uint256 private constant LIQUIDATION_PRECISION = 100;
    /** @dev Minimum health factor a user must maintain (1e18 means adjusted collateral value must be >= total DSC minted). */
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    /** @dev Bonus percentage for liquidators (e.g., 10 means a 10% bonus on collateral). */
    uint256 private constant LIQUIDATION_BONUS = 10;

    /** @dev Immutable reference to the DecentralizedStableCoin (DSC) token contract. */
    DecentralizedStableCoin private immutable i_dsc;

    ////////////////////////////
    ///     EVENTS  //////////
    ///////////////////////////

    /**
     * @notice Emitted when collateral is deposited into the engine.
     * @param user The user who deposited the collateral.
     * @param token The address of the collateral token.
     * @param amount The amount of collateral deposited.
     */
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);

    /**
     * @notice Emitted when collateral is redeemed from the engine.
     * @param redeemedFrom The user whose collateral was redeemed (could be the user themselves or by a liquidator).
     * @param redeemedTo The user who received the redeemed collateral (user or liquidator).
     * @param token The address of the collateral token.
     * @param amount The amount of collateral redeemed.
     */
    event CollateralRedeemed(
        address indexed redeemedFrom, address indexed redeemedTo, address indexed token, uint256 amount
    );

    ////////////////////////////
    ///  MODIFIERS  ////////////
    ///////////////////////////

    /** @dev Modifier to ensure an amount is greater than zero. */
    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine__NeedsMoreThanZero();
        }
        _;
    }

    /** @dev Modifier to ensure a token is an allowed collateral type. */
    modifier isAllowToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__NotAllowedToken();
        }
        _;
    }

    ////////////////////////////
    ///  FUNCTIONS  ////////////
    ///////////////////////////

    /**
     * @notice Initializes the DSCEngine with collateral token addresses, their price feed addresses, and the DSC token address.
     * @param tokenAddresses Array of addresses for the collateral tokens.
     * @param priceFeedAddresses Array of addresses for the Chainlink price feeds corresponding to each collateral token.
     * @param dscAddress Address of the DecentralizedStableCoin (DSC) token.
     */
    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress) {
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressAndPriceFeedAddressesMustBeSameLength();
        }

        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }

        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    ////////////////////////////
    ///  EXTERNAL FUNCTIONS  ////////////
    ///////////////////////////

    /**
     * @notice Deposits collateral and mints DSC in a single transaction.
     * @param tokenCollateralAddress The address of the token to deposit as collateral.
     * @param amountCollateral The amount of collateral to deposit.
     * @param amountDscToMint The amount of DSC to mint.
     * @dev User must approve this contract to spend `amountCollateral` of `tokenCollateralAddress`.
     * @dev Health factor is checked after minting DSC.
     */
    function depositCollateralAndMintDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
    )
        external
        // Note: individual functions `depositCollateral` and `mintDsc` handle `moreThanZero` and `isAllowToken`
    {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountDscToMint); // This function will check health factor
    }

    /**
     * @notice Deposits collateral into the DSCEngine.
     * @param tokenCollateralAddress The address of the token to deposit as collateral.
     * @param amountCollateral The amount of collateral to deposit.
     * @dev User must approve this contract to spend `amountCollateral` of `tokenCollateralAddress`.
     * @dev Emits {CollateralDeposited} event.
     */
    function depositCollateral(
        address tokenCollateralAddress,
        uint256 amountCollateral
    )
        public
        moreThanZero(amountCollateral)
        isAllowToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);

        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    /**
     * @notice Burns DSC and redeems a specified amount of collateral in a single transaction.
     * @param tokenCollateralAddress The address of the collateral token to redeem.
     * @param amountCollateral The amount of collateral to redeem.
     * @param amountDscToBurn The amount of DSC to burn.
     * @dev User must approve this contract to spend `amountDscToBurn` of DSC token.
     * @dev Health factor is checked after redeeming collateral.
     */
    function redeemCollateralForDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToBurn
    )
        external
        moreThanZero(amountCollateral) // amountDscToBurn is checked by burnDsc
        nonReentrant
    {
        burnDsc(amountDscToBurn); // This will check if amountDscToBurn > 0
        redeemCollateral(tokenCollateralAddress, amountCollateral); // This will check health factor
    }

    /**
     * @notice Redeems a specified amount of collateral.
     * @param tokenCollateralAddress The address of the collateral token to redeem.
     * @param amountCollateral The amount of collateral to redeem.
     * @dev Health factor must remain above MIN_HEALTH_FACTOR after redemption.
     * @dev Emits {CollateralRedeemed} event.
     */
    function redeemCollateral(
        address tokenCollateralAddress,
        uint256 amountCollateral
    )
        public
        moreThanZero(amountCollateral)
        isAllowToken(tokenCollateralAddress) // Important to check token is valid for redemption calculations
        nonReentrant
    {
        _redeemCollateral(msg.sender, msg.sender, tokenCollateralAddress, amountCollateral);
        _revertIfHealthFactorIsBroken(msg.sender); // Check health factor after collateral is removed
    }

    /**
     * @notice Mints DSC against the caller's deposited collateral.
     * @param amountDscToMint The amount of DSC to mint.
     * @dev Health factor must remain above MIN_HEALTH_FACTOR after minting.
     * @dev Caller must have sufficient collateral value.
     */
    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant {
        s_DSCMinted[msg.sender] += amountDscToMint;
        _revertIfHealthFactorIsBroken(msg.sender); // Check health factor after DSC is minted

        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!minted) {
            revert DSCEngine_MintFailed();
        }
    }

    /**
     * @notice Burns DSC tokens from the caller.
     * @param amount The amount of DSC to burn.
     * @dev User must approve this contract to spend `amount` of DSC token.
     * @dev Health factor is checked if the user still has minted DSC, though burning typically improves it.
     */
    function burnDsc(uint256 amount) public moreThanZero(amount) {
        _burnDsc(amount, msg.sender, msg.sender);
        if (s_DSCMinted[msg.sender] > 0) {
            _revertIfHealthFactorIsBroken(msg.sender); // I dont think this will ever hit ! but we include it just
                // incase
        }
    }

    // If initially you deposited $100 ETH for $50 DSC
    // If ETH drops to $20 ETH we still have $50 DSC which is now under $1 (20/50) // WE DONT WANT IT TO GET TO THIS
    // POINT!
    //Therefore we need to remove ppl position when they reach this point

    // As the price goes down to $75 which is backing the $50 DSC
    // We will let a liquidator take the $75 backing and burns off the $50 DSC

    // If someone is almost undercollateralized, we wil pay you to liquidate them!!

    /**
     * @param collateral  The erc20 collateral address to liquidate from the user
     * @param user  The user who has broken the health factor, There _healtherFactor should be below the
     * MIN_HEALTH_FACTOR
     * @param debtToCover The amount of DSC you want to burn to improve the users health factor
     *
     * @notice You can partially liquidate a user.
     * @notice You will get a liquidation bonus for taking the user's funds.
     * @notice This function assumes the protocol will be sufficiently overcollateralized (e.g., > 200%)
     * for the liquidation bonus to be covered by the user's collateral.
     * @dev Economic Consideration: If the protocol becomes severely undercollateralized (e.g., total collateral value drops significantly below total debt),
     * or if a specific user's collateral value plummets rapidly, the fixed `LIQUIDATION_BONUS`
     * might not be fully covered by the liquidated collateral. This is an inherent risk in CDP systems
     * when collateral prices are highly volatile. The protocol does not have a separate treasury to fund bonuses in such extreme scenarios.
     */
    function liquidate(
        address collateral,
        address user,
        uint256 debtToCover // when the eth tanks user should be out of the system
    )
        external
        moreThanZero(debtToCover)
        nonReentrant
    {
        //need to check health factor of the user
        uint256 startingUserHealthFactor = _healthFactor(user);

        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOk();
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
        _burnDsc(debtToCover, user, msg.sender); //now burn the dsc // the user is the one we are liquidating and the
            // msg.sender is the one paying off the debt of the user

        uint256 endingUserHealthFactor = _healthFactor(user);
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }

        _revertIfHealthFactorIsBroken(msg.sender); //Checks to ensure the person paying off the debt is not comprimised
            // now after paying of the users debt
    }

    // function getHealthFactor() external view { } // This function is redundant due to getHealthFactor(address user)

    /**
     * @notice Calculates the amount of a specific collateral token equivalent to a given USD value.
     * @param collateralToken The address of the collateral token.
     * @param usdAmountInWei The USD value in Wei (18 decimals).
     * @return The equivalent amount of the collateral token in its native precision.
     * @dev Uses Chainlink price feeds and adjusts for feed precision.
     */
    function getTokenAmountFromUsd(address collateralToken, uint256 usdAmountInWei) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[collateralToken]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        // Price feed returns price with 8 decimals (e.g., 2000 * 1e8 for ETH/USD at $2000)
        // We want to convert usdAmountInWei (18 decimals) to token amount (typically 18 decimals)
        // Formula: (usdAmountInWei * 1e18) / (priceFromFeed * 1e10)
        // price * ADDITIONAL_FEED_PRECISION converts price to 18 decimals
        return (usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }

    /**
     * @notice Calculates the total USD value of a user's deposited collateral.
     * @param user The address of the user.
     * @return The total value of the user's collateral in USD (18 decimals).
     * @dev Iterates through all allowed collateral types.
     */
    function getAccountCollateralValue(address user) public view returns (uint256) {
        uint256 totalCollateralValueInUsd = 0;
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            if (amount > 0) { // Optimization: only fetch price if user has collateral for this token
                totalCollateralValueInUsd += getUsdValue(token, amount);
            }
        }
        return totalCollateralValueInUsd;
    }

    /**
     * @notice Calculates the USD value of a given amount of a specific token.
     * @param token The address of the token.
     * @param amount The amount of the token (in its native precision, typically 18 decimals).
     * @return The USD value of the token amount (18 decimals).
     * @dev Uses Chainlink price feeds and adjusts for feed precision.
     */
    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        // price is in 1e8 (e.g., $2000/ETH is 2000 * 1e8)
        // amount is in 1e18 (token's decimals)
        // Result should be in 1e18
        // ((price * 1e10) * amount) / 1e18
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }

    /**
     * @notice Retrieves the total DSC minted by a user and the total USD value of their collateral.
     * @param user The address of the user.
     * @return totalDscMinted The total amount of DSC minted by the user.
     * @return collateralValueInUsd The total USD value of the user's deposited collateral.
     */
    function getAccountInformation(address user)
        external
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        (totalDscMinted, collateralValueInUsd) = _getAccountInformation(user);
    }

    ////////////////////////////
    ///  Private and Internal view FUNCTIONS  ///
    ///////////////////////////
    /**
     * @dev Low-Level internal function, do not call unless the function calling it is checking for health factors being
     * broken
     */
    function _burnDsc(uint256 amountDscToBurn, address onBehalfOf, address dscFrom) private {
        if (amountDscToBurn > s_DSCMinted[onBehalfOf]) {
            revert DSCEngine__BurnAmountExceedsBalance();
        }
        s_DSCMinted[onBehalfOf] -= amountDscToBurn;

        bool success = i_dsc.transferFrom(dscFrom, address(this), amountDscToBurn); //First transfer the amount from the
            // sender to the contract then execute the burn
        if (!success) {
            revert DSCEngine__TransferFailed();
        }

        i_dsc.burn(amountDscToBurn); //Now burn the amount from the contract
    }

    function _redeemCollateral(
        address from,
        address to,
        address tokenCollateralAddress,
        uint256 amountCollateral
    )
        private
    {
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral; //Decrease the collateral by the
            // amountCollateral
        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);

        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    /**
     * @notice Calculates the health factor for a user.
     * @param totalDscMinted The total amount of DSC minted by the user.
     * @param collateralValueInUsd The total USD value of the user's deposited collateral.
     * @return The health factor, calculated as (collateralValueInUsd * LIQUIDATION_THRESHOLD / LIQUIDATION_PRECISION * PRECISION) / totalDscMinted.
     * @dev Returns type(uint256).max if totalDscMinted is 0.
     */
    function calculateHealthFactor(
        uint256 totalDscMinted,
        uint256 collateralValueInUsd
    )
        external
        pure
        returns (uint256)
    {
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    /**
     * @dev Internal function to calculate health factor.
     * @param totalDscMinted The total amount of DSC minted.
     * @param collateralValueInUsd The total USD value of collateral.
     * @return The health factor. Returns type(uint256).max if totalDscMinted is 0.
     */
    function _calculateHealthFactor(
        uint256 totalDscMinted,
        uint256 collateralValueInUsd
    )
        internal
        pure
        returns (uint256)
    {
        if (totalDscMinted == 0) return type(uint256).max;
        // This effectively means: (Collateral Value in USD * (LIQUIDATION_THRESHOLD / 100) * 1e18) / DSC Minted
        // If LIQUIDATION_THRESHOLD = 50, it's (Collateral Value * 0.5 * 1e18) / DSC Minted
        // A health factor of 1e18 means (Collateral Value * 0.5) >= DSC Minted, or Collateral Value >= 2 * DSC Minted (200% collateralized)
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

    /**
     * @dev Internal function to retrieve a user's total minted DSC and collateral value.
     * @param user The address of the user.
     * @return totalDscMinted The total DSC minted by the user.
     * @return collateralValueInUsd The total USD value of the user's collateral.
     */
    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        totalDscMinted = s_DSCMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);
    }

    /**
     * @dev Calculates the health factor for a specific user based on their current state.
     * @param user The address of the user.
     * @return The user's health factor. Returns type(uint256).max if no DSC is minted.
     */
    function _healthFactor(address user) private view returns (uint256) {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    /**
     * @dev Internal function to check if a user's health factor is broken (below MIN_HEALTH_FACTOR).
     * @param user The address of the user to check.
     * @dev Reverts with DSCEngine__BreaksHealthFactor error if health factor is too low.
     */
    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
        }
    }

    // Getter functions
    /** @notice Gets the amount of a specific collateral token deposited by a user. */
    function getCollateralBalanceOfUser(address user, address token) external view returns (uint256) {
        return s_collateralDeposited[user][token];
    }

    /** @notice Gets the precision value used in calculations (1e18). */
    function getPrecision() external pure returns (uint256) {
        return PRECISION;
    }

    /** @notice Gets the additional precision factor for price feeds (1e10). */
    function getAdditionalFeedPrecision() external pure returns (uint256) {
        return ADDITIONAL_FEED_PRECISION;
    }

    /** @notice Gets the liquidation threshold (e.g., 50 for 200% collateralization). */
    function getLiquidationThreshold() external pure returns (uint256) {
        return LIQUIDATION_THRESHOLD;
    }

    /** @notice Gets the liquidation bonus percentage for liquidators (e.g., 10 for 10%). */
    function getLiquidationBonus() external pure returns (uint256) {
        return LIQUIDATION_BONUS;
    }

    /** @notice Gets the liquidation precision (denominator for threshold, typically 100). */
    function getLiquidationPrecision() external pure returns (uint256) {
        return LIQUIDATION_PRECISION;
    }

    /** @notice Gets the minimum health factor required (1e18). */
    function getMinHealthFactor() external pure returns (uint256) {
        return MIN_HEALTH_FACTOR;
    }

    /** @notice Gets the list of allowed collateral token addresses. */
    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }

    /** @notice Gets the address of the DSC token contract. */
    function getDsc() external view returns (address) {
        return address(i_dsc);
    }

    /** @notice Gets the price feed address for a given collateral token. */
    function getCollateralTokenPriceFeed(address token) external view returns (address) {
        return s_priceFeeds[token];
    }

    /** @notice Gets the current health factor for a given user. */
    function getHealthFactor(address user) external view returns (uint256) {
        return _healthFactor(user);
    }
}
