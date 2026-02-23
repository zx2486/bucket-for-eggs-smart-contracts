// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PureMembership} from "./PureMembership.sol";

/**
 * @title PureMembershipFactory
 * @author Bucket-for-Eggs Team
 * @notice Factory contract to deploy UUPS proxies of PureMembership.
 * @dev Each deployed proxy is a fully independent PureMembership instance owned
 * by the caller. The factory only stores the shared implementation address and
 * tracks deployed proxy addresses for discovery purposes.
 */
contract PureMembershipFactory {
    /// @notice The PureMembership implementation contract used by all proxies
    address public immutable implementation;

    /// @notice All proxy addresses deployed through this factory
    address[] public deployedProxies;

    /// @notice Emitted when a new PureMembership proxy is deployed
    /// @param proxy Address of the newly created proxy
    /// @param owner Owner of the new membership contract
    /// @param bucketInfo BucketInfo contract wired to this instance
    /// @param uri ERC-1155 metadata URI
    event PureMembershipCreated(address indexed proxy, address indexed owner, address indexed bucketInfo, string uri);

    error InvalidImplementation();
    error InvalidBucketInfo();

    /**
     * @notice Constructor
     * @param implementation_ Address of the deployed PureMembership implementation contract
     */
    constructor(address implementation_) {
        if (implementation_ == address(0)) revert InvalidImplementation();
        implementation = implementation_;
    }

    /**
     * @notice Deploy a new PureMembership proxy and initialise it
     * @dev The caller becomes the owner of the new contract.  All membership
     * configuration is set at construction time; additional configs can be
     * added later by the owner through `addMembershipConfig`.
     * @param configs       Initial membership tier configurations
     * @param bucketInfoAddr Address of the BucketInfo contract
     * @param uri           ERC-1155 metadata URI (e.g. "https://api.example.com/metadata/{id}.json")
     * @return proxy Address of the newly deployed PureMembership proxy
     */
    function createPureMembership(
        PureMembership.MembershipConfig[] calldata configs,
        address bucketInfoAddr,
        string calldata uri
    ) external returns (address proxy) {
        if (bucketInfoAddr == address(0)) revert InvalidBucketInfo();

        // Encode the initializer call
        bytes memory initData = abi.encodeCall(PureMembership.initialize, (configs, bucketInfoAddr, uri));

        // Deploy a new ERC-1967 UUPS proxy pointing at the shared implementation
        proxy = address(new ERC1967Proxy(implementation, initData));

        // Transfer ownership from this factory (msg.sender of initialize) to the caller.
        // initialize() sets owner = msg.sender which is this factory during the proxy
        // constructor, so we must transfer it immediately.
        PureMembership(proxy).transferOwnership(msg.sender);

        // Track the deployment
        deployedProxies.push(proxy);

        emit PureMembershipCreated(proxy, msg.sender, bucketInfoAddr, uri);
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
