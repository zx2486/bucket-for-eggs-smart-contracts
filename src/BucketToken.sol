// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/**
 * @title BucketToken
 * @dev ERC-20 token with minting, burning, pausing, and permit functionality
 *
 * Features:
 * - Minting: Owner can mint new tokens
 * - Burning: Token holders can burn their tokens
 * - Pausable: Owner can pause all token transfers
 * - Permit: EIP-2612 gasless approvals
 */
contract BucketToken is
    ERC20,
    ERC20Burnable,
    ERC20Pausable,
    Ownable,
    ERC20Permit
{
    /// @dev Maximum supply cap (optional - remove if unlimited supply is desired)
    uint256 public constant MAX_SUPPLY = 1_000_000_000 * 10 ** 18; // 1 billion tokens

    /**
     * @dev Constructor that gives msg.sender all of existing tokens
     * @param initialOwner Address that will own the contract
     * @param initialSupply Initial supply to mint
     */
    constructor(
        address initialOwner,
        uint256 initialSupply
    )
        ERC20("Bucket Token", "BUCKET")
        Ownable(initialOwner)
        ERC20Permit("Bucket Token")
    {
        require(
            initialSupply <= MAX_SUPPLY,
            "Initial supply exceeds max supply"
        );
        _mint(initialOwner, initialSupply);
    }

    /**
     * @dev Mint new tokens (only owner)
     * @param to Address to mint tokens to
     * @param amount Amount of tokens to mint
     */
    function mint(address to, uint256 amount) public onlyOwner {
        require(
            totalSupply() + amount <= MAX_SUPPLY,
            "Minting would exceed max supply"
        );
        _mint(to, amount);
    }

    /**
     * @dev Pause token transfers (only owner)
     */
    function pause() public onlyOwner {
        _pause();
    }

    /**
     * @dev Unpause token transfers (only owner)
     */
    function unpause() public onlyOwner {
        _unpause();
    }

    /**
     * @dev Hook that is called before any transfer of tokens
     * @param from Address tokens are transferred from
     * @param to Address tokens are transferred to
     * @param value Amount of tokens transferred
     */
    function _update(
        address from,
        address to,
        uint256 value
    ) internal override(ERC20, ERC20Pausable) {
        super._update(from, to, value);
    }
}
