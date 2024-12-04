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
    error DecentralizedStableCoin__BurnAmountExceedsBalance();
    error DecentralizedStableCoin__NotZeroAddress();

    constructor() ERC20("DecentralizedStableCoin", "DSC") Ownable(msg.sender) {} //name of our stable coin and symbol

    function burn(uint256 _amount) public override onlyOwner {
        uint256 balance = balanceOf(msg.sender); //balance of the msg.sender

        if (_amount <= 0) {
            //amount to burn is less than the zero
            revert DecentralizedStableCoin__MustBeMoreThanZero();
        }
        if (balance < _amount) {
            // amount to burn is less then the actual balance of the sender
            revert DecentralizedStableCoin__BurnAmountExceedsBalance();
        }
        super.burn(_amount); //use the burn function from the parent class
    }

    function mint(
        address _to,
        uint256 _amount
    ) external onlyOwner returns (bool) {
        if (_to == address(0)) {
            // dont mint to zero address
            revert DecentralizedStableCoin__NotZeroAddress();
        }
        if (_amount <= 0) {
            revert DecentralizedStableCoin__MustBeMoreThanZero();
        }

        _mint(_to, _amount); //
        return true;
    }
}
