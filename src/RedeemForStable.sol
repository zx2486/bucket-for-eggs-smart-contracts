// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IBucketInfo} from "./interfaces/IBucketInfo.sol";
import {DexConfig, DexSwapLib} from "./libraries/DexSwapLib.sol";
import {SwapExecutionLib} from "./libraries/SwapExecutionLib.sol";

/// @title RedeemForStable
/// @notice Swaps caller-owned tokens into a stablecoin without custody between calls.
/// @dev Tokens sent directly to this contract outside swapForStable cannot be recovered.
contract RedeemForStable is ReentrancyGuardTransient, Ownable {
    using SafeERC20 for IERC20;

    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant MAX_SLIPPAGE_BPS = 1_000;
    uint256 public constant MAX_INPUT_TOKENS = 8;
    uint256 public constant MAX_DEX_CONFIGS = 8;

    error ZeroAddress();
    error InvalidConfiguration();
    error TooManyInputTokens(uint256 count);
    error TooManyDexConfigs(uint256 count);
    error InvalidInputLengths();
    error InvalidAmount(address token);
    error InvalidToken(address token);
    error DuplicateToken(address token);
    error UnsupportedStable(address token);
    error SlippageTooHigh(uint256 requested);
    error InvalidNativeValue(uint256 expected, uint256 received);
    error UnexpectedNativeValue(uint256 received);
    error ReceivedBelowMinReturn(uint256 received, uint256 minReturn);
    error Blacklisted(address account);
    error PlatformNotOperational();
    error PermitAllowanceInsufficient(address token, uint256 required, uint256 available);

    struct SwapContext {
        uint256[] inputBalancesBefore;
        uint256[] amountsIn;
        uint256 stableOut;
        bool hasNativeInput;
    }

    struct PermitData {
        address token;
        uint256 value;
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    IBucketInfo public immutable BUCKET_INFO;
    address public immutable WETH;

    mapping(uint8 => DexConfig) public dexConfigs;
    uint8 public dexCount;

    mapping(address => bool) public isStable;
    address[] private _stables;

    event SwappedForStable(
        address indexed user, address indexed stable, address[] tokens, uint256[] amountsIn, uint256 stableOut
    );

    constructor(address bucketInfo_, address weth_, DexConfig[] memory dexes_, address[] memory stables_)
        Ownable(msg.sender)
    {
        if (bucketInfo_ == address(0) || weth_ == address(0)) revert ZeroAddress();
        if (bucketInfo_.code.length == 0 || weth_.code.length == 0) revert InvalidConfiguration();
        if (dexes_.length == 0 || dexes_.length > MAX_DEX_CONFIGS) {
            revert TooManyDexConfigs(dexes_.length);
        }
        if (stables_.length == 0 || stables_.length > MAX_INPUT_TOKENS) {
            revert InvalidConfiguration();
        }

        BUCKET_INFO = IBucketInfo(bucketInfo_);
        WETH = weth_;

        for (uint256 i; i < dexes_.length; ++i) {
            DexConfig memory config = dexes_[i];
            if (config.enabled && (config.router.code.length == 0 || config.quoter.code.length == 0)) {
                revert InvalidConfiguration();
            }
            dexConfigs[uint8(i)] = config;
        }
        dexCount = uint8(dexes_.length);

        for (uint256 i; i < stables_.length; ++i) {
            address stable = stables_[i];
            if (stable == address(0) || stable.code.length == 0 || isStable[stable]) {
                revert InvalidConfiguration();
            }
            isStable[stable] = true;
            _stables.push(stable);
        }
    }

    function stableTokens() external view returns (address[] memory) {
        return _stables;
    }

    function permitMany(PermitData[] calldata permits) external nonReentrant {
        if (permits.length > MAX_INPUT_TOKENS) revert TooManyInputTokens(permits.length);
        for (uint256 i; i < permits.length; ++i) {
            PermitData calldata permitData = permits[i];
            if (permitData.token == address(0) || permitData.value == 0) {
                revert InvalidAmount(permitData.token);
            }

            try IERC20Permit(permitData.token)
                .permit(
                    msg.sender,
                    address(this),
                    permitData.value,
                    permitData.deadline,
                    permitData.v,
                    permitData.r,
                    permitData.s
                ) {}
                catch {}

            uint256 available;
            try IERC20(permitData.token).allowance(msg.sender, address(this)) returns (uint256 allowance) {
                available = allowance;
            } catch {}
            if (available < permitData.value) {
                revert PermitAllowanceInsufficient(permitData.token, permitData.value, available);
            }
        }
    }

    /// @notice Swap caller-selected tokens into a configured stablecoin.
    /// @dev Oracle pricing may use a manual price up to 30 days old; minTotalOut is the caller's final guard.
    function swapForStable(
        address[] calldata tokens,
        uint256[] calldata amounts,
        address stable,
        uint256 maxSlippageBps,
        uint256 minTotalOut
    ) external payable nonReentrant returns (uint256 stableOut) {
        if (!BUCKET_INFO.isPlatformOperational()) revert PlatformNotOperational();
        if (BUCKET_INFO.isBlacklisted(msg.sender)) revert Blacklisted(msg.sender);
        if (!isStable[stable] || !BUCKET_INFO.isTokenValid(stable)) revert UnsupportedStable(stable);
        if (tokens.length != amounts.length || tokens.length == 0) revert InvalidInputLengths();
        if (tokens.length > MAX_INPUT_TOKENS) revert TooManyInputTokens(tokens.length);
        if (maxSlippageBps > MAX_SLIPPAGE_BPS) revert SlippageTooHigh(maxSlippageBps);

        uint256 ethBefore = address(this).balance - msg.value;
        uint256 stableBefore = IERC20(stable).balanceOf(address(this));
        uint256 wethBefore = IERC20(WETH).balanceOf(address(this));
        SwapContext memory context = _swapInputs(tokens, amounts, stable, maxSlippageBps, ethBefore);

        uint256 callerStableBefore = IERC20(stable).balanceOf(msg.sender);
        IERC20(stable).safeTransfer(msg.sender, context.stableOut);
        stableOut = IERC20(stable).balanceOf(msg.sender) - callerStableBefore;
        if (stableOut < context.stableOut) revert ReceivedBelowMinReturn(stableOut, context.stableOut);
        if (stableOut < minTotalOut) revert ReceivedBelowMinReturn(stableOut, minTotalOut);

        _verifyBalances(tokens, stable, context.inputBalancesBefore, ethBefore, stableBefore, wethBefore);

        emit SwappedForStable(msg.sender, stable, tokens, context.amountsIn, stableOut);
    }

    function _swapInputs(
        address[] calldata tokens,
        uint256[] calldata amounts,
        address stable,
        uint256 maxSlippageBps,
        uint256 ethBefore
    ) internal returns (SwapContext memory context) {
        context.inputBalancesBefore = new uint256[](tokens.length);
        context.amountsIn = new uint256[](tokens.length);

        for (uint256 i; i < tokens.length; ++i) {
            _checkUniqueToken(tokens, i);
            context.inputBalancesBefore[i] =
                tokens[i] == address(0) ? ethBefore : IERC20(tokens[i]).balanceOf(address(this));
        }

        uint256 nativeInputCount;
        for (uint256 i; i < tokens.length; ++i) {
            if (tokens[i] == address(0)) ++nativeInputCount;
        }
        if (nativeInputCount > 1) revert InvalidInputLengths();
        if (nativeInputCount == 0 && msg.value != 0) revert UnexpectedNativeValue(msg.value);

        for (uint256 i; i < tokens.length; ++i) {
            uint256 received = _collectInput(tokens[i], amounts[i], context.inputBalancesBefore[i]);
            if (tokens[i] == address(0)) context.hasNativeInput = true;
            context.amountsIn[i] = received;
            context.stableOut += _swapLeg(tokens[i], stable, received, maxSlippageBps);
        }
    }

    function _checkUniqueToken(address[] calldata tokens, uint256 index) internal pure {
        for (uint256 i; i < index; ++i) {
            if (tokens[i] == tokens[index]) revert DuplicateToken(tokens[index]);
        }
    }

    function _collectInput(address token, uint256 amount, uint256 balanceBefore) internal returns (uint256 received) {
        if (amount == 0) revert InvalidAmount(token);
        if (!BUCKET_INFO.isTokenValid(token)) revert InvalidToken(token);

        if (token == address(0)) {
            if (msg.value != amount) revert InvalidNativeValue(amount, msg.value);
            return amount;
        }

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        received = IERC20(token).balanceOf(address(this)) - balanceBefore;
        if (received == 0) revert InvalidAmount(token);
    }

    function _swapLeg(address token, address stable, uint256 amount, uint256 maxSlippageBps)
        internal
        returns (uint256 received)
    {
        if (token == stable) return amount;

        uint256 stableBefore = IERC20(stable).balanceOf(address(this));
        uint256 legMin = SwapExecutionLib.minReturnForStableLeg(BUCKET_INFO, token, stable, amount, maxSlippageBps);
        DexSwapLib.executeBestSwap(dexConfigs, dexCount, WETH, token, stable, amount, legMin);
        received = IERC20(stable).balanceOf(address(this)) - stableBefore;
        if (received < legMin) revert ReceivedBelowMinReturn(received, legMin);
    }

    function _verifyBalances(
        address[] calldata tokens,
        address stable,
        uint256[] memory inputBalancesBefore,
        uint256 ethBefore,
        uint256 stableBefore,
        uint256 wethBefore
    ) internal view {
        for (uint256 i; i < tokens.length; ++i) {
            uint256 balanceAfter = tokens[i] == address(0)
                ? address(this).balance
                : IERC20(tokens[i]).balanceOf(address(this));
            if (balanceAfter != inputBalancesBefore[i]) revert InvalidConfiguration();
        }
        if (IERC20(WETH).balanceOf(address(this)) != wethBefore) revert InvalidConfiguration();
        if (IERC20(stable).balanceOf(address(this)) != stableBefore) revert InvalidConfiguration();
        if (address(this).balance != ethBefore) revert InvalidConfiguration();
        _verifyRouterAllowances(tokens);
    }

    function _verifyRouterAllowances(address[] calldata tokens) internal view {
        for (uint256 i; i < tokens.length; ++i) {
            address token = tokens[i] == address(0) ? WETH : tokens[i];
            for (uint8 j; j < dexCount; ++j) {
                if (!dexConfigs[j].enabled) continue;
                if (IERC20(token).allowance(address(this), dexConfigs[j].router) != 0) {
                    revert InvalidConfiguration();
                }
            }
        }
        for (uint8 j; j < dexCount; ++j) {
            if (!dexConfigs[j].enabled) continue;
            if (IERC20(WETH).allowance(address(this), dexConfigs[j].router) != 0) {
                revert InvalidConfiguration();
            }
        }
    }

    function withdrawToken(address to, address tokenAddr, uint256 amount) external nonReentrant onlyOwner {
        require(to != address(0), "Invalid recipient");
        require(amount > 0, "Amount must be greater than 0");

        IERC20(tokenAddr).safeTransfer(to, amount);
    }

    function withdrawETH(address payable to, uint256 amount) external nonReentrant onlyOwner {
        require(to != address(0), "Invalid recipient");
        require(amount > 0, "Amount must be greater than 0");
        require(address(this).balance >= amount, "Insufficient ETH balance");

        (bool success,) = to.call{value: amount}("");
        require(success, "ETH transfer failed");
    }
}
