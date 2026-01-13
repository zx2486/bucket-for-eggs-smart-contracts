// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../src/BucketToken.sol";

contract BucketTokenTest is Test {
    BucketToken public token;
    address public owner;
    address public user1;
    address public user2;

    // Initial supply: 100 million tokens
    uint256 constant INITIAL_SUPPLY = 100_000_000 * 10**18;
    uint256 constant MAX_SUPPLY = 1_000_000_000 * 10**18;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
        owner = address(this);
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        
        token = new BucketToken(owner, INITIAL_SUPPLY);
    }

    /*//////////////////////////////////////////////////////////////
                            DEPLOYMENT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Deployment() public view {
        assertEq(token.name(), "Bucket Token");
        assertEq(token.symbol(), "BUCKET");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), INITIAL_SUPPLY);
        assertEq(token.balanceOf(owner), INITIAL_SUPPLY);
        assertEq(token.owner(), owner);
    }

    function test_InitialSupplyExceedsMaxSupply() public {
        vm.expectRevert("Initial supply exceeds max supply");
        new BucketToken(owner, MAX_SUPPLY + 1);
    }

    /*//////////////////////////////////////////////////////////////
                            TRANSFER TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Transfer() public {
        uint256 amount = 1000 * 10**18;
        
        vm.expectEmit(true, true, false, true);
        emit Transfer(owner, user1, amount);
        
        token.transfer(user1, amount);
        
        assertEq(token.balanceOf(user1), amount);
        assertEq(token.balanceOf(owner), INITIAL_SUPPLY - amount);
    }

    function test_TransferFrom() public {
        uint256 amount = 1000 * 10**18;
        
        // Approve user1 to spend tokens
        token.approve(user1, amount);
        
        // Transfer from owner to user2 using user1's allowance
        vm.prank(user1);
        token.transferFrom(owner, user2, amount);
        
        assertEq(token.balanceOf(user2), amount);
        assertEq(token.balanceOf(owner), INITIAL_SUPPLY - amount);
        assertEq(token.allowance(owner, user1), 0);
    }

    function testFuzz_Transfer(address to, uint256 amount) public {
        vm.assume(to != address(0));
        vm.assume(to != owner);
        amount = bound(amount, 0, INITIAL_SUPPLY);
        
        token.transfer(to, amount);
        
        assertEq(token.balanceOf(to), amount);
        assertEq(token.balanceOf(owner), INITIAL_SUPPLY - amount);
    }

    /*//////////////////////////////////////////////////////////////
                            MINTING TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Mint() public {
        uint256 mintAmount = 1000 * 10**18;
        uint256 initialBalance = token.balanceOf(user1);
        
        token.mint(user1, mintAmount);
        
        assertEq(token.balanceOf(user1), initialBalance + mintAmount);
        assertEq(token.totalSupply(), INITIAL_SUPPLY + mintAmount);
    }

    function test_MintOnlyOwner() public {
        uint256 mintAmount = 1000 * 10**18;
        
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", user1));
        token.mint(user1, mintAmount);
    }

    function test_MintExceedsMaxSupply() public {
        uint256 remainingSupply = MAX_SUPPLY - INITIAL_SUPPLY;
        
        vm.expectRevert("Minting would exceed max supply");
        token.mint(user1, remainingSupply + 1);
    }

    function testFuzz_Mint(address to, uint256 amount) public {
        vm.assume(to != address(0));
        uint256 maxMintable = MAX_SUPPLY - INITIAL_SUPPLY;
        amount = bound(amount, 0, maxMintable);
        
        token.mint(to, amount);
        
        assertEq(token.totalSupply(), INITIAL_SUPPLY + amount);
    }

    /*//////////////////////////////////////////////////////////////
                            BURNING TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Burn() public {
        uint256 burnAmount = 1000 * 10**18;
        uint256 initialBalance = token.balanceOf(owner);
        
        token.burn(burnAmount);
        
        assertEq(token.balanceOf(owner), initialBalance - burnAmount);
        assertEq(token.totalSupply(), INITIAL_SUPPLY - burnAmount);
    }

    function test_BurnFrom() public {
        uint256 burnAmount = 1000 * 10**18;
        
        // Transfer tokens to user1
        token.transfer(user1, burnAmount);
        
        // User1 approves owner to burn their tokens
        vm.prank(user1);
        token.approve(owner, burnAmount);
        
        // Burn from user1's balance
        token.burnFrom(user1, burnAmount);
        
        assertEq(token.balanceOf(user1), 0);
        assertEq(token.totalSupply(), INITIAL_SUPPLY - burnAmount);
    }

    function testFuzz_Burn(uint256 amount) public {
        amount = bound(amount, 0, INITIAL_SUPPLY);
        
        token.burn(amount);
        
        assertEq(token.totalSupply(), INITIAL_SUPPLY - amount);
        assertEq(token.balanceOf(owner), INITIAL_SUPPLY - amount);
    }

    /*//////////////////////////////////////////////////////////////
                            PAUSE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Pause() public {
        token.pause();
        assertTrue(token.paused());
    }

    function test_Unpause() public {
        token.pause();
        token.unpause();
        assertFalse(token.paused());
    }

    function test_PauseOnlyOwner() public {
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", user1));
        token.pause();
    }

    function test_UnpauseOnlyOwner() public {
        token.pause();
        
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", user1));
        token.unpause();
    }

    function test_TransferWhenPaused() public {
        uint256 amount = 1000 * 10**18;
        token.pause();
        
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        token.transfer(user1, amount);
    }

    function test_MintWhenPaused() public {
        uint256 amount = 1000 * 10**18;
        token.pause();
        
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        token.mint(user1, amount);
    }

    function test_BurnWhenPaused() public {
        uint256 amount = 1000 * 10**18;
        token.pause();
        
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        token.burn(amount);
    }

    /*//////////////////////////////////////////////////////////////
                            PERMIT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Permit() public {
        uint256 privateKey = 0xA11CE;
        address alice = vm.addr(privateKey);
        
        // Transfer some tokens to alice
        token.transfer(alice, 1000 * 10**18);
        
        uint256 amount = 100 * 10**18;
        uint256 deadline = block.timestamp + 1 hours;
        
        // Create permit signature
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                alice,
                user1,
                amount,
                token.nonces(alice),
                deadline
            )
        );
        
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash)
        );
        
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        
        // Execute permit
        token.permit(alice, user1, amount, deadline, v, r, s);
        
        assertEq(token.allowance(alice, user1), amount);
        assertEq(token.nonces(alice), 1);
    }

    /*//////////////////////////////////////////////////////////////
                            OWNERSHIP TESTS
    //////////////////////////////////////////////////////////////*/

    function test_TransferOwnership() public {
        token.transferOwnership(user1);
        assertEq(token.owner(), user1);
    }

    function test_RenounceOwnership() public {
        token.renounceOwnership();
        assertEq(token.owner(), address(0));
    }

    /*//////////////////////////////////////////////////////////////
                            GAS TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Gas_Transfer() public {
        uint256 amount = 1000 * 10**18;
        token.transfer(user1, amount);
    }

    function test_Gas_Mint() public {
        uint256 amount = 1000 * 10**18;
        token.mint(user1, amount);
    }

    function test_Gas_Burn() public {
        uint256 amount = 1000 * 10**18;
        token.burn(amount);
    }
}
