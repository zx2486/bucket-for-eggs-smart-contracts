// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ActiveBucket} from "./ActiveBucket.sol";

/**
 * @title ActiveBucketFactory
 * @author Bucket-for-Eggs Team
 * @notice Factory contract to deploy UUPS proxies of ActiveBucket.
 * @dev Each deployed proxy is a fully independent ActiveBucket instance owned
 * by the caller. The factory stores the shared implementation address and
 * tracks deployed proxy addresses for discovery purposes.
 */
contract ActiveBucketFactory {
    /// @notice The ActiveBucket implementation contract used by all proxies
    address public immutable implementation;

    /// @notice The BucketInfo contract every proxy deployed through this factory is wired to.
    /// @dev W1.7: constructor-set-and-immutable, never caller-supplied. Workspace CLAUDE.md §1.1
    /// (the precondition under the ownership table): before this fix, `bucketInfoAddr` was a
    /// caller-supplied parameter to {createActiveBucket}, so an untrusted customer could point a
    /// vault at a `BucketInfo`-shaped contract they control, defeating the 00:44 oracle
    /// protection (`updateBucketInfo` is gated on *BucketInfo's* owner precisely so a vault owner
    /// cannot swap the price feed) and any upgrade registry reached through that pointer. Making
    /// this immutable and factory-set closes that path the same way `implementation` (`:17`,
    /// already immutable) closes the analogous implementation-swap path.
    address public immutable bucketInfo;

    /// @notice All proxy addresses deployed through this factory
    address[] public deployedProxies;

    /// @notice Emitted when a new ActiveBucket proxy is deployed
    event ActiveBucketCreated(
        address indexed proxy, address indexed owner, address indexed bucketInfo, string name, string symbol
    );

    error InvalidImplementation();
    error InvalidBucketInfo();
    error InvalidOneInchRouter();

    /**
     * @notice Constructor
     * @param implementation_ Address of the deployed ActiveBucket implementation contract
     * @param bucketInfo_ Address of the BucketInfo contract every proxy from this factory will use
     */
    constructor(address implementation_, address bucketInfo_) {
        if (implementation_ == address(0)) revert InvalidImplementation();
        if (bucketInfo_ == address(0)) revert InvalidBucketInfo();
        implementation = implementation_;
        bucketInfo = bucketInfo_;
    }

    /**
     * @notice Deploy a new ActiveBucket proxy and initialise it
     * @dev The caller becomes the owner of the new contract. Portfolio
     * composition is managed by the owner via swapBy1inch and flashLoan.
     * The BucketInfo address is this factory's own immutable {bucketInfo} — it is no longer a
     * caller-supplied parameter (W1.7; see the doc comment on {bucketInfo}).
     * @param oneInchRouter    Address of the 1inch aggregation router
     * @param name             ERC-20 token name for the share token
     * @param symbol           ERC-20 token symbol for the share token
     * @return proxy Address of the newly deployed ActiveBucket proxy
     */
    function createActiveBucket(address oneInchRouter, string calldata name, string calldata symbol)
        external
        returns (address proxy)
    {
        if (oneInchRouter == address(0)) revert InvalidOneInchRouter();

        // Encode the initializer call using the factory's own immutable bucketInfo, never a
        // caller-supplied value.
        bytes memory initData = abi.encodeCall(ActiveBucket.initialize, (bucketInfo, oneInchRouter, name, symbol));

        // Deploy a new ERC-1967 UUPS proxy pointing at the shared implementation
        proxy = address(new ERC1967Proxy(implementation, initData));

        // Transfer ownership from this factory to the caller.
        // initialize() sets owner = msg.sender which is this factory during the proxy
        // constructor, so we must transfer it immediately.
        ActiveBucket(payable(proxy)).transferOwnership(msg.sender);

        // Track the deployment
        deployedProxies.push(proxy);

        emit ActiveBucketCreated(proxy, msg.sender, bucketInfo, name, symbol);
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
