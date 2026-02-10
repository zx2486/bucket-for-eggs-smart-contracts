// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title BasicSwap
 * @dev Contract for depositing USDT and swapping 50% to ETH via 1inch
 * @notice Integrates with 1inch aggregation protocol for optimal swap execution
 */
contract BasicSwap is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event Deposited(address indexed user, uint256 amount);
    event Swapped(uint256 usdtAmount, uint256 ethReceived);
    event USDTWithdrawn(address indexed recipient, uint256 amount);
    event ETHWithdrawn(address indexed recipient, uint256 amount);
    event OneInchRouterUpdated(address indexed newRouter);

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @dev USDT token contract
    IERC20 public immutable usdt;

    /// @dev 1inch aggregation router address
    address public oneInchRouter;

    /// @dev Total USDT deposited by all users
    uint256 public totalUSDTDeposited;

    /// @dev Mapping of user address to their USDT balance
    mapping(address => uint256) public userBalances;

    /// @dev USDT has 6 decimals
    uint256 private constant USDT_DECIMALS = 6;

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initialize the BasicSwap contract
     * @param _usdt Address of the USDT token contract
     * @param _oneInchRouter Address of the 1inch aggregation router
     */
    constructor(address _usdt, address _oneInchRouter) Ownable(msg.sender) {
        require(_usdt != address(0), "Invalid USDT address");
        require(_oneInchRouter != address(0), "Invalid 1inch router address");

        usdt = IERC20(_usdt);
        oneInchRouter = _oneInchRouter;

        emit OneInchRouterUpdated(_oneInchRouter);
    }

    /*//////////////////////////////////////////////////////////////
                        DEPOSIT FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deposit USDT into the contract
     * @param amount Amount of USDT to deposit (with 6 decimals)
     */
    function depositUSDT(uint256 amount) external nonReentrant {
        require(amount > 0, "Amount must be greater than 0");

        // Transfer USDT from user to contract
        usdt.safeTransferFrom(msg.sender, address(this), amount);

        // Update balances
        userBalances[msg.sender] += amount;
        totalUSDTDeposited += amount;

        emit Deposited(msg.sender, amount);
    }

    /*//////////////////////////////////////////////////////////////
                        SWAP FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Swap 50% of contract's USDT holdings to ETH via 1inch
     * @dev Only callable by owner. Requires calldata from 1inch API
     * @param swapCalldata The calldata for the 1inch swap (obtained from 1inch API)
     * @return usdtSwapped Amount of USDT swapped
     * @return ethReceived Amount of ETH received
     */
    function swap(bytes calldata swapCalldata)
        external
        onlyOwner
        nonReentrant
        returns (uint256 usdtSwapped, uint256 ethReceived)
    {
        uint256 contractBalance = usdt.balanceOf(address(this));
        require(contractBalance > 0, "No USDT to swap");

        // Calculate 50% of holdings
        usdtSwapped = contractBalance / 2;
        require(usdtSwapped > 0, "Swap amount too small");

        // Approve 1inch router to spend USDT
        usdt.forceApprove(oneInchRouter, usdtSwapped);

        // Record ETH balance before swap
        uint256 ethBalanceBefore = address(this).balance;

        // Execute swap via 1inch router
        (bool success,) = oneInchRouter.call(swapCalldata);
        require(success, "1inch swap failed");

        // Calculate ETH received
        ethReceived = address(this).balance - ethBalanceBefore;
        require(ethReceived > 0, "No ETH received from swap");

        // Reset approval to 0 for security
        usdt.forceApprove(oneInchRouter, 0);

        emit Swapped(usdtSwapped, ethReceived);

        return (usdtSwapped, ethReceived);
    }

    /*//////////////////////////////////////////////////////////////
                        ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Update the 1inch router address
     * @param newRouter New 1inch router address
     */
    function setOneInchRouter(address newRouter) external onlyOwner {
        require(newRouter != address(0), "Invalid router address");
        oneInchRouter = newRouter;
        emit OneInchRouterUpdated(newRouter);
    }

    /**
     * @notice Withdraw USDT from contract (owner only)
     * @param recipient Address to receive USDT
     * @param amount Amount of USDT to withdraw
     */
    function withdrawUSDT(address recipient, uint256 amount) external onlyOwner nonReentrant {
        require(recipient != address(0), "Invalid recipient");
        require(amount > 0, "Amount must be greater than 0");

        uint256 contractBalance = usdt.balanceOf(address(this));
        require(contractBalance >= amount, "Insufficient USDT balance");

        usdt.safeTransfer(recipient, amount);
        emit USDTWithdrawn(recipient, amount);
    }

    /**
     * @notice Withdraw ETH from contract (owner only)
     * @param recipient Address to receive ETH
     * @param amount Amount of ETH to withdraw
     */
    function withdrawETH(address payable recipient, uint256 amount) external onlyOwner nonReentrant {
        require(recipient != address(0), "Invalid recipient");
        require(amount > 0, "Amount must be greater than 0");
        require(address(this).balance >= amount, "Insufficient ETH balance");

        (bool success,) = recipient.call{value: amount}("");
        require(success, "ETH transfer failed");

        emit ETHWithdrawn(recipient, amount);
    }

    /*//////////////////////////////////////////////////////////////
                        VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Get user's USDT balance
     * @param user Address of the user
     * @return User's USDT balance
     */
    function getUserBalance(address user) external view returns (uint256) {
        return userBalances[user];
    }

    /**
     * @notice Get contract's USDT balance
     * @return Contract's USDT balance
     */
    function getContractUSDTBalance() external view returns (uint256) {
        return usdt.balanceOf(address(this));
    }

    /**
     * @notice Get contract's ETH balance
     * @return Contract's ETH balance
     */
    function getContractETHBalance() external view returns (uint256) {
        return address(this).balance;
    }

    /*//////////////////////////////////////////////////////////////
                        RECEIVE FUNCTION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Allow contract to receive ETH (required for 1inch swaps)
     */
    receive() external payable {}
}
