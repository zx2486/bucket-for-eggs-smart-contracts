// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {MockERC20Upgradeable} from "./MockERC20Upgradeable.sol";

/**
 * @title MockERC20Factory
 * @notice Factory contract to deploy minimal proxies (EIP-1167) of MockERC20Upgradeable
 * @dev Uses OpenZeppelin's Clones library for gas-efficient proxy deployment
 */
contract MockERC20Factory {
    using Clones for address;

    /// @notice The implementation contract address
    address public immutable implementation;

    /// @notice Array of all deployed proxy addresses
    address[] public deployedProxies;

    /// @notice Event emitted when a new proxy is created
    event ProxyCreated(
        address indexed proxy,
        string name,
        string symbol,
        uint8 decimals,
        uint256 initialSupply,
        address indexed recipient
    );

    /**
     * @notice Constructor
     * @param implementation_ Address of the MockERC20Upgradeable implementation contract
     */
    constructor(address implementation_) {
        require(implementation_ != address(0), "Invalid implementation address");
        implementation = implementation_;
    }

    /**
     * @notice Create a new ERC20 proxy token
     * @param name_ Token name
     * @param symbol_ Token symbol
     * @param decimals_ Number of decimals
     * @param initialSupply_ Initial supply in whole tokens
     * @param recipient_ Address to receive the initial supply
     * @return proxy Address of the newly created proxy
     */
    function createToken(
        string memory name_,
        string memory symbol_,
        uint8 decimals_,
        uint256 initialSupply_,
        address recipient_
    ) external returns (address proxy) {
        // Create minimal proxy clone
        proxy = implementation.clone();

        // Initialize the proxy
        MockERC20Upgradeable(proxy).initialize(
            name_,
            symbol_,
            decimals_,
            initialSupply_,
            recipient_
        );

        // Track deployed proxy
        deployedProxies.push(proxy);

        emit ProxyCreated(proxy, name_, symbol_, decimals_, initialSupply_, recipient_);

        return proxy;
    }

    /**
     * @notice Create a new ERC20 proxy token with deterministic address
     * @param name_ Token name
     * @param symbol_ Token symbol
     * @param decimals_ Number of decimals
     * @param initialSupply_ Initial supply in whole tokens
     * @param recipient_ Address to receive the initial supply
     * @param salt_ Salt for deterministic deployment
     * @return proxy Address of the newly created proxy
     */
    function createTokenDeterministic(
        string memory name_,
        string memory symbol_,
        uint8 decimals_,
        uint256 initialSupply_,
        address recipient_,
        bytes32 salt_
    ) external returns (address proxy) {
        // Create deterministic minimal proxy clone
        proxy = implementation.cloneDeterministic(salt_);

        // Initialize the proxy
        MockERC20Upgradeable(proxy).initialize(
            name_,
            symbol_,
            decimals_,
            initialSupply_,
            recipient_
        );

        // Track deployed proxy
        deployedProxies.push(proxy);

        emit ProxyCreated(proxy, name_, symbol_, decimals_, initialSupply_, recipient_);

        return proxy;
    }

    /**
     * @notice Predict the address of a deterministic clone
     * @param salt_ Salt for deterministic deployment
     * @return predicted Address that will be used for the clone
     */
    function predictDeterministicAddress(bytes32 salt_) external view returns (address predicted) {
        return implementation.predictDeterministicAddress(salt_, address(this));
    }

    /**
     * @notice Get the number of deployed proxies
     * @return count Number of proxies deployed
     */
    function getDeployedProxiesCount() external view returns (uint256 count) {
        return deployedProxies.length;
    }

    /**
     * @notice Get all deployed proxy addresses
     * @return proxies Array of all deployed proxy addresses
     */
    function getAllDeployedProxies() external view returns (address[] memory proxies) {
        return deployedProxies;
    }
}
