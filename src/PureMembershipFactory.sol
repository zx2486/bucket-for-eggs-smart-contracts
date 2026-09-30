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

    /// @notice The BucketInfo contract every proxy deployed through this factory is wired to.
    /// @dev W1.7: constructor-set-and-immutable, never caller-supplied. See the identical doc
    /// comment on `ActiveBucketFactory.bucketInfo` for the full rationale (workspace CLAUDE.md
    /// §1.1 precondition under the ownership table).
    address public immutable bucketInfo;

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
     * @param bucketInfo_ Address of the BucketInfo contract every proxy from this factory will use
     */
    constructor(address implementation_, address bucketInfo_) {
        if (implementation_ == address(0)) revert InvalidImplementation();
        if (bucketInfo_ == address(0)) revert InvalidBucketInfo();
        implementation = implementation_;
        bucketInfo = bucketInfo_;
    }

    /**
     * @notice Deploy a new PureMembership proxy and initialise it
     * @dev The caller becomes the owner of the new contract.  All membership
     * configuration is set at construction time; additional configs can be
     * added later by the owner through `addMembershipConfig`.
     * The BucketInfo address is this factory's own immutable {bucketInfo} — it is no longer a
     * caller-supplied parameter (W1.7; see the doc comment on {bucketInfo}).
     * @param configs Initial membership tier configurations
     * @param uri     ERC-1155 metadata URI (e.g. "https://api.example.com/metadata/{id}.json")
     * @return proxy Address of the newly deployed PureMembership proxy
     */
    function createPureMembership(PureMembership.MembershipConfig[] calldata configs, string calldata uri)
        external
        returns (address payable proxy)
    {
        // Encode the initializer call using the factory's own immutable bucketInfo, never a
        // caller-supplied value. Arity unchanged from before this fix (3 args) -- only the
        // source of the bucketInfo argument's value changed.
        bytes memory initData = abi.encodeCall(PureMembership.initialize, (configs, bucketInfo, uri));

        // Deploy a new ERC-1967 UUPS proxy pointing at the shared implementation
        proxy = payable(new ERC1967Proxy(implementation, initData));

        // Transfer ownership from this factory (msg.sender of initialize) to the caller.
        // initialize() sets owner = msg.sender which is this factory during the proxy
        // constructor, so we must transfer it immediately.
        PureMembership(proxy).transferOwnership(msg.sender);

        // Track the deployment
        deployedProxies.push(proxy);

        emit PureMembershipCreated(proxy, msg.sender, bucketInfo, uri);
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
