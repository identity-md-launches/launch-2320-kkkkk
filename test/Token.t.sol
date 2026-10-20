// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {KeelV2Token} from "../src/KeelV2Token.sol";

contract TokenTest is Test {
    KeelV2Token private token;
    address private alice = address(0xA11CE);
    address private poolManager = address(0xB001);

    function setUp() public {
        token = new KeelV2Token("kkkkk", "lllll");
    }

    function test_erc20AndExactBalances() public {
        uint256 supply = 1e27;
        assertEq(token.name(), "kkkkk");
        assertEq(token.symbol(), "lllll");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), supply);
        assertEq(token.balanceOf(address(this)), supply);
        assertTrue(token.transfer(alice, 7));
        assertTrue(token.approve(alice, 11));
        vm.prank(alice);
        assertTrue(token.transferFrom(address(this), poolManager, 11));
        assertEq(token.balanceOf(address(this)), supply - 18);
        assertEq(token.balanceOf(alice), 7);
        assertEq(token.balanceOf(poolManager), 11);
        assertEq(token.allowance(address(this), alice), 0);
        assertEq(token.totalSupply(), supply);
    }

    function test_allowanceAndTransferFailures() public {
        vm.expectRevert(KeelV2Token.InsufficientAllowance.selector);
        vm.prank(alice);
        token.transferFrom(address(this), alice, 1);
        vm.expectRevert(KeelV2Token.InsufficientBalance.selector);
        vm.prank(alice);
        token.transfer(poolManager, 1);
        vm.expectRevert(KeelV2Token.ZeroAddress.selector);
        token.transfer(address(0), 1);
        token.approve(alice, type(uint256).max);
        vm.prank(alice);
        token.transferFrom(address(this), alice, 10);
        assertEq(token.allowance(address(this), alice), type(uint256).max);
    }

    function test_checkpointsSameBlockPoolManagerAndSelfTransfer() public {
        uint256 first = vm.getBlockNumber();
        token.transfer(poolManager, 100);
        token.transfer(poolManager, 200);
        vm.prank(poolManager);
        token.transfer(alice, 50);
        vm.prank(alice);
        token.transfer(alice, 50);
        assertEq(token.checkpointCount(poolManager), 1);
        vm.expectRevert(KeelV2Token.UnfinalizedBlock.selector);
        token.balanceAt(alice, first);
        vm.roll(first + 1);
        assertEq(token.balanceAt(poolManager, first), 250);
        assertEq(token.balanceAt(alice, first), 50);
        assertEq(token.balanceAt(address(this), first), 1e27 - 300);
        vm.prank(poolManager);
        token.transfer(alice, 250);
        vm.roll(first + 5);
        assertEq(token.balanceAt(poolManager, first), 250);
        assertEq(token.balanceAt(poolManager, first + 1), 0);
        assertEq(token.balanceAt(alice, first + 4), 300);
        if (first != 0) assertEq(token.balanceAt(address(this), first - 1), 0);
        vm.expectRevert(KeelV2Token.UnfinalizedBlock.selector);
        token.balanceAt(alice, vm.getBlockNumber() + 1);
    }

    function test_noOwnerMintOrReinitialize() public {
        (bool ownerOk,) = address(token).call(abi.encodeWithSignature("owner()"));
        (bool mintOk,) = address(token).call(abi.encodeWithSignature("mint(address,uint256)", alice, 1));
        (bool initOk,) =
            address(token).call(abi.encodeWithSignature("initialize(string,string)", "bad", "bad"));
        assertFalse(ownerOk);
        assertFalse(mintOk);
        assertFalse(initOk);
        assertEq(token.totalSupply(), 1e27);
    }

    function testFuzz_balanceAtMatchesHistory(uint8 rawCount, uint256 seed) public {
        uint256 count = bound(rawCount, 0, 32);
        uint256 first = vm.getBlockNumber();
        uint256 running;
        uint256[] memory snapshots = new uint256[](count + 1);
        snapshots[0] = 0;
        // Always advance at least once, including the regression input count=0.
        vm.roll(first + 1);
        for (uint256 i; i < count; ++i) {
            uint256 amount = bound(uint256(keccak256(abi.encode(seed, i))), 0, 1e27 - running);
            token.transfer(poolManager, amount);
            running += amount;
            if (i % 2 == 0) {
                uint256 returned = running / 3;
                vm.prank(poolManager);
                token.transfer(address(this), returned);
                running -= returned;
            }
            snapshots[i + 1] = running;
            vm.roll(first + i + 2);
        }
        for (uint256 i; i <= count; ++i) {
            assertEq(token.balanceAt(poolManager, first + i), snapshots[i]);
            assertEq(token.balanceAt(address(this), first + i), 1e27 - snapshots[i]);
        }
        assertEq(token.totalSupply(), 1e27);
    }
}
