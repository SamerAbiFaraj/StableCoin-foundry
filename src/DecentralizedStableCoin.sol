//SPDX-License-Identifier:MIT

pragma solidity ^0.8.19;

/**
 * @title DecentralizedStableCoin
 * @author Samer Abi Faraj
 * Collateral: Exogenenous (ETH & BTC)
 * Minting: Algorithmic  (means will be decentralized)
 * Relative Stability: Pegged to USD
 *
 *
 * This is the contract meant to be governed by DSCEngine. This contract is just the ERC20 implementation
 * of our stablecoin system.
 */
import {ERC20Burnable, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract DecentralizedStableCoin is ERC20Burnable, Ownable {
    error DecentralizedStableCoin__MustBeMoreThanZero();
    error DecentralizedStableCoin__BurnAmountExceedsBalance(); // Kept for clarity, though OZ's _burn also checks
    error DecentralizedStableCoin__NotZeroAddress(); // Kept for clarity, though OZ's _mint also checks

    /**
     * @notice Initializes the DSC token with a name, symbol, and sets the deployer as the initial owner.
     */
    constructor() ERC20("DecentralizedStableCoin", "DSC") Ownable(msg.sender) {}

    /**
     * @notice Burns a specified amount of tokens from the contract owner (DSCEngine).
     * @dev This function can only be called by the owner (DSCEngine).
     * The DSCEngine should have received these tokens from a user before calling burn.
     * @param _amount The amount of tokens to burn.
     */
    function burn(uint256 _amount) public override onlyOwner {
        if (_amount <= 0) {
            revert DecentralizedStableCoin__MustBeMoreThanZero();
        }
        // The `super.burn(_amount)` called by `ERC20Burnable`'s default `burn(uint256 value)`
        // eventually calls `_burn(msg.sender, _amount)`.
        // OpenZeppelin's `_burn` internal function already checks for sufficient balance of `msg.sender`.
        // So, the explicit balance check `if (balanceOf(msg.sender) < _amount)` is redundant here.
        super.burn(_amount);
    }

    /**
     * @notice Mints a specified amount of tokens to a given address.
     * @dev This function can only be called by the owner (DSCEngine).
     * @param _to The address to mint tokens to.
     * @param _amount The amount of tokens to mint.
     * @return True if minting was successful.
     */
    function mint(address _to, uint256 _amount) external onlyOwner returns (bool) {
        // OpenZeppelin's `_mint` internal function already checks if `_to` is address(0).
        // So, the explicit check `if (_to == address(0))` is redundant here.
        // if (_to == address(0)) {
        //     revert DecentralizedStableCoin__NotZeroAddress();
        // }
        if (_amount <= 0) {
            revert DecentralizedStableCoin__MustBeMoreThanZero();
        }
        _mint(_to, _amount);
        return true;
    }
}
