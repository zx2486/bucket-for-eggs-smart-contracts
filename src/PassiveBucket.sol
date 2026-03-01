// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {
    ERC20BurnableUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IBucketInfo} from "./interfaces/IBucketInfo.sol";

/**
 * @title ISwapRouter
 * @dev Interface for Uniswap V3 SwapRouter02
 */
interface ISwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

/**
 * @title IQuoter
 * @dev Interface for Uniswap V3 QuoterV2
 */
interface IQuoter {
    struct QuoteExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint24 fee;
        uint160 sqrtPriceLimitX96;
    }

    function quoteExactInputSingle(QuoteExactInputSingleParams memory params)
        external
        returns (uint256 amountOut, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed, uint256 gasEstimate);
}

/**
 * @title IWETH
 * @dev Interface for Wrapped Ether
 */
interface IWETH {
    function withdraw(uint256) external;

    function deposit() external payable;

    function balanceOf(address) external view returns (uint256);

    function approve(address, uint256) external returns (bool);
}

/**
 * @title PassiveBucket
 * @author Bucket-for-Eggs Team
 * @notice Upgradeable ERC-20 vault that manages a basket of tokens according to predefined
 * weight distributions. Users deposit tokens to receive shares and redeem shares to receive
 * proportional underlying tokens. Rebalancing aligns actual holdings with target distribution.
 * @dev Uses UUPS proxy pattern. Integrates with BucketInfo for token validation and pricing,
 * and with DEX routers (Uniswap V3 style + 1inch) for rebalancing.
 */
