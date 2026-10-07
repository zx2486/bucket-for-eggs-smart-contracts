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

    /// @notice W3.2 (D3): pending propose+timelock+veto state for
    /// {proposeUpdateBucketInfo} / {vetoUpdateBucketInfo} / {executeUpdateBucketInfo}.
    /// Plain linear storage (this contract has no ERC-7201 namespace) — appended after
    /// `maxPaymentAmount`, the last pre-existing state variable, so it cannot shift any
    /// existing slot.
    TimelockedAdmin.AddressTimelock private _bucketInfoUpdateTimelock;

    /// @dev Propose→execute delay for `updateBucketInfo`. NO EXACT NUMBER WAS
    /// CLIENT-SPECIFIED for this veto window; mirrors the Inferred default used at
    /// `BucketVaultBase.BUCKET_INFO_UPDATE_TIMELOCK_DELAY` (48 hours, reusing the client's
    /// vault-upgrade-timelock figure from `09-DECISION-LOG.md` §10.1) for the same reason:
    /// identical rug-pull shape, one platform-wide delay rather than two unexplained
    /// numbers. Flagged for the client to confirm or override — see
    /// W3-SC-GOVERNANCE-REPORT.md `## Corrections to my briefing`.
    uint256 public constant BUCKET_INFO_UPDATE_TIMELOCK_DELAY = 48 hours;

    /// @notice The platform-owned {ImplementationRegistry} this contract's upgrades are checked
    /// against. W3.3 (`09-DECISION-LOG.md` §10.1): `immutable`, constructor-set, never
    /// repointable — the whitelist authority itself must not be swappable by this contract's
    /// (customer) owner. This contract has no shared base to inherit the vaults'
    /// `_registry()`/`_registryKind()` hooks from, so it carries its own duplicate copy of the
    /// whole upgrade-governance section below — see BucketVaultBase.sol's section doc comment.
    IImplementationRegistry public immutable REGISTRY;

    /// @notice W3.3: pending queue+timelock state for {queueUpgrade} / {cancelUpgrade} /
    /// {_authorizeUpgrade}. Plain linear storage, appended after `_bucketInfoUpdateTimelock`
    /// above, so it cannot shift any existing slot.
    TimelockedAdmin.AddressTimelock private _upgradeTimelock;

    /// @dev Vault-level queue(propose)→execute delay for the UUPS upgrade path.
    /// CLIENT-CONFIRMED at exactly 48 hours, no bypass (`09-DECISION-LOG.md` §10.1 /
    /// `10-ANSWER:2`) — unlike {BUCKET_INFO_UPDATE_TIMELOCK_DELAY} above, this figure is NOT
    /// Inferred.
    uint256 public constant UPGRADE_TIMELOCK_DELAY = 48 hours;

    /// @notice W4.3 (D2, court-order requirement): pending seizure state for {proposeSeizure} /
    /// {cancelSeizure} / {executeSeizure}, keyed by the account being seized from -- same
    /// mapping shape as {BucketVaultBase}'s own copy (`TimelockedAdmin.sol`'s
    /// `SeizureTimelock` doc comment names this contract explicitly as sharing the pattern).
    /// Plain linear storage, appended after `_upgradeTimelock`, the last pre-existing state
    /// variable, so it cannot shift any existing slot.
    mapping(address => TimelockedAdmin.SeizureTimelock) private _seizureTimelocks;

    /// @dev Same 48-hour figure as {BUCKET_INFO_UPDATE_TIMELOCK_DELAY} / {UPGRADE_TIMELOCK_DELAY}
    /// -- one platform-wide delay, not a third unexplained number. `internal`, not `public`,
    /// mirroring {BucketVaultBase.SEIZURE_TIMELOCK_DELAY}'s own visibility choice: no test or
    /// integration yet depends on an external getter, and the value is already public knowledge
    /// via {SeizureLib.SeizureProposed}'s emitted `eta`.
    uint256 internal constant SEIZURE_TIMELOCK_DELAY = 48 hours;

    /// @dev BPS scale used by {calculateFee}'s local defensive clamp (W3.6) — matches
    /// `BucketInfo.calculateFee`'s own `/10000` (`BucketInfo.sol:657`).
    uint256 public constant BPS_DENOMINATOR = 10_000;

    /// @dev W3.6 defensive ceiling on the fee taken from a {withdrawRevenue} amount, mirrored
    /// against BucketInfo's own `MAX_PLATFORM_FEE = 1000` (`BucketInfo.sol:89`). Re-checked here
    /// even though BucketInfo already enforces it — see the clamp's usage site for why.
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
    /// W3.2 (D3): emitted by {proposeUpdateBucketInfo}. `eta` is when
    /// {executeUpdateBucketInfo} becomes callable absent a veto.
    event BucketInfoUpdateProposed(
        address indexed oldBucketInfo, address indexed proposedBucketInfo, address indexed proposedBy, uint256 eta
    );
    /// W3.2 (D3): emitted by {vetoUpdateBucketInfo}.
    event BucketInfoUpdateVetoed(address indexed vetoedBucketInfo, address indexed vetoedBy);
    event MaxPaymentAmountUpdated(uint256 oldMax, uint256 newMax);
    /// W3.3 (`09-DECISION-LOG.md` §10.1c): emitted by {queueUpgrade}. `vault` is redundant on a
    /// per-vault contract but lets a multi-vault indexer / `eth_getLogs` sweep watch every
    /// vault's pending upgrades without an archive node.
    event UpgradeQueued(address indexed vault, address indexed newImplementation, uint256 eta);
    /// W3.3: emitted by {cancelUpgrade}. `implementation` is the address that was pending and
    /// will now never execute.
    event UpgradeCancelled(address indexed vault, address indexed implementation);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error PlatformNotOperational();
    error InvalidToken(address token);
    error InvalidTokenId(uint256 tokenId);
    error ZeroAddress();
    /// @dev Task #33 (W1.7 direct-proxy-bypass fix): thrown by `initialize()` when `msg.sender`
    /// is not a factory the platform has authorized via
    /// `IImplementationRegistry.setAuthorizedFactory`. See the identical check and full
    /// rationale in ActiveBucket.sol's `initialize()`.
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
    /// @dev W4.2b: thrown by {_update} when either side of a mint/burn/transfer is
    /// blacklisted, or when `BucketInfo` cannot be reached to answer that question (D2,
    /// fail-closed). See this contract's own COMPLIANCE section.
    error Blacklisted(address account);
    /// @dev W4.2b (root CLAUDE.md §8's "soulbound is a REQUIREMENT, not a shipped property" /
    /// client 01:33, 01:54): thrown by {_update} for any transfer that is neither a mint
    /// (`from == address(0)`) nor a burn (`to == address(0)`) -- i.e. any holder-to-holder
    /// transfer of a membership token, which must never be allowed regardless of blacklist
    /// status.
    error MembershipNotTransferable();
    /// @dev W3.3: {queueUpgrade}/{_authorizeUpgrade}. The implementation actually installed via
    /// UUPS's `upgradeToAndCall` at execution time must be byte-identical to the one announced
    /// at queue time — queuing the ADDRESS (never a boolean) is the whole point: a boolean flag
    /// would let the queuer announce implementation A and execute implementation B, "worse than
    /// no window, because it manufactures assurance"
    /// (`04-CONTRACTS-IMPLEMENTATION-PLAN.md` §5.6.1/§10.1c).
    error UpgradeImplementationMismatch(address expected, address provided);
    /// @dev W3.3: the platform ({ImplementationRegistry}) has not (or no longer) approved this
    /// implementation for this contract's `Kind`. Re-checked at EXECUTION time (inside
    /// {_authorizeUpgrade}), not just at queue time, so a mid-window revocation actually blocks
    /// the upgrade (`09-DECISION-LOG.md` §10.1).
    error UpgradeNotApproved(address implementation);
    /// @dev Thrown by {renounceOwnership}, which is always disabled -- task #45 (W3 gate)
    /// discovered this override was MISSING here, so `OwnableUpgradeable.renounceOwnership()`
    /// currently SUCCEEDS and would permanently brick every `onlyOwner` path (pause,
    /// queueUpgrade, updateBucketInfo, ...) with no remedy. Q14.2
    /// (`10-BLOCKER-14-DECOMPOSITION-ANSWER.md:6-7`): "If we want to make the contract ownerless,
    /// we will change the owner into a DAO contract (not in scope yet)" -- same rule, same
    /// wording, as `BucketInfo.sol:711`/`ImplementationRegistry.sol:39`/
    /// `BucketVaultBase.sol`'s own copy of this fix. Stays single-step `Ownable` (D-3) -- this
    /// fixes ONLY the renounce path, and does not add `Ownable2Step`.
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
            COMPLIANCE — BLACKLIST + SOULBOUND (W4.2b, D2, N4)
    //////////////////////////////////////////////////////////////*/

    /// @dev Fail-closed read of `bucketInfo.isBlacklisted(account)` -- duplicate of
    /// {BucketVaultBase._isBlacklistedFailClosed} (this contract has no shared base to inherit
    /// it from; INV-9's "written once" applies to the CHECK LOGIC being identical across both
    /// copies, not to there being a single physical copy -- see BucketVaultBase.sol's own
    /// COMPLIANCE section for the full rationale, reproduced here verbatim). Never reverts
    /// itself: "true" stands in for both "actually blacklisted" and "BucketInfo unreachable".
    function _isBlacklistedFailClosed(address account) internal view returns (bool) {
        try bucketInfo.isBlacklisted(account) returns (bool blacklisted) {
            return blacklisted;
        } catch {
            return true;
        }
    }

    /// @dev Reverts with {Blacklisted} if `account` is fail-closed blacklisted. Duplicate of
    /// {BucketVaultBase._assertNotBlacklisted} for the same reason {_isBlacklistedFailClosed} is
    /// duplicated above. Used both by {_update} below (mint/burn path) and by {buyMembership}
    /// (W4.2c) directly, for the renewal branch that never touches {_update} at all.
    function _assertNotBlacklisted(address account) internal view {
        if (_isBlacklistedFailClosed(account)) revert Blacklisted(account);
    }

    /// @dev Verifier fix (2026-10-04): mirrors {BucketVaultBase.whenCallerNotBlacklisted} --
    /// this contract has no shared base to inherit it from (same reason the two helpers above
    /// are duplicated). Closes the "admin calls by a blacklisted owner" gap on every
    /// `onlyOwner` function below, plus the ERC-1155 `setApprovalForAll` spender-side gap that
    /// {_update} structurally cannot see (it only ever receives `from`/`to` of an actual
    /// transfer, never a third-party operator being approved).
    modifier whenCallerNotBlacklisted() {
        _assertNotBlacklisted(msg.sender);
        _;
    }

    /// @dev Verifier fix (2026-10-04): blocks a blacklisted account from granting itself an
    /// operator-approval surface it could otherwise still exercise once un-blacklisted, and
    /// closes the literal "setApprovalForAll by a blacklisted address" gap the audit found --
    /// the soulbound guard in {_update} stops the resulting transfer, but never stopped the
    /// approval call itself from succeeding.
    function setApprovalForAll(address operator, bool approved) public virtual override whenCallerNotBlacklisted {
        super.setApprovalForAll(operator, approved);
    }

    /// @notice ERC-1155 transfer hook (mint, burn, and any transfer all route through this one
    /// override -- unlike ERC20Upgradeable's per-unit `_update`, ERC1155Upgradeable has exactly
    /// one `_update(from, to, ids, values)` regardless of batch size). Bundles TWO checks
    /// deliberately in the SAME edit, per root CLAUDE.md §8's explicit instruction ("build them
    /// together or the second one rewrites the first"):
    ///  1. Soulbound (N4, client 01:33/01:54): blocks ANY holder-to-holder transfer outright --
    ///     `from != address(0) && to != address(0)` -- regardless of blacklist status. Mint
    ///     ({buyMembership}'s `_mint`) and burn ({cancelMembership}'s `_burn`) remain the only
    ///     two permitted state transitions for a membership token. ⚠ This closes an open defect:
    ///     before this override, `safeTransferFrom` worked (root CLAUDE.md §8 verified 2026-09-13
    ///     there was no transfer restriction anywhere in `src/`), despite membership being a
    ///     client requirement to be non-transferable.
    ///  2. Blacklist (W4.2, D2): blocks the call if `from` or `to` is blacklisted (or
    ///     `BucketInfo` is unreachable, fail-closed). Checked AFTER the soulbound gate above, so
    ///     a holder-to-holder attempt reverts with {MembershipNotTransferable} regardless of
    ///     either party's blacklist status -- the two checks are independent, not layered.
    /// @dev No transfer hook existed anywhere in this codebase before W4 (plan §7.2a); this is
    /// hook CREATION, not modification of pre-existing logic.
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
    /// implementations against. W3.3: baked in as an immutable constructor parameter, never
    /// threaded through `initialize`, following the same "factory-immutable" precedent used for
    /// the vaults (root CLAUDE.md §1.1, W1.7) — so `PureMembershipFactory` needs zero changes to
    /// supply it (`09-DECISION-LOG.md` §11.2 / D-3).
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
        // Task #33 (W1.7 direct-proxy-bypass fix): only a platform-authorized factory may
        // initialize a proxy against this implementation. See the identical check and full
        // rationale in ActiveBucket.sol's `initialize()`.
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

    /**
     * @notice Buy or renew a membership by paying with a whitelisted token
     * @dev If the user already has an active membership of this type, it extends the expiry.
     *      Otherwise, mints a new ERC-1155 token and sets the initial expiry.
     * @param tokenId The membership token ID to purchase
     * @param payTokenAddress The payment token (address(0) for ETH)
     * @param maxPay Optional caller-supplied ceiling on `paymentAmount`, in the same
     *   decimals-adjusted units as `payTokenAddress`. Pass 0 for "no user-side cap".
     *   Composed with the owner-set `maxPaymentAmount` as `min(ownerCap, userCap)`,
     *   where a 0 on either side means that side imposes no restriction. This lets a
     *   caller bound what they are willing to pay if the oracle price moves against
     *   them between quoting and mining, independent of whatever the owner has set.
     */
    function buyMembership(uint256 tokenId, address payTokenAddress, uint256 maxPay)
        external
        payable
        nonReentrant
        whenNotPaused
        whenPlatformOperational
    {
        // W4.2c: the RENEWAL branch below (existing holder, expiry extended) never calls
        // `_mint`/`_update` -- only the NEW-PURCHASE branch does -- so this contract's own
        // `_update` hook (see COMPLIANCE section above) never fires for a renewal. Without this
        // explicit check, a blacklisted holder could renew an existing membership indefinitely
        // with zero enforcement. This is a genuine coverage gap, not a gas/UX nicety: unlike
        // ActiveBucket/PassiveBucket's `deposit`/`redeem` (which unconditionally `_mint`/`_burn`
        // every call and are therefore fully covered by the hook alone), this entry point is not.
        _assertNotBlacklisted(msg.sender);

        MembershipConfig memory config = membershipConfigs[tokenId];
        if (config.duration == 0) revert InvalidTokenId(tokenId);
        if (!bucketInfo.isTokenValid(payTokenAddress)) {
            revert InvalidToken(payTokenAddress);
        }

        // Calculate payment amount based on token price
        uint256 oraclePrice = bucketInfo.getTokenPrice(payTokenAddress);
        if (oraclePrice == 0) revert InvalidToken(payTokenAddress);
        uint8 decimals = _getTokenDecimals(payTokenAddress);

        // paymentAmount = membershipPriceUSD / tokenPriceUSD * 10^decimals
        // config.price and oraclePrice both in 8 decimal USD
        uint256 paymentAmount = (config.price * (10 ** decimals)) / oraclePrice;

        // Enforce owner cap (maxPaymentAmount) and optional per-call user cap (maxPay),
        // composed as min(ownerCap, userCap). 0 on either side means "no restriction
        // from that side". This must run before any funds move.
        uint256 effectiveCap = maxPaymentAmount;
        if (maxPay != 0 && (effectiveCap == 0 || maxPay < effectiveCap)) {
            effectiveCap = maxPay;
        }
        if (effectiveCap != 0 && paymentAmount > effectiveCap) {
            revert PaymentExceedsMaxAmount(paymentAmount, effectiveCap);
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
            // Renew: extend from current expiry
            membershipExpiry[msg.sender][tokenId] += config.duration;

            emit MembershipRenewed(
                msg.sender, tokenId, config.level, payTokenAddress, paymentAmount, membershipExpiry[msg.sender][tokenId]
            );
        } else {
            // New membership
            if (balanceOf(msg.sender, tokenId) == 0) {
                _mint(msg.sender, tokenId, 1, "");
                activeMembershipCount[config.level]++;
            }
            membershipExpiry[msg.sender][tokenId] = block.timestamp + config.duration;

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
        // Calculate fee
        // W3.6: defensive clamp on the fee returned by BucketInfo. `MAX_PLATFORM_FEE = 1000` bps
        // (10%) is enforced on BucketInfo (`BucketInfo.sol:89`) but not re-checked here — this is
        // the belt to the timelock's braces (`04-CONTRACTS-IMPLEMENTATION-PLAN.md` W3.6): if
        // `calculateFee()` ever returned a value above the intended cap (corrupted state, future
        // bug), an unclamped `fee` could exceed `amount` and panic on the subtraction below,
        // reverting every withdrawal. Clamping locally keeps this function safe even if
        // BucketInfo's own guarantee is ever violated. PureMembership has no shared base to
        // inherit a helper from (see its own local W3.3 errors/constants above), so the clamp is
        // local too.
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
     *      tokens; this mirrors the shape the plan and review asked for
     *      (`_deliverables/04-CONTRACTS-IMPLEMENTATION-PLAN.md` conflict (h),
     *      `_review/03b-membership.md` H-02) and the cross-token caveat is flagged
     *      in full in the accompanying report, not silently assumed away.
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
    // updateBucketInfo — W3.2 REWRITE: propose (BucketInfo owner) + timelock + veto
    // (this contract's own owner) + permissionless execute.
    //
    // Mirrors BucketVaultBase.sol's identical W3.2 rewrite exactly (D3,
    // `04-CONTRACTS-IMPLEMENTATION-PLAN.md` W3.2). PureMembership does NOT inherit
    // BucketVaultBase (it is ERC-1155, not a share-vault) and so needs its own copy of this
    // logic rather than reuse; its `bucketInfo` field is plain linear storage, not an
    // ERC-7201 namespace, so the new pending-timelock state is simply a new state variable
    // appended after the existing ones (see STATE VARIABLES section) rather than a new
    // namespaced struct field.
    //
    // ⚠ Load-bearing coupling (04 §5.6): same as the vault version — this is the ONLY
    // execution path for an emergency BucketInfo migration on membership contracts, so
    // `executeUpdateBucketInfo` below is deliberately PERMISSIONLESS once the delay has
    // elapsed and no veto arrived.
    // ============================================================

    /**
     * @notice Propose updating the BucketInfo contract address.
     * @dev Gated on the CURRENT BucketInfo's owner — NOT this contract's own owner. See
     * workspace CLAUDE.md §1.1. Overwrites any existing pending proposal.
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
     * @dev Gated on THIS contract's own owner — the D3 veto window. A no-op (does not
     * revert) if nothing is pending.
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
                    UPGRADE GOVERNANCE — W3.3
    //////////////////////////////////////////////////////////////*/
    // Standalone duplicate of BucketVaultBase.sol's "Upgrade governance" section — this contract
    // has no shared base to call into. See that file's section doc comment for the full
    // three-party rationale (platform decides WHAT, this contract's owner decides
    // WHETHER/WHEN, every other holder gets the 48-hour exit window) and the revocation-
    // visibility caveat (nothing on this contract changes when the platform revokes registry
    // approval mid-window; {pendingImplementation}/{upgradeEta} alone cannot tell a holder
    // whether a pending upgrade can still execute).

    /**
     * @notice Queue a UUPS upgrade to `newImplementation`. Starts the 48-hour holder-exit window.
     * @dev Gated on this contract's owner (the customer). Does NOT require registry approval to
     * queue — only to EXECUTE (see {_authorizeUpgrade}) — the re-check at execution is what
     * actually gates it. Overwrites any existing pending upgrade.
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

    /// @notice Always reverts. Task #45 fix -- see {RenounceOwnershipDisabled}'s doc comment for
    /// why this override was missing and what it would otherwise have permanently bricked.
    /// Single-step `Ownable` stays the only ownership base here (D-3) -- this does not
    /// introduce `Ownable2Step`.
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
                    COMPLIANCE — SEIZURE (W4.3, D2 / court-order requirement)
    //////////////////////////////////////////////////////////////*/
    // Standalone duplicate of BucketVaultBase.sol's "COMPLIANCE -- SEIZURE" section -- this
    // contract has no shared base to call into (same reason its own COMPLIANCE -- BLACKLIST +
    // SOULBOUND section above is a duplicate, not a reuse). See that file's section header
    // comment for the full rationale this copies verbatim: the client requirement
    // (`00-EXECUTIVE-SUMMARY-USER-REPLY.md:18-21`, "a function to move the tokens holded by a
    // blacklisted address to another wallet for further manual process", taking a `bytes32`
    // document hash "of a document / court order"), the ⚠ SOURCE DISAGREES resolution (the
    // client says BucketInfo would carry this function; root CLAUDE.md §8 fixes BucketInfo's
    // mutable surface and BucketInfo holds no membership tokens to move anyway, so the
    // mechanism lives HERE, on the contract that actually holds the balance), the
    // platform-owner gate on propose/cancel (mirrors {proposeUpdateBucketInfo}, NOT this
    // contract's own `onlyOwner` -- a blacklisted contract owner must not be able to veto their
    // own seizure), the deliberate absence of a separate veto party, and the reversed
    // fail-closed direction at execution ({SeizureLib.requireConfirmedBlacklisted} for
    // `account` vs. {SeizureLib.requireNotBlacklistedFailClosed} for `to` -- an unreachable
    // BucketInfo must ABORT a platform seizure rather than wave it through, the mirror image of
    // D2's usual "block the user's own action when in doubt" direction).
    //
    // ⚠ ONE GENUINE DIFFERENCE FROM THE VAULTS, called out explicitly per hard rule 5/10: this
    // contract is ERC-1155, not ERC-20, so "whatever `account` currently holds" is not a single
    // scalar balance -- an account can hold a nonzero balance of MULTIPLE membership `tokenId`s
    // simultaneously (one per membership level purchased). `TimelockedAdmin.SeizureTimelock`
    // carries no `tokenId` field, and its own doc comment (`libs/TimelockedAdmin.sol`) names
    // this contract as sharing the exact same `mapping(address => SeizureTimelock)` shape used
    // by the two ERC-20 vaults -- i.e. ONE seizure proposal per account, not one per
    // account-and-tokenId. Reading "seizing whatever account currently holds" literally, this
    // contract's {executeSeizure} therefore sweeps EVERY configured `tokenId` the account holds
    // a nonzero balance of, in one call, to the same nominated wallet. This is an Inferred
    // design choice (no `file:line` client text spells out the multi-tokenId case) and is
    // flagged for human confirmation in this wave's compliance report -- the alternative
    // (seize one named tokenId at a time) was rejected because it would require changing the
    // shared `SeizureTimelock` struct/propose signature, which the vaults do not need and which
    // `libs/TimelockedAdmin.sol`'s own doc comment already commits to a single shared shape
    // across all three token contracts.
    //
    // `SeizureLib` itself is fully generic (it never touches the actual token balance -- see its
    // own doc comment) and is reused HERE UNCHANGED, not re-copied: propose/cancel/the
    // blacklist-confirmation and fail-closed checks inside execute are byte-identical calls into
    // the same deployed library BucketVaultBase already uses. Only the actual balance-move
    // (the ERC-1155-specific multi-`tokenId` loop below) is written locally, for the same reason
    // BucketVaultBase's own `super._update` call could not move into the library: the token
    // movement primitive is `internal` to each contract's own OpenZeppelin inheritance chain.

    /**
     * @notice Propose seizing every membership token `account` currently holds (across all
     * configured token IDs), on a `bytes32` document hash (e.g. a court order) for the record.
     * @dev Gated on BucketInfo's owner (the platform) -- see this section's header comment.
     * `account` must be confirmed blacklisted now; execution re-checks this independently.
     * Overwrites any existing pending seizure proposal for this account.
     */
    function proposeSeizure(address account, address to, bytes32 documentHash) external {
        SeizureLib.proposeSeizure(_seizureTimelocks, bucketInfo, account, to, documentHash, SEIZURE_TIMELOCK_DELAY);
    }

    /**
     * @notice Cancel a pending seizure proposal for `account` before it takes effect.
     * @dev Gated on BucketInfo's owner, same as {proposeSeizure} -- deliberately no separate
     * veto party. No-op if nothing is pending, matching `TimelockedAdmin.cancel`'s semantics.
     */
    function cancelSeizure(address account) external {
        SeizureLib.cancelSeizure(_seizureTimelocks, bucketInfo, account);
    }

    /**
     * @notice Execute a pending seizure once the timelock has elapsed, moving EVERY configured
     * membership `tokenId` that `account` currently holds a nonzero balance of to the nominated
     * wallet, in a single ERC-1155 batch transfer.
     * @dev Deliberately PERMISSIONLESS once the delay has elapsed, mirroring
     * {executeUpdateBucketInfo}/{BucketVaultBase.executeSeizure} -- but {SeizureLib.executeSeizure}
     * still gates the outcome, re-checked at execution time on BOTH `account` (confirmed
     * blacklisted) and `to` (fail-closed not blacklisted), so anyone may trigger it but nobody
     * can make it succeed against an account no longer confirmed blacklisted or into a
     * destination that is itself blacklisted.
     * Bypasses this contract's own {_update} override deliberately, via `super._update` --
     * `account` IS blacklisted (this contract's soulbound half of {_update} would ALSO revert
     * any nonzero-to-nonzero transfer regardless of blacklist status), so routing through the
     * override would revert on either of its two checks. This is the one place in this
     * contract where a holder-to-holder-shaped balance move is intentional, not a bug.
     * `totalBalance` (the sum across every held tokenId) is passed to {SeizureLib.executeSeizure}
     * purely for its {NothingToSeize} guard and the {SeizureLib.SeizureExecuted} event's
     * `beforeBalance` field -- it is a count, not itself moved; the actual per-`tokenId` amounts
     * are moved by the batch `super._update` call below, using OpenZeppelin's plain `_update`
     * (not `_updateWithAcceptanceCheck`), which deliberately SKIPS the ERC-1155 receiver
     * acceptance check -- the same trade-off {BucketVaultBase.executeSeizure} makes implicitly
     * (ERC-20 has no receiver hook to skip): a compliance seizure into a custody wallet must not
     * be blockable by that wallet failing to implement `onERC1155Received`.
     */
    function executeSeizure(address account) external {
        uint256 configuredCount = configuredTokenIds.length;

        // First pass: count how many configured tokenIds `account` holds a nonzero balance of,
        // and sum the total across all of them -- this sum is `beforeBalance` for
        // {SeizureLib.executeSeizure}'s {NothingToSeize} check and event, not itself moved.
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

        // `totalBalance == 0` reverts with `NothingToSeize` inside the library call above, so by
        // this point `heldCount` is provably at least 1 -- the second pass below always builds a
        // non-empty batch.
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
    /// @dev Reads storage DIRECTLY rather than through {SeizureLib} -- same trivial-read
    /// reasoning as {BucketVaultBase.pendingSeizure}: a 3-field struct read with no check,
    /// gating, or event does not justify a library call.
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
     * @dev W3.3 (`09-DECISION-LOG.md` §10.1): `onlyOwner` alone is condition 1 of 4. Full
     * standalone duplicate of {BucketVaultBase._authorizeUpgradeCommon} (no shared base to call
     * into here) — enforces:
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
