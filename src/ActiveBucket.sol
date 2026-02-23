// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {
    ERC20BurnableUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IBucketInfo} from "./interfaces/IBucketInfo.sol";
import {IFlashLoanReceiver} from "./interfaces/IFlashLoanReceiver.sol";

/**
 * @title ActiveBucket
 * @author Bucket-for-Eggs Team
 * @notice Upgradeable ERC-20 vault without predefined distributions. The owner has full
 * control over portfolio composition via swapBy1inch and flashLoan functions.
 * Users deposit tokens to receive shares and redeem shares to receive proportional tokens.
 * @dev Uses UUPS proxy pattern. Similar to PassiveBucket but without bucket distributions,
 * accountability requirements, or DefiSwap rebalancing.
 */
contract ActiveBucket is
    Initializable,
    ERC20Upgradeable,
    ERC20BurnableUpgradeable,
    PausableUpgradeable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice BucketInfo contract for token validation and pricing
    IBucketInfo public bucketInfo;

    /// @notice 1inch aggregation router address
    address public oneInchRouter;

    /// @notice Share price in USD with 8 decimals
    uint256 public tokenPrice;

    /// @notice Whether swap functions are paused
    bool public swapPaused;

    /// @notice Total deposited value in USD (8 decimals)
    uint256 public totalDepositValue;

    /// @notice Total withdrawn value in USD (8 decimals)
    uint256 public totalWithdrawValue;

    /// @notice Precision constant for share calculations
    uint256 public constant PRECISION = 1e18;

    /// @notice Initial share price ($1 in 8-decimal USD)
    uint256 public constant INITIAL_TOKEN_PRICE = 1e8;

    /// @notice Basis points denominator
    uint256 public constant BPS_DENOMINATOR = 10000;

    /// @notice Maximum value loss for 1inch swap (0.5% = 50 bps)
    uint256 public constant MAX_VALUE_LOSS_BPS = 50;

    /// @notice Flash loan interest rate (2% = 200 bps)
    uint256 public constant FLASH_LOAN_FEE_BPS = 200;

    /// @notice Minimum owner holding (5% in basis points)
    uint256 public constant MIN_OWNER_BPS = 500;

    /// @notice Performance fee in basis points
    uint256 public performanceFeeBps;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event Deposited(
        address indexed user, address indexed token, uint256 amount, uint256 sharesMinted, uint256 depositValueUSD
    );
    event Redeemed(address indexed user, uint256 sharesRedeemed);
    event TokenReturned(address indexed user, address indexed token, uint256 amount);
    event SwapPauseChanged(bool paused);
    event SwapExecuted(
        address indexed caller, uint256 totalValueBefore, uint256 totalValueAfter, uint256 newTokenPrice
    );
    event FlashLoan(
        address indexed initiator, address indexed receiver, address indexed token, uint256 amount, uint256 fee
    );
    event TokensRecovered(address indexed token, address indexed to, uint256 amount);
    event OneInchRouterUpdated(address indexed newRouter);
    event PerformanceFeeDistributed(address indexed recipient, uint256 sharesMinted, uint256 feeValueUSD);
    event PerformancePenaltyBurned(address indexed owner, uint256 sharesBurned, uint256 penaltyValueUSD);
    event PerformanceFeeUpdated(uint256 newFeeBps);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error PlatformNotOperational();
    error InvalidToken(address token);
    error ZeroAddress();
    error ZeroAmount();
    error InvalidRedeemAmount();
    error SwapIsPaused();
    error SwapNotPaused();
    error InsufficientShares();
    error ETHTransferFailed();
    error SwapFailed();
    error ValueLossTooHigh(uint256 valueBefore, uint256 valueAfter);
    error InsufficientBalance();
    error InsufficientRepayment(uint256 expected, uint256 actual);
    error CannotRecoverWhitelistedToken(address token);

    /*//////////////////////////////////////////////////////////////
                              MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier whenPlatformOperational() {
        if (!bucketInfo.isPlatformOperational()) {
            revert PlatformNotOperational();
        }
        _;
    }

    modifier whenSwapNotPaused() {
        if (swapPaused) revert SwapIsPaused();
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
     * @notice Initializes the ActiveBucket contract
     * @param bucketInfoAddr The BucketInfo contract address
     * @param _oneInchRouter The 1inch aggregation router address
     */
    function initialize(address bucketInfoAddr, address _oneInchRouter, string memory name, string memory symbol)
        external
        initializer
    {
        if (bucketInfoAddr == address(0)) revert ZeroAddress();
        if (_oneInchRouter == address(0)) revert ZeroAddress();

        __ERC20_init(name, symbol);
        __ERC20Burnable_init();
        __Pausable_init();
        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        bucketInfo = IBucketInfo(bucketInfoAddr);
        oneInchRouter = _oneInchRouter;

        performanceFeeBps = 500; // 5% default
    }

    /*//////////////////////////////////////////////////////////////
                        DEPOSIT / REDEEM
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deposit a whitelisted token and receive share tokens
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

        if (tokenPrice == 0) {
            tokenPrice = INITIAL_TOKEN_PRICE;
        }

        uint256 oraclePrice = bucketInfo.getTokenPrice(token);
        if (oraclePrice == 0) revert InvalidToken(token);
        uint8 decimals = _getTokenDecimals(token);
        uint256 depositValue = (actualAmount * oraclePrice) / (10 ** decimals);

        uint256 sharesToMint = (depositValue * PRECISION) / tokenPrice;
        if (sharesToMint == 0) revert ZeroAmount();

        totalDepositValue += depositValue;
        _mint(msg.sender, sharesToMint);

        emit Deposited(msg.sender, token, actualAmount, sharesToMint, depositValue);
    }

    /**
     * @notice Redeem shares for proportional underlying tokens
     * @dev Returns all whitelisted tokens proportionally to actual contract holdings
     * @param shares The number of share tokens to redeem
     */
    function redeem(uint256 shares) external nonReentrant whenNotPaused whenPlatformOperational {
        if (shares == 0 || shares > balanceOf(msg.sender)) {
            revert InvalidRedeemAmount();
        }

        uint256 supply = totalSupply();
        address[] memory tokens = bucketInfo.getWhitelistedTokens();

        // Calculate return amounts before burning
        uint256[] memory returnAmounts = new uint256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            uint256 balance = _getTokenBalance(tokens[i]);
            returnAmounts[i] = (balance * shares) / supply;
        }

        // Track withdrawal value
        uint256 withdrawValue = _calculateValueOfShares(shares, supply);
        totalWithdrawValue += withdrawValue;

        // Burn shares
        _burn(msg.sender, shares);

        // Transfer tokens
        for (uint256 i = 0; i < tokens.length; i++) {
            if (returnAmounts[i] > 0) {
                _transferToken(tokens[i], msg.sender, returnAmounts[i]);
                emit TokenReturned(msg.sender, tokens[i], returnAmounts[i]);
            }
        }

        emit Redeemed(msg.sender, shares);
    }

    /*//////////////////////////////////////////////////////////////
                        SWAP BY 1INCH
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Execute a swap via 1inch aggregation router (owner only)
     * @dev Does not check distribution or accountability. Value loss must be < 0.5%.
     * @param swapCalldata The encoded calldata for the 1inch router
     */
    function swapBy1inch(bytes calldata swapCalldata)
        external
        onlyOwner
        nonReentrant
        whenNotPaused
        whenSwapNotPaused
        whenPlatformOperational
    {
        uint256 totalValueBefore = _calculateTotalValue();
        uint256 beforeTokenPrice = tokenPrice;

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

        // Send performance fee to BucketInfo and owner
        uint256 tokenTotalSupply = totalSupply();
        tokenPrice = _handleRebalanceFees(
            beforeTokenPrice * tokenTotalSupply, totalValueAfter, performanceFeeBps, tokenTotalSupply
        );

        emit SwapExecuted(msg.sender, totalValueBefore, totalValueAfter, tokenPrice);
    }

    /*//////////////////////////////////////////////////////////////
                          FLASH LOAN
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Flash loan any token held by the contract (owner only, 2% interest)
     * @param token The token to flash loan (address(0) for ETH)
     * @param amount The amount to flash loan
     * @param receiver The address that receives the tokens and callback
     * @param data Arbitrary data to pass to the flash loan receiver
     */
    function flashLoan(address token, uint256 amount, address receiver, bytes calldata data)
        external
        onlyOwner
        nonReentrant
        whenNotPaused
        whenPlatformOperational
    {
        if (receiver == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        uint256 balanceBefore = _getTokenBalance(token);
        if (balanceBefore < amount) revert InsufficientBalance();

        uint256 fee = (amount * FLASH_LOAN_FEE_BPS) / BPS_DENOMINATOR;
        uint256 beforeTokenPrice = tokenPrice;

        // Transfer tokens to receiver
        _transferToken(token, receiver, amount);

        // Execute callback
        IFlashLoanReceiver(receiver).onFlashLoan(msg.sender, token, amount, fee, data);

        // Check repayment
        uint256 balanceAfter = _getTokenBalance(token);
        uint256 expectedBalance = balanceBefore + fee;
        if (balanceAfter < expectedBalance) {
            revert InsufficientRepayment(expectedBalance, balanceAfter);
        }

        // Send performance fee to BucketInfo and owner
        uint256 totalValueAfterLoan = _calculateTotalValue();
        uint256 tokenTotalSupply = totalSupply();
        tokenPrice = _handleRebalanceFees(
            beforeTokenPrice * tokenTotalSupply, totalValueAfterLoan, performanceFeeBps, tokenTotalSupply
        );

        emit FlashLoan(msg.sender, receiver, token, amount, fee);
    }

    /*//////////////////////////////////////////////////////////////
                        PAUSE MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /// @notice Pause the contract (prevents deposits and redemptions)
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpause the contract
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Pause swap and flash loan functions
    function pauseSwap() external onlyOwner {
        if (swapPaused) revert SwapIsPaused();
        swapPaused = true;
        emit SwapPauseChanged(true);
    }

    /// @notice Unpause swap and flash loan functions
    function unpauseSwap() external onlyOwner {
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

        if (token == address(0)) {
            (bool success,) = to.call{value: amount}("");
            if (!success) revert ETHTransferFailed();
        } else {
            IERC20(token).safeTransfer(to, amount);
        }

        emit TokensRecovered(token, to, amount);
    }

    /**
     * @notice Update the 1inch router address
     * @param newRouter New router address
     */
    function setOneInchRouter(address newRouter) external onlyOwner {
        if (newRouter == address(0)) revert ZeroAddress();
        oneInchRouter = newRouter;
        emit OneInchRouterUpdated(newRouter);
    }

    /**
     * @notice Update the performance fee parameters
     * @param _performanceFeeBps  Performance fee in basis points (e.g., 500 = 5%)
     */
    function setPerformanceFee(uint256 _performanceFeeBps) external onlyOwner {
        require(_performanceFeeBps <= BPS_DENOMINATOR, "Fee exceeds 100%");
        performanceFeeBps = _performanceFeeBps;
        emit PerformanceFeeUpdated(_performanceFeeBps);
    }

    /*//////////////////////////////////////////////////////////////
                          VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Calculate total value of all whitelisted tokens held by the contract
    function calculateTotalValue() external view returns (uint256) {
        return _calculateTotalValue();
    }

    /*//////////////////////////////////////////////////////////////
                      INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _calculateTotalValue() internal view returns (uint256) {
        address[] memory tokens = bucketInfo.getWhitelistedTokens();
        uint256 totalValue = 0;
        for (uint256 i = 0; i < tokens.length; i++) {
            uint256 balance = _getTokenBalance(tokens[i]);
            if (balance > 0) {
                uint256 price = bucketInfo.getTokenPrice(tokens[i]);
                if (price == 0) revert InvalidToken(tokens[i]);
                uint8 dec = _getTokenDecimals(tokens[i]);
                totalValue += (balance * price) / (10 ** dec);
            }
        }
        return totalValue;
    }

    function _calculateValueOfShares(uint256 shares, uint256 supply) internal view returns (uint256) {
        if (supply == 0) return 0;
        return (_calculateTotalValue() * shares) / supply;
    }

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
     * @dev Handle fee distribution and token price updates after swapping or flash loan repayment. Distributes performance fees to BucketInfo and owner, and updates token price based on new total value.
     * @param totalValueBefore Total value before rebalance (USD 8 dec)
     * @param totalValueAfter Total value after rebalance (USD 8 dec)
     * @param ownerFeeBps Owner performancefee in basis points (e.g., 500 = 5%)
     * @param tokenTotalSupply Total supply of the tokens for price calculation
     */
    function _handleRebalanceFees(
        uint256 totalValueBefore,
        uint256 totalValueAfter,
        uint256 ownerFeeBps,
        uint256 tokenTotalSupply
    ) internal returns (uint256) {
        if ((balanceOf(owner()) * BPS_DENOMINATOR) / tokenTotalSupply >= MIN_OWNER_BPS) {
            // provide performance fee or penalty only when owner is accountable (holding >= 5% of total supply)
            if (totalValueAfter > totalValueBefore) {
                uint256 increase = totalValueAfter - totalValueBefore;

                // Calculate new token price (pre-fee-minting)
                uint256 newPrice = (totalValueAfter * PRECISION) / tokenTotalSupply;

                // Platform fee to BucketInfo
                uint256 platformFeeValue = bucketInfo.calculateFee(increase);
                if (platformFeeValue > 0 && newPrice > 0) {
                    uint256 platformShares = (platformFeeValue * PRECISION) / newPrice;
                    if (platformShares > 0) {
                        _mint(address(bucketInfo), platformShares);
                        emit PerformanceFeeDistributed(address(bucketInfo), platformShares, platformFeeValue);
                    }
                }

                // Owner fee
                uint256 ownerFeeValue = (increase * ownerFeeBps) / BPS_DENOMINATOR;
                if (ownerFeeValue > 0 && newPrice > 0) {
                    uint256 ownerShares = (ownerFeeValue * PRECISION) / newPrice;
                    if (ownerShares > 0) {
                        _mint(owner(), ownerShares);
                        emit PerformanceFeeDistributed(owner(), ownerShares, ownerFeeValue);
                    }
                }
            } else if (totalValueAfter < totalValueBefore) {
                uint256 decrease = totalValueBefore - totalValueAfter;

                // Owner bears 5% of decrease (burned from owner shares)
                uint256 penaltyValue = (decrease * performanceFeeBps) / BPS_DENOMINATOR;
                uint256 currentPrice = tokenPrice > 0 ? tokenPrice : INITIAL_TOKEN_PRICE;
                uint256 sharesToBurn = (penaltyValue * PRECISION) / currentPrice;
                uint256 ownerBalance = balanceOf(owner());

                if (sharesToBurn > ownerBalance) {
                    sharesToBurn = ownerBalance;
                }
                if (sharesToBurn > 0) {
                    _burn(owner(), sharesToBurn);
                    emit PerformancePenaltyBurned(owner(), sharesToBurn, penaltyValue);
                }
            }
        }

        // Update token price to reflect new state
        return (totalSupply() > 0) ? (_calculateTotalValue() * PRECISION) / totalSupply() : INITIAL_TOKEN_PRICE;
    }

    /**
     * @notice Check if the owner holds at least 5% of total supply
     * @return True if owner holds >= 5% or total supply is 0
     */
    function isBucketAccountable() public view returns (bool) {
        uint256 supply = totalSupply();
        if (supply == 0) return true;
        return (balanceOf(owner()) * BPS_DENOMINATOR) / supply >= MIN_OWNER_BPS;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /*//////////////////////////////////////////////////////////////
                          RECEIVE ETH
    //////////////////////////////////////////////////////////////*/

    receive() external payable {}
}