contract PassiveBucket is
    Initializable,
    ERC20Upgradeable,
    ERC20BurnableUpgradeable,
    PausableUpgradeable,
    OwnableUpgradeable,
    ReentrancyGuardTransient,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                STRUCTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Token and its target weight in the bucket distribution
    /// @param token The token address (address(0) for native ETH)
    /// @param weight The weight percentage (all weights must sum to 100)
    struct BucketDistribution {
        address token;
        uint256 weight;
    }

    /// @notice DEX router configuration for rebalancing
    struct DexConfig {
        address router;
        address quoter;
        uint24 fee;
        bool enabled;
    }

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice BucketInfo contract for token validation and pricing
    IBucketInfo public bucketInfo;

    /// @notice 1inch aggregation router address
    address public oneInchRouter;

    /// @notice WETH address for DEX swaps involving native ETH
    address public weth;

    /// @notice Current bucket distributions
    BucketDistribution[] private _bucketDistributions;

    /// @notice Share price in USD with 8 decimals (matching BucketInfo)
    uint256 public tokenPrice;

    /// @notice Whether swap/rebalance functions are paused
    bool public swapPaused;

    /// @notice Total deposited value in USD (8 decimals)
    uint256 public totalDepositValue;

    /// @notice Total withdrawn value in USD (8 decimals)
    uint256 public totalWithdrawValue;

    /// @notice DEX configurations indexed by ID
    mapping(uint8 => DexConfig) public dexConfigs;

    /// @notice Number of configured DEXs
    uint8 public dexCount;

    /// @notice Owner fee in basis points for rebalanceByDefi (e.g., 300 = 3%)
    uint256 public rebalanceOwnerFeeBps;

    /// @notice Caller fee in basis points for rebalanceByDefi (e.g., 100 = 1%)
    uint256 public rebalanceCallerFeeBps;

    /// @notice Precision constant for share calculations
    uint256 public constant PRECISION = 1e18;

    /// @notice Initial share price ($1 in 8-decimal USD)
    uint256 public constant INITIAL_TOKEN_PRICE = 1e8;

    /// @notice Weight denominator (weights must sum to this value)
    uint256 public constant WEIGHT_SUM = 100;

    /// @notice Minimum owner holding (5% in basis points)
    uint256 public constant MIN_OWNER_BPS = 500;

    /// @notice Basis points denominator
    uint256 public constant BPS_DENOMINATOR = 10000;

    /// @notice Distribution tolerance for rebalance verification (2%)
    uint256 public constant DISTRIBUTION_TOLERANCE = 2;

    /// @notice Maximum value loss for 1inch rebalance (0.5% = 50 bps)
    uint256 public constant MAX_VALUE_LOSS_BPS = 50;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event Deposited(
        address indexed user, address indexed token, uint256 amount, uint256 sharesMinted, uint256 depositValueUsd
    );
    event Redeemed(address indexed user, uint256 sharesRedeemed);
    event TokenReturned(address indexed user, address indexed token, uint256 amount);
    event BucketDistributionsUpdated(BucketDistribution[] distributions);
    event SwapPauseChanged(bool paused);
    event Rebalanced(
        address indexed caller,
        uint256 totalValueBeforeSwap,
        uint256 totalValueBasedOnLastTokenPrice,
        uint256 totalValueAfter,
        uint256 newTokenPrice
    );
    event RebalanceFeeDistributed(address indexed recipient, uint256 sharesMinted, uint256 feeValueUsd);
    event OwnerPenaltyBurned(address indexed owner, uint256 sharesBurned, uint256 penaltyValueUsd);
    event TokensRecovered(address indexed token, address indexed to, uint256 amount);
    event DexConfigured(uint8 indexed dexId, address router, address quoter, bool enabled);
    event WETHUpdated(address indexed weth);
    event RebalanceFeesUpdated(uint256 ownerFeeBps, uint256 callerFeeBps);
    event BucketInfoUpdated(address indexed oldBucketInfo, address indexed newBucketInfo, address indexed updatedBy);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error PlatformNotOperational();
    error InvalidToken(address token);
    error InvalidDistributions();
    error WeightSumMismatch(uint256 totalWeight);
    error DuplicateToken(address token);
    error EmptyDistributions();
    error ZeroAddress();
    error ZeroAmount();
    error InvalidRedeemAmount();
    error OwnerNotAccountable();
    error SwapIsPaused();
    error SwapNotPaused();
    error InsufficientShares();
    error ETHTransferFailed();
    error SwapFailed();
    error ValueLossTooHigh(uint256 valueBefore, uint256 valueAfter);
    error DistributionMismatch(address token, uint256 actual, uint256 target);
    error CannotRecoverWhitelistedToken(address token);
    error UnauthorizedBucketInfoUpdate();

    /*//////////////////////////////////////////////////////////////
                              MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Ensures the platform is operational
    modifier whenPlatformOperational() {
        if (!bucketInfo.isPlatformOperational()) {
            revert PlatformNotOperational();
        }
        _;
    }

    /// @notice Ensures swap/rebalance functions are not paused
    modifier whenSwapNotPaused() {
        if (swapPaused) revert SwapIsPaused();
        _;
    }

    /// @notice Ensures owner holds >= 5% of total supply; reverts owner-only calls otherwise
    modifier onlyAccountableOwner() {
        _checkOwner();
        if (!isBucketAccountable()) revert OwnerNotAccountable();
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
     * @notice Initializes the PassiveBucket contract
     * @param bucketInfoAddr The BucketInfo contract address
     * @param distributions The initial bucket distributions (token + weight arrays)
     * @param _oneInchRouter The 1inch aggregation router address
     */
    function initialize(
        address bucketInfoAddr,
        BucketDistribution[] calldata distributions,
        address _oneInchRouter,
        string memory name,
        string memory symbol
    ) external initializer {
        if (bucketInfoAddr == address(0)) revert ZeroAddress();
        if (_oneInchRouter == address(0)) revert ZeroAddress();

        __ERC20_init(name, symbol);
        __ERC20Burnable_init();
        __Pausable_init();
        __Ownable_init(msg.sender);
        // __ReentrancyGuard_init();
        // __UUPSUpgradeable_init();

        bucketInfo = IBucketInfo(bucketInfoAddr);
        oneInchRouter = _oneInchRouter;

        rebalanceOwnerFeeBps = 600; // 6% default
        rebalanceCallerFeeBps = 300; // 3% default

        _validateAndStoreDistributions(distributions);
    }

    /*//////////////////////////////////////////////////////////////
                        DEPOSIT / REDEEM
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deposit a whitelisted token and receive share tokens
     * @dev For ETH deposits, send value with msg.value and set token to address(0).
     *      For ERC-20, approve this contract first.
     * @param token The token address (address(0) for ETH)
     * @param amount The amount to deposit (ignored for ETH; msg.value is used)
     */
    function deposit(address token, uint256 amount)
        external
        payable
        nonReentrant
        whenNotPaused
        whenPlatformOperational
    {
        if (!bucketInfo.isTokenValid(token)) revert InvalidToken(token);

        uint256 actualAmount;
        if (token == address(0)) {
            actualAmount = msg.value;
        } else {
            actualAmount = amount;
            IERC20(token).safeTransferFrom(msg.sender, address(this), actualAmount);
        }
        if (actualAmount == 0) revert ZeroAmount();

        // Initialize share price on first deposit
        if (tokenPrice == 0) {
            tokenPrice = INITIAL_TOKEN_PRICE;
        }

        // Calculate deposit value in USD (8 decimals)
        uint256 oraclePrice = bucketInfo.getTokenPrice(token);
        if (oraclePrice == 0) revert InvalidToken(token);
        uint8 decimals = _getTokenDecimals(token);
        uint256 depositValue = (actualAmount * oraclePrice) / (10 ** decimals);

        // Calculate shares to mint
        uint256 sharesToMint = (depositValue * PRECISION) / tokenPrice;
        if (sharesToMint == 0) revert ZeroAmount();

        totalDepositValue += depositValue;
        _mint(msg.sender, sharesToMint);

        emit Deposited(msg.sender, token, actualAmount, sharesToMint, depositValue);
    }

    /**
     * @notice Redeem shares for proportional underlying tokens from the distribution
     * @dev Owner can only redeem if isBucketAccountable is true before and after.
     *      Returns tokens based on actual contract holdings proportional to share ownership.
     * @param shares The number of share tokens to redeem
     */
    function redeem(uint256 shares) external nonReentrant whenNotPaused whenPlatformOperational {
        if (shares == 0 || shares > balanceOf(msg.sender)) {
            revert InvalidRedeemAmount();
        }

        // Owner accountability check (before)
        bool isOwnerCaller = (msg.sender == owner());
        if (isOwnerCaller) {
            if (!isBucketAccountable()) revert OwnerNotAccountable();
        }

        uint256 supply = totalSupply();

        // Calculate return amounts before burning
        uint256 len = _bucketDistributions.length;
        uint256[] memory returnAmounts = new uint256[](len);
        address[] memory returnTokens = new address[](len);
        for (uint256 i = 0; i < len; i++) {
            returnTokens[i] = _bucketDistributions[i].token;
            uint256 balance = _getTokenBalance(returnTokens[i]);
            returnAmounts[i] = (balance * shares) / supply;
        }

        // Track withdrawal value
        uint256 withdrawValue = _calculateValueOfShares(shares, supply);
        totalWithdrawValue += withdrawValue;

        // Burn shares (effect)
        _burn(msg.sender, shares);

        // Transfer tokens (interactions)
        for (uint256 i = 0; i < len; i++) {
            if (returnAmounts[i] > 0) {
                _transferToken(returnTokens[i], msg.sender, returnAmounts[i]);
                emit TokenReturned(msg.sender, returnTokens[i], returnAmounts[i]);
            }
        }

        // Owner accountability check (after)
        if (isOwnerCaller) {
            if (!isBucketAccountable()) revert OwnerNotAccountable();
        }

        emit Redeemed(msg.sender, shares);
    }

    /*//////////////////////////////////////////////////////////////
                      BUCKET DISTRIBUTION MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Update the bucket distributions (owner only, must be accountable)
     * @param distributions The new bucket distributions
     */
    function updateBucketDistributions(BucketDistribution[] calldata distributions)
        external
        onlyAccountableOwner
        whenPlatformOperational
    {
        _validateAndStoreDistributions(distributions);
    }

    /**
     * @notice Returns the current bucket distributions
     * @return Array of BucketDistribution structs
     */
    function getBucketDistributions() external view returns (BucketDistribution[] memory) {
        return _bucketDistributions;
    }

    /*//////////////////////////////////////////////////////////////
                          ACCOUNTABILITY
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Check if the owner holds at least 5% of total supply
     * @return True if owner holds >= 5% or total supply is 0
     */
    function isBucketAccountable() public view returns (bool) {
        uint256 supply = totalSupply();
        if (supply == 0) return true;
        return (balanceOf(owner()) * BPS_DENOMINATOR) / supply >= MIN_OWNER_BPS;
    }

    /*//////////////////////////////////////////////////////////////
                          REBALANCING
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Rebalance the portfolio via best DEX offers
     * @dev Callable by any shareholder with no input. Automatically computes required swaps
     *      to realign holdings to target distribution, querying all configured DEXs for the
     *      best price per swap. If the distribution is already within tolerance, no swaps are
     *      executed. After the swap block, fees are always settled based on the change in
     *      total portfolio value: platform fee to BucketInfo, ownerFeeBps to owner,
     *      callerFeeBps to caller (minted as shares), and a penalty burned from owner on
     *      value decrease.
     */
    function rebalanceByDefi() external nonReentrant whenNotPaused whenSwapNotPaused whenPlatformOperational {
        if (balanceOf(msg.sender) == 0) revert InsufficientShares();

        uint256 totalValueBefore = _calculateTotalValue();
        uint256 beforeTokenPrice = tokenPrice;

        address[] memory tokens = bucketInfo.getWhitelistedTokens();
        
        // Only execute swaps when distribution has drifted outside tolerance
        if (!_isDistributionValid()) {
            // uint256 len = _bucketDistributions.length;
            // address[] memory tokens = bucketInfo.getWhitelistedTokens();
            uint256 len = tokens.length;
            // Classify each distribution token as a seller (overweight) or buyer (underweight)
            address[] memory sellTokens = new address[](len);
            uint256[] memory sellAmounts = new uint256[](len); // in token-native units
            address[] memory buyTokens = new address[](len);
            uint256[] memory buyDeficits = new uint256[](len); // in USD (8 decimals)
            uint256[] memory countAndDeficit = new uint256[](3); // array of keeping sellCount, buyCount and totalDeficit
            // uint256 sellCount = 0;
            // uint256 buyCount = 0;
            // uint256 totalDeficit = 0;

            for (uint256 i = 0; i < len; i++) {
                address token = tokens[i];
                uint256 currentValueUSD = _getTokenValue(token);
                // Find target distribution weight based on token address (0 for ETH) and calculate target USD value
                uint256 targetWeight = 0;
                for (uint256 j = 0; j < _bucketDistributions.length; j++) {
                    if (_bucketDistributions[j].token == token) {
                        targetWeight = _bucketDistributions[j].weight;
                        break;
                    }
                }
                uint256 targetValueUSD = (totalValueBefore * targetWeight) / WEIGHT_SUM;
                
                if (currentValueUSD > targetValueUSD) {
                    // Overweight: convert excess USD value into token units to sell
                    uint256 excessUSD = currentValueUSD - targetValueUSD;
                    uint256 price = bucketInfo.getTokenPrice(token);
                    if (price == 0) revert InvalidToken(token);
                    uint8 dec = _getTokenDecimals(token);
                    uint256 excessTokens = (excessUSD * (10 ** dec)) / price;
                    if (excessTokens > 0) {
                        sellTokens[countAndDeficit[0]] = token;
                        sellAmounts[countAndDeficit[0]] = excessTokens;
                        countAndDeficit[0]++;
                    }
                } else if (targetValueUSD > currentValueUSD) {
                    // Underweight: record USD deficit for proportional buy allocation
                    uint256 deficitUSD = targetValueUSD - currentValueUSD;
                    buyTokens[countAndDeficit[1]] = token;
                    buyDeficits[countAndDeficit[1]] = deficitUSD;
                    countAndDeficit[2] += deficitUSD;
                    countAndDeficit[1]++;
                }
            }
            
            // For each overweight token, sell its excess proportionally to every underweight token
            if (countAndDeficit[2] > 0) {
                for (uint256 i = 0; i < countAndDeficit[0]; i++) {
                    for (uint256 j = 0; j < countAndDeficit[1]; j++) {
                        uint256 amountToSell = (sellAmounts[i] * buyDeficits[j]) / countAndDeficit[2];
                        if (amountToSell > 0) {
                            _executeBestSwap(sellTokens[i], buyTokens[j], amountToSell, 0);
                        }
                    }
                }
            }
        }

        // Calculate new total value and settle fees / update token price
        uint256 totalValueAfter = _calculateTotalValue();
        // Check value loss < 0.5%
        if (totalValueAfter < totalValueBefore) {
            uint256 maxLoss = (totalValueBefore * MAX_VALUE_LOSS_BPS) / BPS_DENOMINATOR;
            if (totalValueBefore - totalValueAfter > maxLoss) {
                revert ValueLossTooHigh(totalValueBefore, totalValueAfter);
            }
        }
        // Revert if distribution is still out of tolerance after swaps
        _verifyDistribution();
        // Send performance fee to BucketInfo, owner and msg.sender based on value change, and burn owner penalty if value decreased
        uint256 tokenTotalSupply = totalSupply();
        tokenPrice = _handleRebalanceFees(
            (beforeTokenPrice * tokenTotalSupply) / PRECISION, totalValueAfter, rebalanceOwnerFeeBps, rebalanceCallerFeeBps
        );

        emit Rebalanced(msg.sender, totalValueBefore, (beforeTokenPrice * tokenTotalSupply) / PRECISION, totalValueAfter, tokenPrice);
    }

    /**
     * @notice Rebalance the portfolio via 1inch aggregation router
     * @dev Callable by any shareholder. Value loss must be < 0.5%.
     *      Fees: 6% of increase to owner, 3% to caller.
     * @param swapCalldata The encoded calldata for the 1inch router
     */
    function rebalanceBy1inch(bytes calldata swapCalldata)
        external
        nonReentrant
        whenNotPaused
        whenSwapNotPaused
        whenPlatformOperational
    {
        if (balanceOf(msg.sender) == 0) revert InsufficientShares();

        uint256 totalValueBefore = _calculateTotalValue();
        uint256 beforeTokenPrice = tokenPrice;

        // Execute swap via 1inch
        (bool success,) = oneInchRouter.call(swapCalldata);
        if (!success) revert SwapFailed();

        uint256 totalValueAfter = _calculateTotalValue();

        // Check value loss < 0.5%
        if (totalValueAfter < totalValueBefore) {
            uint256 maxLoss = (totalValueBefore * MAX_VALUE_LOSS_BPS) / BPS_DENOMINATOR;
            if (totalValueBefore - totalValueAfter > maxLoss) {
                revert ValueLossTooHigh(totalValueBefore, totalValueAfter);
            }
        }

        // Verify distribution matches target
        _verifyDistribution();
        // Send performance fee to BucketInfo, owner and msg.sender based on value change, and burn owner penalty if value decreased
        uint256 tokenTotalSupply = totalSupply();
        tokenPrice = _handleRebalanceFees(
            (beforeTokenPrice * tokenTotalSupply) / PRECISION, totalValueAfter, rebalanceOwnerFeeBps, rebalanceCallerFeeBps
        );

        emit Rebalanced(msg.sender, totalValueBefore, (beforeTokenPrice * tokenTotalSupply) / PRECISION, totalValueAfter, tokenPrice);
    }

    /*//////////////////////////////////////////////////////////////
                        PAUSE MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /// @notice Pause the contract (prevents deposits and redemptions)
    function pause() external onlyAccountableOwner {
        _pause();
    }

    /// @notice Unpause the contract
    function unpause() external onlyAccountableOwner {
        _unpause();
    }

    /// @notice Pause swap/rebalance functions
    function pauseSwap() external onlyAccountableOwner {
        if (swapPaused) revert SwapIsPaused();
        swapPaused = true;
        emit SwapPauseChanged(true);
    }

    /// @notice Unpause swap/rebalance functions
    function unpauseSwap() external onlyAccountableOwner {
        if (!swapPaused) revert SwapNotPaused();
        swapPaused = false;
        emit SwapPauseChanged(false);
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
        if (bucketInfo.isTokenWhitelisted(token)) {
            revert CannotRecoverWhitelistedToken(token);
        }

        _transferToken(token, to, amount);

        emit TokensRecovered(token, to, amount);
    }

    /**
     * @notice Configure a DEX for rebalancing
     * @param dexId The DEX identifier
     * @param router Router address
     * @param quoter Quoter address
     * @param fee Fee tier (for Uniswap-style DEXs)
     * @param enabled Whether the DEX is enabled
     */
    function configureDEX(uint8 dexId, address router, address quoter, uint24 fee, bool enabled) external onlyOwner {
        dexConfigs[dexId] = DexConfig({router: router, quoter: quoter, fee: fee, enabled: enabled});
        if (dexId >= dexCount) {
            dexCount = dexId + 1;
        }
        emit DexConfigured(dexId, router, quoter, enabled);
    }

    /**
     * @notice Set the WETH address for DEX swaps involving native ETH
     * @param _weth The WETH contract address
     */
    function setWETH(address _weth) external onlyOwner {
        if (_weth == address(0)) revert ZeroAddress();
        weth = _weth;
        emit WETHUpdated(_weth);
    }

    /**
     * @notice Update the rebalanceByDefi fee parameters
     * @param _ownerFeeBps  Owner fee in basis points (e.g., 300 = 3%)
     * @param _callerFeeBps Caller fee in basis points (e.g., 100 = 1%)
     */
    function setRebalanceFees(uint256 _ownerFeeBps, uint256 _callerFeeBps) external onlyOwner {
        require(_ownerFeeBps + _callerFeeBps <= BPS_DENOMINATOR, "Fees exceed 100%");
        rebalanceOwnerFeeBps = _ownerFeeBps;
        rebalanceCallerFeeBps = _callerFeeBps;
        emit RebalanceFeesUpdated(_ownerFeeBps, _callerFeeBps);
    }

    /**
     * @notice Update the BucketInfo contract address
     * @dev Can only be called by the current owner of the BucketInfo contract
     * @param newBucketInfo The new BucketInfo contract address
     */
    function updateBucketInfo(address newBucketInfo) external {
        if (newBucketInfo == address(0)) revert ZeroAddress();

        // Only the current BucketInfo owner can update
        address bucketInfoOwner = IBucketInfo(address(bucketInfo)).owner();
        if (msg.sender != bucketInfoOwner) revert UnauthorizedBucketInfoUpdate();

        address oldBucketInfo = address(bucketInfo);
        bucketInfo = IBucketInfo(newBucketInfo);

        emit BucketInfoUpdated(oldBucketInfo, newBucketInfo, msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                          VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Calculate total value of all whitelisted tokens held by the contract
     * @return totalValue Total value in USD with 8 decimals
     */
    function calculateTotalValue() external view returns (uint256) {
        return _calculateTotalValue();
    }

    /**
     * @notice Get the number of distributions
     * @return The length of the distributions array
     */
    function getDistributionCount() external view returns (uint256) {
        return _bucketDistributions.length;
    }

    /*//////////////////////////////////////////////////////////////
                      INTERNAL: DISTRIBUTION VALIDATION
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Validate and store bucket distributions
     * @param distributions The distributions to validate and store
     */
    function _validateAndStoreDistributions(BucketDistribution[] calldata distributions) internal {
        if (distributions.length == 0) revert EmptyDistributions();

        uint256 totalWeight = 0;

        // Check for duplicates and validate tokens
        for (uint256 i = 0; i < distributions.length; i++) {
            if (!bucketInfo.isTokenValid(distributions[i].token)) {
                revert InvalidToken(distributions[i].token);
            }
            if (distributions[i].weight == 0) revert InvalidDistributions();

            // Check for duplicates
            for (uint256 j = 0; j < i; j++) {
                if (distributions[j].token == distributions[i].token) {
                    revert DuplicateToken(distributions[i].token);
                }
            }

            totalWeight += distributions[i].weight;
        }

        if (totalWeight != WEIGHT_SUM) revert WeightSumMismatch(totalWeight);

        // Clear existing and store new
        delete _bucketDistributions;
        for (uint256 i = 0; i < distributions.length; i++) {
            _bucketDistributions.push(distributions[i]);
        }

        emit BucketDistributionsUpdated(distributions);
    }

    /*//////////////////////////////////////////////////////////////
                    INTERNAL: VALUE CALCULATIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Calculate total value of whitelisted tokens in the contract (USD 8 decimals)
     */
    function _calculateTotalValue() internal view returns (uint256) {
        address[] memory tokens = bucketInfo.getWhitelistedTokens();
        uint256 totalValue = 0;
        for (uint256 i = 0; i < tokens.length; i++) {
            totalValue += _getTokenValue(tokens[i]);
        }
        return totalValue;
    }

    /**
     * @dev Calculate the USD value of a given number of shares
     */
    function _calculateValueOfShares(uint256 shares, uint256 supply) internal view returns (uint256) {
        if (supply == 0) return 0;
        return (_calculateTotalValue() * shares) / supply;
    }

    /**
     * @dev Get token balance held by this contract
     */
    function _getTokenBalance(address token) internal view returns (uint256) {
        if (token == address(0)) return address(this).balance;
        return IERC20(token).balanceOf(address(this));
    }

    /**
     * @dev Get token decimals (18 for native ETH)
     */
    function _getTokenDecimals(address token) internal view returns (uint8) {
        if (token == address(0)) return 18;
        return IERC20Metadata(token).decimals();
    }

    /**
     * @dev Get the value of a specific token held by the contract (USD 8 decimals)
     */
    function _getTokenValue(address token) internal view returns (uint256) {
        uint256 balance = _getTokenBalance(token);
        if (balance == 0) return 0;
        uint256 price = bucketInfo.getTokenPrice(token);
        uint8 dec = _getTokenDecimals(token);
        // if price is 0, throw error to prevent division by zero and incorrect value calculation
        if (price == 0) revert InvalidToken(token);
        return (balance * price) / (10 ** dec);
    }

    /*//////////////////////////////////////////////////////////////
                    INTERNAL: TOKEN TRANSFERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Transfer token or ETH to a recipient
     */
    function _transferToken(address token, address to, uint256 amount) internal {
        if (token == address(0)) {
            (bool success,) = to.call{value: amount}("");
            if (!success) revert ETHTransferFailed();
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }

    /*//////////////////////////////////////////////////////////////
                    INTERNAL: DEX SWAP EXECUTION
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Execute a swap using the best available DEX (queries all configured DEXs)
     */
    function _executeBestSwap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut) internal {
        // Handle ETH → WETH wrapping if needed
        address actualTokenIn = tokenIn;
        address actualTokenOut = tokenOut;

        if (tokenIn == address(0)) {
            require(weth != address(0), "WETH not set");
            IWETH(weth).deposit{value: amountIn}();
            actualTokenIn = weth;
        }
        if (tokenOut == address(0)) {
            require(weth != address(0), "WETH not set");
            actualTokenOut = weth;
        }

        // Find best DEX
        uint8 bestDex = 0;
        uint256 bestQuote = 0;

        for (uint8 i = 0; i < dexCount; i++) {
            DexConfig memory configTry = dexConfigs[i];
            if (!configTry.enabled || configTry.quoter == address(0)) continue;

            try IQuoter(configTry.quoter)
                .quoteExactInputSingle(
                    IQuoter.QuoteExactInputSingleParams({
                        tokenIn: actualTokenIn,
                        tokenOut: actualTokenOut,
                        amountIn: amountIn,
                        fee: configTry.fee,
                        sqrtPriceLimitX96: 0
                    })
                ) returns (
                uint256 amountOut, uint160, uint32, uint256
            ) {
                if (amountOut > bestQuote) {
                    bestQuote = amountOut;
                    bestDex = i;
                }
            } catch {}
        }

        require(bestQuote > minAmountOut, "No sufficient quote found");

        // Execute on best DEX
        DexConfig memory config = dexConfigs[bestDex];
        IERC20(actualTokenIn).forceApprove(config.router, amountIn);

        ISwapRouter(config.router)
            .exactInputSingle(
                ISwapRouter.ExactInputSingleParams({
                    tokenIn: actualTokenIn,
                    tokenOut: actualTokenOut,
                    fee: config.fee,
                    recipient: address(this),
                    amountIn: amountIn,
                    amountOutMinimum: (bestQuote * 95) / 100,
                    sqrtPriceLimitX96: 0
                })
            );
        
        IERC20(actualTokenIn).forceApprove(config.router, 0);

        // Unwrap WETH → ETH if needed
        // if (tokenOut == address(0)) {
            uint256 wethBal = IWETH(weth).balanceOf(address(this));
            if (wethBal > 0) {
                IWETH(weth).withdraw(wethBal);
            }
        // }
    }

    /*//////////////////////////////////////////////////////////////
                INTERNAL: DISTRIBUTION VERIFICATION
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Returns true if all token weights are within DISTRIBUTION_TOLERANCE of targets.
     *      Returns true when total value is zero (nothing to check).
     */
    function _isDistributionValid() internal view returns (bool) {
        uint256 totalValue = _calculateTotalValue();
        if (totalValue == 0) return true;

        for (uint256 i = 0; i < _bucketDistributions.length; i++) {
            uint256 tokenValue = _getTokenValue(_bucketDistributions[i].token);
            uint256 actualWeight = (tokenValue * WEIGHT_SUM) / totalValue;
            uint256 targetWeight = _bucketDistributions[i].weight;

            if (
                actualWeight + DISTRIBUTION_TOLERANCE < targetWeight
                    || actualWeight > targetWeight + DISTRIBUTION_TOLERANCE
            ) {
                return false;
            }
        }
        return true;
    }

    /**
     * @dev Verify that the current token value distribution matches target weights
     * within the allowed tolerance. Reverts with DistributionMismatch on failure.
     */
    function _verifyDistribution() internal view {
        uint256 totalValue = _calculateTotalValue();
        if (totalValue == 0) return;

        for (uint256 i = 0; i < _bucketDistributions.length; i++) {
            uint256 tokenValue = _getTokenValue(_bucketDistributions[i].token);
            uint256 actualWeight = (tokenValue * WEIGHT_SUM) / totalValue;
            uint256 targetWeight = _bucketDistributions[i].weight;

            // Allow DISTRIBUTION_TOLERANCE% deviation
            if (
                actualWeight + DISTRIBUTION_TOLERANCE < targetWeight
                    || actualWeight > targetWeight + DISTRIBUTION_TOLERANCE
            ) {
                revert DistributionMismatch(_bucketDistributions[i].token, actualWeight, targetWeight);
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                    INTERNAL: REBALANCE FEE HANDLING
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Handle fee distribution and token price updates after rebalance
     * @param totalValueBefore Total value before rebalance (USD 8 dec)
     * @param totalValueAfter Total value after rebalance (USD 8 dec)
     * @param ownerFeeBps Owner fee in basis points (e.g., 300 = 3%)
     * @param callerFeeBps Caller fee in basis points (e.g., 100 = 1%)
     */
    function _handleRebalanceFees(
        uint256 totalValueBefore,
        uint256 totalValueAfter,
        uint256 ownerFeeBps,
        uint256 callerFeeBps
    ) internal returns (uint256) {
        bool accountable = isBucketAccountable();
        // Calculate new token price (pre-fee-minting)
        uint256 newPrice = (totalSupply() > 0) ? (totalValueAfter * PRECISION) / totalSupply() : INITIAL_TOKEN_PRICE;
        uint256 valueDifference = totalValueAfter > totalValueBefore
            ? totalValueAfter - totalValueBefore
            : totalValueBefore - totalValueAfter;

        if (totalValueAfter > totalValueBefore) {
            uint256 increase = totalValueAfter - totalValueBefore;
            if (accountable) {
                // Owner fee
                uint256 ownerFeeValue = (increase * ownerFeeBps * PRECISION) / BPS_DENOMINATOR;
                if (ownerFeeValue > 0 && newPrice > 0) {
                    uint256 ownerShares = (ownerFeeValue) / newPrice;
                    ownerFeeValue = ownerFeeValue / PRECISION; // adjust back to USD value for event
                    if (ownerShares > 0) {
                        _mint(owner(), ownerShares);
                        emit RebalanceFeeDistributed(owner(), ownerShares, ownerFeeValue);
                    }
                }
            }
            // Caller fee
            uint256 callerFeeValue = (increase * callerFeeBps * PRECISION) / BPS_DENOMINATOR;
            if (callerFeeValue > 0 && newPrice > 0) {
                uint256 callerShares = (callerFeeValue) / newPrice;
                callerFeeValue = callerFeeValue / PRECISION; // adjust back to USD value for event
                if (callerShares > 0) {
                    _mint(msg.sender, callerShares);
                    emit RebalanceFeeDistributed(msg.sender, callerShares, callerFeeValue);
                }
            }
        } else if (totalValueAfter < totalValueBefore) {
            uint256 decrease = totalValueBefore - totalValueAfter;

            // Owner bears some of the decrease (burned from owner shares)
            if (accountable) {
                uint256 penaltyValue = (decrease * (callerFeeBps + ownerFeeBps) * PRECISION) / BPS_DENOMINATOR;
                uint256 sharesToBurn = (penaltyValue) / newPrice;
                penaltyValue = penaltyValue / PRECISION; // adjust back to USD value for event
                uint256 ownerBalance = balanceOf(owner());

                if (sharesToBurn > ownerBalance) {
                    sharesToBurn = ownerBalance;
                }
                if (sharesToBurn > 0) {
                    _burn(owner(), sharesToBurn);
                    emit OwnerPenaltyBurned(owner(), sharesToBurn, penaltyValue);
                }
            }
        }

        // Platform fee to BucketInfo
        uint256 platformFeeValue = bucketInfo.calculateFee(valueDifference);
        if (platformFeeValue > 0 && newPrice > 0) {
            uint256 platformShares = (platformFeeValue * PRECISION) / newPrice;
            if (platformShares > 0) {
                _mint(address(bucketInfo), platformShares);
                emit RebalanceFeeDistributed(address(bucketInfo), platformShares, platformFeeValue);
            }
        }

        // Update token price to reflect new state
        return (totalSupply() > 0) ? (_calculateTotalValue() * PRECISION) / totalSupply() : INITIAL_TOKEN_PRICE;
    }

    /*//////////////////////////////////////////////////////////////
                          UUPS UPGRADE
    //////////////////////////////////////////////////////////////*/

    /// @dev Authorize upgrade (owner only)
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /*//////////////////////////////////////////////////////////////
                        RECEIVE ETH
    //////////////////////////////////////////////////////////////*/

    /// @notice Allow contract to receive ETH
    receive() external payable {}
}
