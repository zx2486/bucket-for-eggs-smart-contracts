// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC1155Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC1155/ERC1155Upgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IBucketInfo} from "./interfaces/IBucketInfo.sol";

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
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

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

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event MembershipPurchased(
        address indexed user, uint256 indexed tokenId, uint256 level,
        address payToken, uint256 payAmount, uint256 expiryTime
    );
    event MembershipRenewed(
        address indexed user, uint256 indexed tokenId, uint256 level,
        address payToken, uint256 payAmount, uint256 newExpiryTime
    );
    event MembershipCancelled(address indexed user, uint256 indexed tokenId, uint256 level);
    event RevenueWithdrawn(address indexed to, address indexed token, uint256 amount, uint256 fee);
    event TokensRecovered(address indexed token, address indexed to, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error PlatformNotOperational();
    error InvalidToken(address token);
    error InvalidTokenId(uint256 tokenId);
    error ZeroAddress();
    error ZeroAmount();
    error InsufficientPayment(uint256 required, uint256 provided);
    error NoActiveMembership();
    error MembershipExpired();
    error InsufficientContractBalance(uint256 requested, uint256 available);
    error ETHTransferFailed();
    error CannotRecoverWhitelistedToken(address token);

    /*//////////////////////////////////////////////////////////////
                              MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier whenPlatformOperational() {
        if (!bucketInfo.isPlatformOperational()) revert PlatformNotOperational();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
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
    function initialize(
        MembershipConfig[] calldata configs,
        address bucketInfoAddr,
        string calldata uri
    ) external initializer {
        if (bucketInfoAddr == address(0)) revert ZeroAddress();

        __ERC1155_init(uri);
        __Pausable_init();
        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

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
     */
    function buyMembership(uint256 tokenId, address payTokenAddress)
        external
        payable
        nonReentrant
        whenNotPaused
        whenPlatformOperational
    {
        MembershipConfig memory config = membershipConfigs[tokenId];
        if (config.duration == 0) revert InvalidTokenId(tokenId);
        if (!bucketInfo.isTokenValid(payTokenAddress)) revert InvalidToken(payTokenAddress);

        // Calculate payment amount based on token price
        uint256 oraclePrice = bucketInfo.getTokenPrice(payTokenAddress);
        uint8 decimals = _getTokenDecimals(payTokenAddress);

        // paymentAmount = membershipPriceUSD / tokenPriceUSD * 10^decimals
        // config.price and oraclePrice both in 8 decimal USD
        uint256 paymentAmount = (config.price * (10 ** decimals)) / oraclePrice;

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
                msg.sender, tokenId, config.level,
                payTokenAddress, paymentAmount,
                membershipExpiry[msg.sender][tokenId]
            );
        } else {
            // New membership
            if (balanceOf(msg.sender, tokenId) == 0) {
                _mint(msg.sender, tokenId, 1, "");
                activeMembershipCount[config.level]++;
            }
            membershipExpiry[msg.sender][tokenId] = block.timestamp + config.duration;

            emit MembershipPurchased(
                msg.sender, tokenId, config.level,
                payTokenAddress, paymentAmount,
                membershipExpiry[msg.sender][tokenId]
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
            if (
                config.level >= level
                && balanceOf(user, tid) > 0
                && membershipExpiry[user][tid] > block.timestamp
            ) {
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
        if (membershipExpiry[msg.sender][tokenId] <= block.timestamp) revert MembershipExpired();

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
    function getMembershipRevenue()
        external
        view
        returns (address[] memory tokens, uint256[] memory amounts)
    {
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
        nonReentrant
        whenPlatformOperational
    {
        // if (to == address(0)) revert ZeroAddress();
        if (!bucketInfo.isTokenValid(tokenAddr)) revert InvalidToken(tokenAddr);
        if (amount == 0) revert ZeroAmount();

        uint256 balance = _getTokenBalance(tokenAddr);
        if (amount > balance) revert InsufficientContractBalance(amount, balance);

        // Ensure the amount is at least 100 USD on first withdrawal to avoid dust withdrawals
        uint256 oraclePrice = bucketInfo.getTokenPrice(tokenAddr);
        uint8 decimals = _getTokenDecimals(tokenAddr);
        uint256 amountInUSD = (amount * oraclePrice) / (10 ** decimals);
        if (totalWithdrawn == 0) {
            if (amountInUSD < 100 * (10 ** 8)) { // 100 USD with 8 decimals
                revert InsufficientPayment(100 * (10 ** 8), amountInUSD);
            }
        }
        // Calculate fee
        uint256 fee = bucketInfo.calculateFee(amount);
        uint256 ownerAmount = amount - fee;

        // Transfer to owner's specified address
        _transferToken(tokenAddr, to, ownerAmount);

        // Transfer fee to BucketInfo contract
        if (fee > 0) {
            _transferToken(tokenAddr, address(bucketInfo), fee);
        }

        withdrawnByToken[tokenAddr] += amount;
        totalWithdrawn += amountInUSD;

        emit RevenueWithdrawn(to, tokenAddr, ownerAmount, fee);
    }

    /*//////////////////////////////////////////////////////////////
                        PAUSE MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /// @notice Pause the contract (prevents buyMembership)
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpause the contract
    function unpause() external onlyOwner {
        _unpause();
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
    function recoverTokens(address token, uint256 amount, address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (bucketInfo.isTokenWhitelisted(token)) revert CannotRecoverWhitelistedToken(token);

        if (token == address(0)) {
            (bool success,) = to.call{value: amount}("");
            if (!success) revert ETHTransferFailed();
        } else {
            IERC20(token).safeTransfer(to, amount);
        }

        emit TokensRecovered(token, to, amount);
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

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /*//////////////////////////////////////////////////////////////
                          RECEIVE ETH
    //////////////////////////////////////////////////////////////*/

    receive() external payable {}
}
