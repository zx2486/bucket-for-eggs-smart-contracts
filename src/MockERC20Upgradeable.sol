// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/**
 * @title MockERC20Upgradeable
 * @notice Upgradeable ERC20 token for testing purposes with fixed supply
 * @dev Uses OpenZeppelin's upgradeable contracts pattern
 */
contract MockERC20Upgradeable is Initializable, ERC20Upgradeable {
    uint8 private _decimals;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the token contract
     * @param name_ Token name
     * @param symbol_ Token symbol
     * @param decimals_ Number of decimals
     * @param initialSupply_ Initial supply in whole tokens (will be multiplied by 10^decimals)
     * @param recipient_ Address to receive the initial supply
     */
    function initialize(
        string memory name_,
        string memory symbol_,
        uint8 decimals_,
        uint256 initialSupply_,
        address recipient_
    ) external initializer {
        __ERC20_init(name_, symbol_);
        _decimals = decimals_;

        if (initialSupply_ > 0) {
            _mint(recipient_, initialSupply_ * 10 ** decimals_);
        }
    }

    /**
     * @notice Returns the number of decimals
     * @return Number of decimals used by the token
     */
    function decimals() public view virtual override returns (uint8) {
        return _decimals;
    }

    /**
     * @notice Mint additional tokens (for testing purposes)
     * @param to Address to mint tokens to
     * @param amount Amount in whole tokens
     */
    function mint(address to, uint256 amount) external {
        _mint(to, amount * 10 ** _decimals);
    }
}
