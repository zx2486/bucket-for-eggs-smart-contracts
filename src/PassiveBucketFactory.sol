// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PassiveBucket} from "./PassiveBucket.sol";

/**
 * @title PassiveBucketFactory
 * @author Bucket-for-Eggs Team
 * @notice Factory contract to deploy UUPS proxies of PassiveBucket.
 * @dev Each deployed proxy is a fully independent PassiveBucket instance owned
 * by the caller. The factory stores the shared implementation address and
 * tracks deployed proxy addresses for discovery purposes.
 */
contract PassiveBucketFactory {
    /// @notice The PassiveBucket implementation contract used by all proxies
    address public immutable implementation;

    /// @notice The BucketInfo contract every proxy deployed through this factory is wired to.
    /// @dev W1.7: constructor-set-and-immutable, never caller-supplied. See the identical doc
    /// comment on `ActiveBucketFactory.bucketInfo` for the full rationale (workspace CLAUDE.md
    /// §1.1 precondition under the ownership table).
    address public immutable bucketInfo;

    /// @notice All proxy addresses deployed through this factory
    address[] public deployedProxies;

    /// @notice Emitted when a new PassiveBucket proxy is deployed
    event PassiveBucketCreated(
        address indexed proxy, address indexed owner, address indexed bucketInfo, string name, string symbol
    );

    error InvalidImplementation();
    error InvalidBucketInfo();
    error InvalidOneInchRouter();

    /**
     * @notice Constructor
     * @param implementation_ Address of the deployed PassiveBucket implementation contract
     * @param bucketInfo_ Address of the BucketInfo contract every proxy from this factory will use
     */
    constructor(address implementation_, address bucketInfo_) {
        if (implementation_ == address(0)) revert InvalidImplementation();
        if (bucketInfo_ == address(0)) revert InvalidBucketInfo();
        implementation = implementation_;
        bucketInfo = bucketInfo_;
    }

    /**
     * @notice Deploy a new PassiveBucket proxy and initialise it
     * @dev The caller becomes the owner of the new contract. Distributions,
     * DEX configs, and WETH can be configured after deployment by the owner.
     * The BucketInfo address is this factory's own immutable {bucketInfo} — it is no longer a
     * caller-supplied parameter (W1.7; see the doc comment on {bucketInfo}).
     * @param distributions    Initial token distributions (weights must sum to 100)
     * @param oneInchRouter    Address of the 1inch aggregation router
     * @param name             ERC-20 token name for the share token
     * @param symbol           ERC-20 token symbol for the share token
     * @return proxy Address of the newly deployed PassiveBucket proxy
     */
    function createPassiveBucket(
        PassiveBucket.BucketDistribution[] calldata distributions,
        address oneInchRouter,
        string calldata name,
        string calldata symbol
    ) external returns (address proxy) {
        if (oneInchRouter == address(0)) revert InvalidOneInchRouter();

        // Encode the initializer call using the factory's own immutable bucketInfo, never a
        // caller-supplied value.
        bytes memory initData =
            abi.encodeCall(PassiveBucket.initialize, (bucketInfo, distributions, oneInchRouter, name, symbol));

        // Deploy a new ERC-1967 UUPS proxy pointing at the shared implementation
        proxy = address(new ERC1967Proxy(implementation, initData));

        // Transfer ownership from this factory to the caller.
        // initialize() sets owner = msg.sender which is this factory during the proxy
        // constructor, so we must transfer it immediately.
        PassiveBucket(payable(proxy)).transferOwnership(msg.sender);

        // Track the deployment
        deployedProxies.push(proxy);

        emit PassiveBucketCreated(proxy, msg.sender, bucketInfo, name, symbol);
    }

    /**
     * @notice Get the total number of proxies deployed through this factory
     * @return count Number of deployed proxies
     */
    function getDeployedProxiesCount() external view returns (uint256 count) {
        return deployedProxies.length;
    }

    /**
     * @notice Get all proxy addresses deployed through this factory
     * @return proxies Array of all deployed proxy addresses
     */
    function getAllDeployedProxies() external view returns (address[] memory proxies) {
        return deployedProxies;
    }
}
