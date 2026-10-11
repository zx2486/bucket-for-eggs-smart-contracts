// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC1155Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC1155/ERC1155Upgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IBucketInfo} from "./interfaces/IBucketInfo.sol";
import {IImplementationRegistry} from "./interfaces/IImplementationRegistry.sol";
import {TimelockedAdmin} from "./libs/TimelockedAdmin.sol";
import {SeizureLib} from "./libraries/SeizureLib.sol";

/**
 * @title PureMembership
 * @author Bucket-for-Eggs Team
 * @notice Upgradeable ERC-1155 membership management contract. Tokens represent
 * membership cards with levels, prices, duration, and expiration tracking.
 * Users buy memberships with whitelisted tokens, and the owner can withdraw revenue.
 * @dev Uses UUPS proxy pattern. Each token ID maps to a membership configuration.
 */
contract PureMembership is
    Initializable,
    ERC1155Upgradeable,
    PausableUpgradeable,
    OwnableUpgradeable,
    ReentrancyGuardTransient,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;
    using TimelockedAdmin for TimelockedAdmin.AddressTimelock;

    /*//////////////////////////////////////////////////////////////
                                STRUCTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Membership level configuration
    /// @param tokenId The ERC-1155 token ID for this membership
    /// @param level The membership level (higher = better)
    /// @param name The membership name
    /// @param price The membership price in USD (8 decimals)
    /// @param duration The membership duration in seconds
    struct MembershipConfig {
        uint256 tokenId;
        uint256 level;
        string name;
        uint256 price;
        uint256 duration;
    }

    /// @notice User membership info for external queries
    struct UserMembership {
        uint256 tokenId;
        uint256 level;
        string name;
        uint256 expiryTime;
        bool isActive;
    }

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice BucketInfo contract for token validation and pricing
    IBucketInfo public bucketInfo;

    /// @notice Membership configuration per token ID
    mapping(uint256 => MembershipConfig) public membershipConfigs;

    /// @notice Array of all configured token IDs
    uint256[] public configuredTokenIds;

    /// @notice User membership expiration: user => tokenId => expiry timestamp
    mapping(address => mapping(uint256 => uint256)) public membershipExpiry;

    /// @notice Accumulated revenue by payment token address
    mapping(address => uint256) public revenueByToken;

    /// @notice Accumulated withdrawals by token address
    mapping(address => uint256) public withdrawnByToken;

    /// @notice Total revenue withdrawn across all tokens
    uint256 public totalWithdrawn;

    /// @notice Active membership count per level
    mapping(uint256 => uint256) public activeMembershipCount;

    /// @notice Owner-set ceiling on `paymentAmount` accepted per `buyMembership` call.
    /// 0 (the storage default) means "no owner-side cap". Denominated in the raw
    /// units of whichever `payTokenAddress` is used for a given call. See
    /// `setMaxPaymentAmount` for why this cannot be set from `initialize()`.
    uint256 public maxPaymentAmount;

    /// @notice Pending propose+timelock+veto state for {proposeUpdateBucketInfo} /
    /// {vetoUpdateBucketInfo} / {executeUpdateBucketInfo}.
    TimelockedAdmin.AddressTimelock private _bucketInfoUpdateTimelock;

    /// @dev Propose→execute delay for `updateBucketInfo`, giving investors a veto window before
    /// the pointer changes.
    uint256 public constant BUCKET_INFO_UPDATE_TIMELOCK_DELAY = 48 hours;

    /// @notice The platform-owned {ImplementationRegistry} this contract's upgrades are checked
    /// against. Immutable, constructor-set, never repointable -- the whitelist authority itself
    /// must not be swappable by this contract's (customer) owner.
    IImplementationRegistry public immutable REGISTRY;

    /// @notice Pending queue+timelock state for {queueUpgrade} / {cancelUpgrade} /
    /// {_authorizeUpgrade}.
    TimelockedAdmin.AddressTimelock private _upgradeTimelock;

    /// @dev Queue(propose)→execute delay for the UUPS upgrade path. Exactly 48 hours, no bypass.
    uint256 public constant UPGRADE_TIMELOCK_DELAY = 48 hours;

    /// @notice Pending seizure state for {proposeSeizure} / {cancelSeizure} / {executeSeizure},
    /// keyed by the account being seized from.
    mapping(address => TimelockedAdmin.SeizureTimelock) private _seizureTimelocks;

    /// @dev Same 48-hour delay used platform-wide for timelocked governance actions. No external
    /// getter is needed since the value is already public via {SeizureLib.SeizureProposed}'s
    /// emitted `eta`.
    uint256 internal constant SEIZURE_TIMELOCK_DELAY = 48 hours;

    /// @dev BPS scale used by the local defensive fee clamp.
    uint256 public constant BPS_DENOMINATOR = 10_000;

    /// @dev Defensive ceiling on the fee taken from a {withdrawRevenue} amount, mirrored
    /// against BucketInfo's own platform-fee cap. Re-checked here even though BucketInfo
    /// already enforces it.
    uint256 public constant MAX_LOCAL_PLATFORM_FEE_BPS = 1000;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event MembershipPurchased(
        address indexed user,
        uint256 indexed tokenId,
        uint256 level,
        address payToken,
        uint256 payAmount,
        uint256 expiryTime
    );
    event MembershipRenewed(
        address indexed user,
        uint256 indexed tokenId,
        uint256 level,
        address payToken,
        uint256 payAmount,
        uint256 newExpiryTime
    );
    event MembershipCancelled(address indexed user, uint256 indexed tokenId, uint256 level);
    event RevenueWithdrawn(address indexed to, address indexed token, uint256 amount, uint256 fee);
    event TokensRecovered(address indexed token, address indexed to, uint256 amount);
    event BucketInfoUpdated(address indexed oldBucketInfo, address indexed newBucketInfo, address indexed updatedBy);
    /// @notice Emitted by {proposeUpdateBucketInfo}. `eta` is when {executeUpdateBucketInfo}
    /// becomes callable absent a veto.
    event BucketInfoUpdateProposed(
        address indexed oldBucketInfo, address indexed proposedBucketInfo, address indexed proposedBy, uint256 eta
    );
    /// @notice Emitted by {vetoUpdateBucketInfo}.
    event BucketInfoUpdateVetoed(address indexed vetoedBucketInfo, address indexed vetoedBy);
    event MaxPaymentAmountUpdated(uint256 oldMax, uint256 newMax);
    /// @notice Emitted by {queueUpgrade}. `vault` lets a multi-vault indexer watch every vault's
    /// pending upgrades without an archive node.
    event UpgradeQueued(address indexed vault, address indexed newImplementation, uint256 eta);
    /// @notice Emitted by {cancelUpgrade}. `implementation` is the address that was pending and
    /// will now never execute.
    event UpgradeCancelled(address indexed vault, address indexed implementation);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error PlatformNotOperational();
    error InvalidToken(address token);
    error InvalidTokenId(uint256 tokenId);
    error ZeroAddress();
    /// @dev Thrown by `initialize()` when `msg.sender` is not a factory the platform has
    /// authorized via `IImplementationRegistry.setAuthorizedFactory`.
    error UnauthorizedInitializer();
    error ZeroAmount();
    error InsufficientPayment(uint256 required, uint256 provided);
    error NoActiveMembership();
    error MembershipExpired();
    error InsufficientContractBalance(uint256 requested, uint256 available);
    error ETHTransferFailed();
    error CannotRecoverWhitelistedToken(address token);
    error UnauthorizedBucketInfoUpdate();
    error PaymentExceedsMaxAmount(uint256 paymentAmount, uint256 maxAllowed);
    /// @dev Thrown by {_update} when either side of a mint/burn/transfer is blacklisted, or
    /// when `BucketInfo` cannot be reached to answer that question (fail-closed).
    error Blacklisted(address account);
    /// @dev Thrown by {_update} for any transfer that is neither a mint (`from == address(0)`)
    /// nor a burn (`to == address(0)`) -- i.e. any holder-to-holder transfer of a membership
    /// token, which must never be allowed regardless of blacklist status.
    error MembershipNotTransferable();
    /// @dev The implementation actually installed via UUPS's `upgradeToAndCall` at execution
    /// time must be byte-identical to the one announced at queue time.
    error UpgradeImplementationMismatch(address expected, address provided);
    /// @dev The platform ({ImplementationRegistry}) has not (or no longer) approved this
    /// implementation for this contract's `Kind`. Re-checked at execution time, not just at
    /// queue time, so a mid-window revocation actually blocks the upgrade.
    error UpgradeNotApproved(address implementation);
    /// @dev Thrown by {renounceOwnership}, which is always disabled so ownership can never be
    /// abandoned, leaving every `onlyOwner` path permanently uncontrolled.
    error RenounceOwnershipDisabled();

    /*//////////////////////////////////////////////////////////////
                              MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier whenPlatformOperational() {
        if (!bucketInfo.isPlatformOperational()) {
            revert PlatformNotOperational();
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////
                      COMPLIANCE — BLACKLIST + SOULBOUND
    //////////////////////////////////////////////////////////////*/

    /// @dev Fail-closed read of `bucketInfo.isBlacklisted(account)`. Never reverts itself:
    /// `true` stands in for both "actually blacklisted" and "BucketInfo unreachable".
    function _isBlacklistedFailClosed(address account) internal view returns (bool) {
        try bucketInfo.isBlacklisted(account) returns (bool blacklisted) {
            return blacklisted;
        } catch {
            return true;
        }
    }

    /// @dev Reverts with {Blacklisted} if `account` is fail-closed blacklisted. Used both by
    /// {_update} below (mint/burn path) and by {buyMembership} directly, for the renewal branch
    /// that never touches {_update} at all.
    function _assertNotBlacklisted(address account) internal view {
        if (_isBlacklistedFailClosed(account)) revert Blacklisted(account);
    }

    /// @dev Guards every owner-only entry point against being called by a blacklisted owner,
    /// and also covers `setApprovalForAll`, which {_update} cannot see since it only receives
    /// `from`/`to` of an actual transfer, never a third-party operator being approved.
    modifier whenCallerNotBlacklisted() {
        _assertNotBlacklisted(msg.sender);
        _;
    }

    /// @dev Blocks a blacklisted account from granting itself an operator-approval surface it
    /// could otherwise still exercise once un-blacklisted.
    function setApprovalForAll(address operator, bool approved) public virtual override whenCallerNotBlacklisted {
        super.setApprovalForAll(operator, approved);
    }

    /// @notice ERC-1155 transfer hook (mint, burn, and any transfer all route through this one
    /// override). Enforces two independent rules:
    ///  1. Soulbound: blocks any holder-to-holder transfer outright, regardless of blacklist
    ///     status. Mint ({buyMembership}'s `_mint`) and burn ({cancelMembership}'s `_burn`)
    ///     remain the only two permitted state transitions for a membership token.
    ///  2. Blacklist: blocks the call if `from` or `to` is blacklisted (or `BucketInfo` is
    ///     unreachable, fail-closed).
    function _update(address from, address to, uint256[] memory ids, uint256[] memory values)
        internal
        virtual
        override
    {
        if (from != address(0) && to != address(0)) revert MembershipNotTransferable();
        if (from != address(0)) _assertNotBlacklisted(from);
        if (to != address(0)) _assertNotBlacklisted(to);
        super._update(from, to, ids, values);
    }

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @custom:oz-upgrades-unsafe-allow constructor
    /// @param registry_ The platform-owned {ImplementationRegistry} this contract checks upgrade
    /// implementations against. Baked in as an immutable constructor parameter, never threaded
    /// through `initialize`, so the factory needs no access to repoint it.
    constructor(address registry_) {
        if (registry_ == address(0)) revert ZeroAddress();
        REGISTRY = IImplementationRegistry(registry_);
        _disableInitializers();
    }

    /*//////////////////////////////////////////////////////////////
                            INITIALIZER
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initializes the PureMembership contract
     * @param configs Array of membership level configurations
     * @param bucketInfoAddr The BucketInfo contract address
     * @param uri The URI for the ERC-1155 metadata
     */
    function initialize(MembershipConfig[] calldata configs, address bucketInfoAddr, string calldata uri)
        external
        initializer
    {
        // Only a platform-authorized factory may initialize a proxy against this
        // implementation.
        if (!REGISTRY.isAuthorizedFactory(msg.sender)) revert UnauthorizedInitializer();
        if (bucketInfoAddr == address(0)) revert ZeroAddress();

        __ERC1155_init(uri);
        __Pausable_init();
        __Ownable_init(msg.sender);
        // __ReentrancyGuard_init();
        // __UUPSUpgradeable_init();

        bucketInfo = IBucketInfo(bucketInfoAddr);

        for (uint256 i = 0; i < configs.length; i++) {
            membershipConfigs[configs[i].tokenId] = configs[i];
            configuredTokenIds.push(configs[i].tokenId);
        }
    }

    /*//////////////////////////////////////////////////////////////
                        MEMBERSHIP FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Buy or renew one membership duration.
    function buyMembership(uint256 tokenId, address payTokenAddress)
        external
        payable
        nonReentrant
        whenNotPaused
        whenPlatformOperational
    {
        _buyMembership(tokenId, payTokenAddress, 1);
    }

    /// @notice Buy or renew a membership for the specified number of durations.
    /// @param paySection Number of durations to purchase. Zero defaults to one.
    function buyMembership(uint256 tokenId, address payTokenAddress, uint256 paySection)
        external
        payable
        nonReentrant
        whenNotPaused
        whenPlatformOperational
    {
        _buyMembership(tokenId, payTokenAddress, paySection);
    }

    function _buyMembership(uint256 tokenId, address payTokenAddress, uint256 paySection) internal {
        // The renewal branch below (existing holder, expiry extended) never calls _mint/_update,
        // so this contract's _update hook never fires for a renewal — checked explicitly here
        // so a blacklisted holder cannot renew an existing membership indefinitely.
        _assertNotBlacklisted(msg.sender);

        MembershipConfig memory config = membershipConfigs[tokenId];
        if (config.duration == 0) revert InvalidTokenId(tokenId);
        if (!bucketInfo.isTokenValid(payTokenAddress)) {
            revert InvalidToken(payTokenAddress);
        }

        if (paySection == 0) paySection = 1;

        uint256 oraclePrice = bucketInfo.getTokenPrice(payTokenAddress);
        if (oraclePrice == 0) revert InvalidToken(payTokenAddress);
        uint8 decimals = _getTokenDecimals(payTokenAddress);

        uint256 totalPrice = config.price * paySection;
        uint256 paymentAmount = (totalPrice * (10 ** decimals)) / oraclePrice;

        if (maxPaymentAmount != 0 && paymentAmount > maxPaymentAmount) {
            revert PaymentExceedsMaxAmount(paymentAmount, maxPaymentAmount);
        }

        // Handle payment
        if (payTokenAddress == address(0)) {
            if (msg.value < paymentAmount) {
                revert InsufficientPayment(paymentAmount, msg.value);
            }
            // Refund excess ETH
            uint256 excess = msg.value - paymentAmount;
            if (excess > 0) {
                (bool success,) = msg.sender.call{value: excess}("");
                if (!success) revert ETHTransferFailed();
            }
        } else {
            IERC20(payTokenAddress).safeTransferFrom(msg.sender, address(this), paymentAmount);
        }

        // Track revenue
        revenueByToken[payTokenAddress] += paymentAmount;

        // Check if renewal or new purchase
        if (membershipExpiry[msg.sender][tokenId] > block.timestamp) {
            membershipExpiry[msg.sender][tokenId] += config.duration * paySection;

            emit MembershipRenewed(
                msg.sender, tokenId, config.level, payTokenAddress, paymentAmount, membershipExpiry[msg.sender][tokenId]
            );
        } else {
            // New membership
            if (balanceOf(msg.sender, tokenId) == 0) {
                _mint(msg.sender, tokenId, 1, "");
                activeMembershipCount[config.level]++;
            }
            membershipExpiry[msg.sender][tokenId] = block.timestamp + config.duration * paySection;

            emit MembershipPurchased(
                msg.sender, tokenId, config.level, payTokenAddress, paymentAmount, membershipExpiry[msg.sender][tokenId]
            );
        }
    }

    /**
     * @notice Check if a user has an active membership at a given level or above
     * @param user The user address
     * @param level The minimum membership level to check
     * @return True if the user has an active membership at the level or above
     */
    function checkMembershipStatus(address user, uint256 level) external view returns (bool) {
        for (uint256 i = 0; i < configuredTokenIds.length; i++) {
            uint256 tid = configuredTokenIds[i];
            MembershipConfig memory config = membershipConfigs[tid];
            if (config.level >= level && balanceOf(user, tid) > 0 && membershipExpiry[user][tid] > block.timestamp) {
                return true;
            }
        }
        return false;
    }

    /**
     * @notice Cancel a membership by burning the token (no refund)
     * @param tokenId The membership token ID to cancel
     */
    function cancelMembership(uint256 tokenId) external nonReentrant {
        if (balanceOf(msg.sender, tokenId) == 0) revert NoActiveMembership();
        if (membershipExpiry[msg.sender][tokenId] <= block.timestamp) {
            revert MembershipExpired();
        }

        MembershipConfig memory config = membershipConfigs[tokenId];

        _burn(msg.sender, tokenId, 1);
        membershipExpiry[msg.sender][tokenId] = 0;

        if (activeMembershipCount[config.level] > 0) {
            activeMembershipCount[config.level]--;
        }

        emit MembershipCancelled(msg.sender, tokenId, config.level);
    }

    /*//////////////////////////////////////////////////////////////
                          VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Get membership configuration for a token ID
     * @param tokenId The membership token ID
     * @return The MembershipConfig struct
     */
    function getMembershipInfo(uint256 tokenId) external view returns (MembershipConfig memory) {
        return membershipConfigs[tokenId];
    }

    /**
     * @notice Get all active memberships for a user
     * @param user The user address
     * @return Array of UserMembership structs
     */
    function getUserMemberships(address user) external view returns (UserMembership[] memory) {
        uint256 count = 0;
        for (uint256 i = 0; i < configuredTokenIds.length; i++) {
            if (balanceOf(user, configuredTokenIds[i]) > 0) {
                count++;
            }
        }

        UserMembership[] memory memberships = new UserMembership[](count);
        uint256 idx = 0;
        for (uint256 i = 0; i < configuredTokenIds.length; i++) {
            uint256 tid = configuredTokenIds[i];
            if (balanceOf(user, tid) > 0) {
                MembershipConfig memory config = membershipConfigs[tid];
                uint256 expiry = membershipExpiry[user][tid];
                memberships[idx] = UserMembership({
                    tokenId: tid,
                    level: config.level,
                    name: config.name,
                    expiryTime: expiry,
                    isActive: expiry > block.timestamp
                });
                idx++;
            }
        }

        return memberships;
    }

    /**
     * @notice Get total revenue generated from membership sales (all tokens)
     * @return tokens Array of payment token addresses with revenue
     * @return amounts Array of revenue amounts per token
     */
    function getMembershipRevenue() external view returns (address[] memory tokens, uint256[] memory amounts) {
        address[] memory whitelisted = bucketInfo.getWhitelistedTokens();
        uint256 count = 0;

        // Count tokens with revenue
        for (uint256 i = 0; i < whitelisted.length; i++) {
            if (revenueByToken[whitelisted[i]] > 0) {
                count++;
            }
        }

        tokens = new address[](count);
        amounts = new uint256[](count);
        uint256 idx = 0;

        for (uint256 i = 0; i < whitelisted.length; i++) {
            if (revenueByToken[whitelisted[i]] > 0) {
                tokens[idx] = whitelisted[i];
                amounts[idx] = revenueByToken[whitelisted[i]];
                idx++;
            }
        }
    }

    /**
     * @notice Get the number of configured token IDs
     */
    function getConfiguredTokenIdCount() external view returns (uint256) {
        return configuredTokenIds.length;
    }

    /*//////////////////////////////////////////////////////////////
                        REVENUE WITHDRAWAL
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Withdraw accumulated revenue (owner only)
     * @dev Fee is calculated via bucketInfo.calculateFee() and sent to BucketInfo contract.
     *      Only whitelisted tokens can be withdrawn.
     * @param to The recipient address
     * @param tokenAddr The token to withdraw
     * @param amount The amount to withdraw
     */
    function withdrawRevenue(address to, address tokenAddr, uint256 amount)
        external
        onlyOwner
        whenCallerNotBlacklisted
        nonReentrant
        whenPlatformOperational
    {
        // if (to == address(0)) revert ZeroAddress();
        if (!bucketInfo.isTokenValid(tokenAddr)) revert InvalidToken(tokenAddr);
        if (amount == 0) revert ZeroAmount();

        uint256 balance = _getTokenBalance(tokenAddr);
        if (amount > balance) {
            revert InsufficientContractBalance(amount, balance);
        }

        // Ensure the amount is at least 100 USD on first withdrawal to avoid dust withdrawals
        uint256 oraclePrice = bucketInfo.getTokenPrice(tokenAddr);
        if (oraclePrice == 0) revert InvalidToken(tokenAddr);
        uint8 decimals = _getTokenDecimals(tokenAddr);
        uint256 amountInUsd = (amount * oraclePrice) / (10 ** decimals);
        if (totalWithdrawn == 0) {
            if (amountInUsd < 100 * (10 ** 8)) {
                // 100 USD with 8 decimals
                revert InsufficientPayment(100 * (10 ** 8), amountInUsd);
            }
        }
        // Calculate fee, re-checked locally against MAX_LOCAL_PLATFORM_FEE_BPS as a defensive
        // clamp: if calculateFee() ever returned a value above the intended cap, an unclamped
        // fee could exceed amount and panic on the subtraction below.
        uint256 fee = bucketInfo.calculateFee(amount);
        uint256 maxFee = (amount * MAX_LOCAL_PLATFORM_FEE_BPS) / BPS_DENOMINATOR;
        if (fee > maxFee) fee = maxFee;
        uint256 ownerAmount = amount - fee;

        // Transfer to owner's specified address
        _transferToken(tokenAddr, to, ownerAmount);

        // Transfer fee to BucketInfo contract
        if (fee > 0) {
            _transferToken(tokenAddr, address(bucketInfo), fee);
        }

        withdrawnByToken[tokenAddr] += amount;
        totalWithdrawn += amountInUsd;

        emit RevenueWithdrawn(to, tokenAddr, ownerAmount, fee);
    }

    /*//////////////////////////////////////////////////////////////
                        PAUSE MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /// @notice Pause the contract (prevents buyMembership)
    function pause() external onlyOwner whenCallerNotBlacklisted {
        _pause();
    }

    /// @notice Unpause the contract
    function unpause() external onlyOwner whenCallerNotBlacklisted {
        _unpause();
    }

    /*//////////////////////////////////////////////////////////////
                    PAYMENT CAP MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Set the owner-side cap on the payment amount accepted in a single
     *         `buyMembership` call.
     * @dev `newMax == 0` means "no owner-side cap" (unlimited); this is also the
     *      storage default, so newly-deployed proxies are unrestricted until the
     *      owner opts in by calling this function. The value is denominated in the
     *      raw (decimals-adjusted) units of whichever `payTokenAddress` is used for
     *      a given call -- the same units as the `paymentAmount` it is compared
     *      against in `buyMembership`. Because different ERC-20s have different
     *      `decimals()`, a single global cap does not carry equal USD weight across
     *      tokens.
     * @param newMax The new owner-side maximum payment amount (0 = unlimited)
     */
    function setMaxPaymentAmount(uint256 newMax) external onlyOwner whenCallerNotBlacklisted {
        uint256 oldMax = maxPaymentAmount;
        maxPaymentAmount = newMax;
        emit MaxPaymentAmountUpdated(oldMax, newMax);
    }

    /*//////////////////////////////////////////////////////////////
                        ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Recover tokens accidentally sent to the contract (non-whitelisted only)
     * @param token The token address to recover
     * @param amount The amount to recover
     * @param to The recipient address
     */
    function recoverTokens(address token, uint256 amount, address to) external onlyOwner whenCallerNotBlacklisted {
        if (to == address(0)) revert ZeroAddress();
        if (bucketInfo.isTokenWhitelisted(token)) {
            revert CannotRecoverWhitelistedToken(token);
        }

        if (token == address(0)) {
            (bool success,) = to.call{value: amount}("");
            if (!success) revert ETHTransferFailed();
        } else {
            IERC20(token).safeTransfer(to, amount);
        }

        emit TokensRecovered(token, to, amount);
    }

    // ============================================================
    // updateBucketInfo — propose (BucketInfo's owner) + timelock + veto (this contract's own
    // owner) + permissionless execute. This is the only execution path for an emergency
    // BucketInfo migration on membership contracts, so `executeUpdateBucketInfo` below is
    // deliberately permissionless once the delay has elapsed and no veto arrived.
    // ============================================================

    /**
     * @notice Propose updating the BucketInfo contract address.
     * @dev Gated on the CURRENT BucketInfo's owner — NOT this contract's own owner. Overwrites
     * any existing pending proposal.
     * @param newBucketInfo The proposed new BucketInfo contract address.
     */
    function proposeUpdateBucketInfo(address newBucketInfo) external {
        if (newBucketInfo == address(0)) revert ZeroAddress();

        address bucketInfoOwner = IBucketInfo(address(bucketInfo)).owner();
        if (msg.sender != bucketInfoOwner) revert UnauthorizedBucketInfoUpdate();

        _bucketInfoUpdateTimelock.propose(newBucketInfo, BUCKET_INFO_UPDATE_TIMELOCK_DELAY);

        emit BucketInfoUpdateProposed(
            address(bucketInfo), newBucketInfo, msg.sender, block.timestamp + BUCKET_INFO_UPDATE_TIMELOCK_DELAY
        );
    }

    /**
     * @notice Veto (cancel) a pending BucketInfo update before it takes effect.
     * @dev Gated on THIS contract's own owner, giving a veto window before the update takes
     * effect. A no-op (does not revert) if nothing is pending.
     */
    function vetoUpdateBucketInfo() external onlyOwner whenCallerNotBlacklisted {
        address proposed = _bucketInfoUpdateTimelock.pending;
        _bucketInfoUpdateTimelock.cancel();
        emit BucketInfoUpdateVetoed(proposed, msg.sender);
    }

    /**
     * @notice Execute a pending BucketInfo update once the timelock has elapsed and no veto
     * arrived.
     * @dev Deliberately PERMISSIONLESS — see the section doc comment above. Reverts
     * `TimelockedAdmin.NoProposalPending` if nothing is pending (including if it was
     * vetoed), or `TimelockedAdmin.TimelockNotElapsed` if called before the delay has
     * passed.
     */
    function executeUpdateBucketInfo() external {
        address newBucketInfo = _bucketInfoUpdateTimelock.execute();
        address oldBucketInfo = address(bucketInfo);
        bucketInfo = IBucketInfo(newBucketInfo);
        emit BucketInfoUpdated(oldBucketInfo, newBucketInfo, msg.sender);
    }

    /// @notice The currently-pending BucketInfo update, if any.
    function pendingBucketInfoUpdate() external view returns (address pending, uint256 eta) {
        return (_bucketInfoUpdateTimelock.pending, _bucketInfoUpdateTimelock.eta);
    }

    /*//////////////////////////////////////////////////////////////
                    UPGRADE GOVERNANCE
    //////////////////////////////////////////////////////////////*/
    // The platform decides what implementations are approved, this contract's owner decides
    // whether and when to adopt one, and every holder gets a 48-hour exit window before the
    // upgrade can execute.

    /**
     * @notice Queue a UUPS upgrade to `newImplementation`. Starts the 48-hour holder-exit window.
     * @dev Gated on this contract's owner (the customer). Does NOT require registry approval to
     * queue — only to execute (see {_authorizeUpgrade}). Overwrites any existing pending
     * upgrade.
     * @param newImplementation The proposed new implementation contract address.
     */
    function queueUpgrade(address newImplementation) external onlyOwner whenCallerNotBlacklisted {
        if (newImplementation == address(0)) revert ZeroAddress();

        _upgradeTimelock.propose(newImplementation, UPGRADE_TIMELOCK_DELAY);

        emit UpgradeQueued(address(this), newImplementation, block.timestamp + UPGRADE_TIMELOCK_DELAY);
    }

    /**
     * @notice Cancel a pending upgrade before it takes effect.
     * @dev Gated on this contract's owner — the same party who queued it. A no-op (does not
     * revert) if nothing is pending.
     */
    function cancelUpgrade() external onlyOwner whenCallerNotBlacklisted {
        address pending = _upgradeTimelock.pending;
        _upgradeTimelock.cancel();
        emit UpgradeCancelled(address(this), pending);
    }

    /// @notice Always reverts — ownership must always be transferable, never abandoned.
    function renounceOwnership() public override {
        revert RenounceOwnershipDisabled();
    }

    /// @notice The currently-queued implementation address, if any. `address(0)` means nothing is
    /// queued.
    function pendingImplementation() external view returns (address) {
        return _upgradeTimelock.pending;
    }

    /// @notice The timestamp at which the currently-queued upgrade becomes executable, if any.
    /// `0` means nothing is queued.
    function upgradeEta() external view returns (uint256) {
        return _upgradeTimelock.eta;
    }

    /*//////////////////////////////////////////////////////////////
                    COMPLIANCE — SEIZURE (court-order requirement)
    //////////////////////////////////////////////////////////////*/
    // Lets the platform move every membership token a blacklisted account holds to a nominated
    // wallet, on a timelock, for manual processing against a court order or similar document.
    // Propose/cancel are gated on BucketInfo's owner (the platform), not this contract's own
    // owner, so a blacklisted contract owner cannot veto their own seizure. Execution is
    // permissionless once the delay has elapsed, with both sides re-checked against the
    // blacklist at that point.
    //
    // Unlike the ERC-20 vaults, an account here can hold multiple membership tokenIds at once
    // (one per level purchased). There is one seizure proposal per account, not per
    // account-and-tokenId, so {executeSeizure} sweeps every configured tokenId the account holds
    // a nonzero balance of, in one call, to the same nominated wallet.

    /**
     * @notice Propose seizing every membership token `account` currently holds (across all
     * configured token IDs), on a `bytes32` document hash (e.g. a court order) for the record.
     * @dev Gated on BucketInfo's owner (the platform). `account` must be confirmed blacklisted
     * now; execution re-checks this independently. Overwrites any existing pending seizure
     * proposal for this account.
     */
    function proposeSeizure(address account, address to, bytes32 documentHash) external {
        SeizureLib.proposeSeizure(_seizureTimelocks, bucketInfo, account, to, documentHash, SEIZURE_TIMELOCK_DELAY);
    }

    /**
     * @notice Cancel a pending seizure proposal for `account` before it takes effect.
     * @dev Gated on BucketInfo's owner, same as {proposeSeizure} — deliberately no separate
     * veto party. No-op if nothing is pending.
     */
    function cancelSeizure(address account) external {
        SeizureLib.cancelSeizure(_seizureTimelocks, bucketInfo, account);
    }

    /**
     * @notice Execute a pending seizure once the timelock has elapsed, moving EVERY configured
     * membership `tokenId` that `account` currently holds a nonzero balance of to the nominated
     * wallet, in a single ERC-1155 batch transfer.
     * @dev Deliberately permissionless once the delay has elapsed; {SeizureLib.executeSeizure}
     * still gates the outcome, re-checked at execution time on both `account` (confirmed
     * blacklisted) and `to` (fail-closed not blacklisted). Bypasses this contract's own
     * {_update} override via `super._update`, since `account` is blacklisted and the move is a
     * holder-to-holder transfer by shape — the one intentional exception to the soulbound rule.
     */
    function executeSeizure(address account) external {
        uint256 configuredCount = configuredTokenIds.length;

        // First pass: count how many configured tokenIds `account` holds a nonzero balance of,
        // and sum the total across all of them for {SeizureLib.executeSeizure}'s
        // {NothingToSeize} check and event.
        uint256 heldCount = 0;
        uint256 totalBalance = 0;
        for (uint256 i = 0; i < configuredCount; i++) {
            uint256 bal = balanceOf(account, configuredTokenIds[i]);
            if (bal > 0) {
                heldCount++;
                totalBalance += bal;
            }
        }

        address to = SeizureLib.executeSeizure(_seizureTimelocks, bucketInfo, account, totalBalance);

        // totalBalance == 0 reverts with NothingToSeize inside the library call above, so
        // heldCount is provably at least 1 here.
        uint256[] memory ids = new uint256[](heldCount);
        uint256[] memory values = new uint256[](heldCount);
        uint256 idx = 0;
        for (uint256 i = 0; i < configuredCount; i++) {
            uint256 tid = configuredTokenIds[i];
            uint256 bal = balanceOf(account, tid);
            if (bal > 0) {
                ids[idx] = tid;
                values[idx] = bal;
                idx++;
            }
        }

        super._update(account, to, ids, values);
    }

    /// @notice The currently-pending seizure proposal for `account`, if any. `eta == 0` means
    /// nothing is pending.
    function pendingSeizure(address account) external view returns (address to, bytes32 documentHash, uint256 eta) {
        TimelockedAdmin.SeizureTimelock storage t = _seizureTimelocks[account];
        return (t.to, t.documentHash, t.eta);
    }

    /*//////////////////////////////////////////////////////////////
                      INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _getTokenBalance(address token) internal view returns (uint256) {
        if (token == address(0)) return address(this).balance;
        return IERC20(token).balanceOf(address(this));
    }

    function _getTokenDecimals(address token) internal view returns (uint8) {
        if (token == address(0)) return 18;
        return IERC20Metadata(token).decimals();
    }

    function _transferToken(address token, address to, uint256 amount) internal {
        if (token == address(0)) {
            (bool success,) = to.call{value: amount}("");
            if (!success) revert ETHTransferFailed();
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }

    /**
     * @dev `onlyOwner` is one of four conditions enforced here:
     *   1. `msg.sender == owner()` — the `onlyOwner` modifier below.
     *   2. `newImplementation == pendingImplementation()` — byte-identical to the address
     *      announced at queue time.
     *   3. `block.timestamp >= upgradeEta()` — the 48-hour window has elapsed, no bypass.
     *   4. `REGISTRY.isApproved(Kind.PureMembership, newImplementation)` — re-checked HERE, at
     *      execution time, not merely at queue time, so a mid-window platform revocation
     *      actually blocks the upgrade.
     * Conditions 2+3 are enforced together by `TimelockedAdmin.execute`, which reverts
     * `NoProposalPending` or `TimelockNotElapsed` as appropriate. Any revert here reverts the
     * whole transaction, so the pending entry is never actually consumed on a failed attempt.
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner whenCallerNotBlacklisted {
        address queued = _upgradeTimelock.pending;
        if (queued != address(0) && newImplementation != queued) {
            revert UpgradeImplementationMismatch(queued, newImplementation);
        }

        _upgradeTimelock.execute();

        if (!REGISTRY.isApproved(IImplementationRegistry.Kind.PureMembership, newImplementation)) {
            revert UpgradeNotApproved(newImplementation);
        }
    }

    /*//////////////////////////////////////////////////////////////
                          RECEIVE ETH
    //////////////////////////////////////////////////////////////*/

    receive() external payable {}
}
