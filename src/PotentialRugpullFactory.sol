// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {PotentialRugpull} from "./PotentialRugpull.sol";

/**
 * @title PotentialRugpullFactory
 * @author Bucket-for-Eggs Team
 * @notice Factory contract to deploy `PotentialRugpull` instances (W5.1, SC-8, task #63).
 * @dev Deliberately DOES NOT follow the `ERC1967Proxy` + `initialize()` pattern the other three
 * factories ({ActiveBucketFactory}, {PassiveBucketFactory}, {PureMembershipFactory}) use.
 * `PotentialRugpull` is a plain, non-upgradeable contract — see `PotentialRugpull.sol`'s
 * DECISION 1 header comment for the full rationale (the client's literal "constructor will only
 * take one variable" constraint, corroborated by `IImplementationRegistry.Kind` excluding
 * `PotentialRugpull` from the three-member enum that drives the platform's upgrade-whitelist
 * machinery). This factory instead deploys via a direct `new PotentialRugpull(cashRatio_)` call,
 * then immediately calls the freshly-deployed instance's one-shot, factory-only
 * `initialize(bucketInfo_, owner_, name_, symbol_)` in the SAME transaction — the
 * deferred-parameter pattern `PotentialRugpull.sol` documents in full.
 * @dev `bucketInfo` is this factory's own constructor-set-and-immutable value, mirroring W1.7's
 * fix on the other three factories (root CLAUDE.md §1.1's precondition: the vault's `BucketInfo`
 * pointer must never be caller-suppliable, or a customer could point their vault at a
 * `BucketInfo`-shaped contract they control). `PotentialRugpull`'s own constructor could not
 * carry this value directly (the one-variable constraint), which is exactly why the deferred
 * `initialize` call exists — and this factory supplies that value from ITS OWN immutable, never
 * from anything the `createPotentialRugpull` caller passes in.
 */
contract PotentialRugpullFactory {
    /// @notice The BucketInfo contract every PotentialRugpull deployed through this factory is
    /// wired to. Constructor-set-and-immutable, never caller-supplied — see header comment.
    address public immutable bucketInfo;

    /// @notice All PotentialRugpull addresses deployed through this factory.
    address[] public deployedRugpulls;

    /// @notice Emitted when a new PotentialRugpull is deployed.
    event PotentialRugpullCreated(
        address indexed instance,
        address indexed owner,
        address indexed bucketInfo,
        uint256 cashRatio,
        string name,
        string symbol
    );

    error InvalidBucketInfo();

    /**
     * @notice Constructor
     * @param bucketInfo_ Address of the BucketInfo contract every instance from this factory will use
     */
    constructor(address bucketInfo_) {
        if (bucketInfo_ == address(0)) revert InvalidBucketInfo();
        bucketInfo = bucketInfo_;
    }

    /**
     * @notice Deploy a new PotentialRugpull instance and initialise it.
     * @dev The caller becomes the owner of the new contract, exactly as with the other three
     * factories — the `…Created` event names `msg.sender`, and {initialize} mints the default
     * share and transfers ownership to that same address within this one transaction, so no
     * indexer ever observes a window where the factory appears to be the owner.
     * @param cashRatio_ The protection ratio (10-90), passed straight through to
     * `PotentialRugpull`'s constructor — this is the ONLY business parameter its constructor
     * accepts, per the client's literal constraint.
     * @param name_ ERC-20 token name for the share token
     * @param symbol_ ERC-20 token symbol for the share token
     * @return instance Address of the newly deployed PotentialRugpull
     */
    function createPotentialRugpull(uint256 cashRatio_, string calldata name_, string calldata symbol_)
        external
        returns (address instance)
    {
        // Deploy directly — NOT an ERC1967Proxy. PotentialRugpull is non-upgradeable by design
        // (see PotentialRugpull.sol DECISION 1).
        PotentialRugpull rugpull = new PotentialRugpull(cashRatio_);
        instance = address(rugpull);

        // One-shot, factory-only completion of setup the single-variable constructor could not
        // carry: the real BucketInfo pointer (this factory's own immutable, never caller-
        // supplied), the real owner (msg.sender, not this factory), and per-instance name/symbol.
        rugpull.initialize(bucketInfo, msg.sender, name_, symbol_);

        deployedRugpulls.push(instance);

        emit PotentialRugpullCreated(instance, msg.sender, bucketInfo, cashRatio_, name_, symbol_);
    }

    /**
     * @notice Get the total number of PotentialRugpull instances deployed through this factory
     * @return count Number of deployed instances
     */
    function getDeployedRugpullsCount() external view returns (uint256 count) {
        return deployedRugpulls.length;
    }

    /**
     * @notice Get all PotentialRugpull addresses deployed through this factory
     * @return instances Array of all deployed instance addresses
     */
    function getAllDeployedRugpulls() external view returns (address[] memory instances) {
        return deployedRugpulls;
    }
}
