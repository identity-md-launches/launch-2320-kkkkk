// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {KeelTest} from "./support/KeelTest.sol";
import {KeelV2Factory} from "../src/KeelV2Factory.sol";
import {KeelHeart} from "../src/KeelHeart.sol";

contract RejectingRecipient {
    receive() external payable {
        revert("no");
    }
}

contract PermitTest is KeelTest {
    int24 private constant TICK = -230280;

    function _try(address who, int24 tick, uint256 deadline, bytes memory signature, uint256 value)
        private
        returns (address token)
    {
        vm.prank(who);
        (token,) = factory.launch{value: value}("k", "l", "", address(0), tick, 300, deadline, signature);
    }

    function test_validPermitConsumesNonceAndForwardsFee() public {
        uint256 deadline = vm.getBlockTimestamp() + 10;
        bytes memory signature = _permit(signerKey, creator, address(0), TICK, deadline, 0);
        assertEq(factory.nonces(creator), 0);
        uint256 teamBefore = team.balance;
        address token = _try(creator, TICK, deadline, signature, 0.0001 ether);
        assertEq(factory.nonces(creator), 1);
        assertEq(team.balance - teamBefore, 0.0001 ether);
        assertEq(address(factory).balance, 0);
        assertTrue(token != address(0));
        vm.expectRevert(KeelV2Factory.InvalidSignature.selector);
        _try(creator, TICK, deadline, signature, 0.0001 ether);
        bytes memory next = _permit(signerKey, creator, address(0), TICK, deadline, 1);
        _try(creator, TICK, deadline, next, 0.0001 ether);
        assertEq(factory.nonces(creator), 2);
    }

    function test_permitBindsCreatorQuoteTickDeadlineAndSigner() public {
        uint256 deadline = vm.getBlockTimestamp() + 10;
        bytes memory signature = _permit(signerKey, creator, address(0), TICK, deadline, 0);
        vm.deal(outsider, 1 ether);
        vm.expectRevert(KeelV2Factory.InvalidSignature.selector);
        _try(outsider, TICK, deadline, signature, 0.0001 ether);
        vm.expectRevert(KeelV2Factory.InvalidSignature.selector);
        _try(creator, TICK + 60, deadline, signature, 0.0001 ether);
        vm.expectRevert(KeelV2Factory.InvalidSignature.selector);
        _try(creator, TICK, deadline + 1, signature, 0.0001 ether);
        bytes memory wrongSigner = _permit(0xBAD, creator, address(0), TICK, deadline, 0);
        vm.expectRevert(KeelV2Factory.InvalidSignature.selector);
        _try(creator, TICK, deadline, wrongSigner, 0.0001 ether);
        bytes memory wrongQuote = _permit(signerKey, creator, address(usdc), TICK, deadline, 0);
        vm.expectRevert(KeelV2Factory.InvalidSignature.selector);
        _try(creator, TICK, deadline, wrongQuote, 0.0001 ether);
        vm.expectRevert(KeelV2Factory.InvalidSignature.selector);
        _try(creator, TICK, deadline, "", 0.0001 ether);
        bytes memory malleable = abi.encodePacked(signature);
        malleable[64] = bytes1(uint8(malleable[64]) == 27 ? 28 : 27);
        vm.expectRevert(KeelV2Factory.InvalidSignature.selector);
        _try(creator, TICK, deadline, malleable, 0.0001 ether);
        vm.warp(deadline + 1);
        vm.expectRevert(KeelV2Factory.PermitExpired.selector);
        _try(creator, TICK, deadline, signature, 0.0001 ether);
        vm.warp(deadline);
        _try(creator, TICK, deadline, signature, 0.0001 ether);
    }

    function test_signerReplacementInvalidatesOldPermits() public {
        uint256 deadline = vm.getBlockTimestamp() + 10;
        bytes memory old = _permit(signerKey, creator, address(0), TICK, deadline, 0);
        vm.prank(owner);
        factory.setSigner(vm.addr(0xB0B));
        vm.expectRevert(KeelV2Factory.InvalidSignature.selector);
        _try(creator, TICK, deadline, old, 0.0001 ether);
        _try(creator, TICK, deadline, _permit(0xB0B, creator, address(0), TICK, deadline, 0), 0.0001 ether);
        KeelV2Factory bare = new KeelV2Factory(manager, owner, team);
        assertEq(bare.signer(), address(0));
    }

    function test_wrongFeeAndFeeChanges() public {
        uint256 deadline = vm.getBlockTimestamp() + 10;
        bytes memory signature = _permit(signerKey, creator, address(0), TICK, deadline, 0);
        vm.expectRevert(KeelV2Factory.WrongFee.selector);
        _try(creator, TICK, deadline, signature, 0.0001 ether - 1);
        vm.expectRevert(KeelV2Factory.WrongFee.selector);
        _try(creator, TICK, deadline, signature, 0.0001 ether + 1);
        vm.startPrank(owner);
        vm.expectRevert(KeelV2Factory.InvalidFee.selector);
        factory.setLaunchFee(0.01 ether + 1);
        factory.setLaunchFee(0.01 ether);
        vm.stopPrank();
        vm.expectRevert(KeelV2Factory.WrongFee.selector);
        _try(creator, TICK, deadline, signature, 0.0001 ether);
        uint256 teamBefore = team.balance;
        _try(creator, TICK, deadline, signature, 0.01 ether);
        assertEq(team.balance - teamBefore, 0.01 ether);
        vm.prank(owner);
        factory.setLaunchFee(0);
        bytes memory next = _permit(signerKey, creator, address(0), TICK, deadline, 1);
        vm.expectRevert(KeelV2Factory.WrongFee.selector);
        _try(creator, TICK, deadline, next, 1);
        _try(creator, TICK, deadline, next, 0);
        assertEq(team.balance - teamBefore, 0.01 ether);
    }

    function test_feeForwardFailureRevertsLaunch() public {
        RejectingRecipient rejecting = new RejectingRecipient();
        vm.prank(owner);
        factory.setTeamRecipient(address(rejecting));
        uint256 deadline = vm.getBlockTimestamp() + 10;
        bytes memory signature = _permit(signerKey, creator, address(0), TICK, deadline, 0);
        vm.expectRevert(KeelV2Factory.FeeTransferFailed.selector);
        _try(creator, TICK, deadline, signature, 0.0001 ether);
        assertEq(factory.nonces(creator), 0);
        vm.prank(owner);
        factory.setLaunchFee(0);
        _try(creator, TICK, deadline, signature, 0);
    }

    function test_tickBoundsStillApplyWithValidPermit() public {
        vm.prank(owner);
        factory.configureQuote(address(0), true, -230280, -230280, false, false);
        uint256 deadline = vm.getBlockTimestamp() + 10;
        bytes memory outside = _permit(signerKey, creator, address(0), TICK - 60, deadline, 0);
        vm.expectRevert(KeelV2Factory.InvalidTicks.selector);
        _try(creator, TICK - 60, deadline, outside, 0.0001 ether);
        _try(
            creator, TICK, deadline, _permit(signerKey, creator, address(0), TICK, deadline, 0), 0.0001 ether
        );
    }

    function test_domainSeparatorBindsChainAndContract() public {
        bytes32 expected = keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
                keccak256("Keel"),
                keccak256("2"),
                block.chainid,
                address(factory)
            )
        );
        assertEq(factory.DOMAIN_SEPARATOR(), expected);
        assertEq(
            factory.LAUNCH_TYPEHASH(),
            keccak256("Launch(address creator,address quote,int24 startTick,uint256 deadline,uint256 nonce)")
        );
        uint256 deadline = vm.getBlockTimestamp() + 10;
        bytes memory signature = _permit(signerKey, creator, address(0), TICK, deadline, 0);
        vm.chainId(block.chainid + 1);
        vm.expectRevert(KeelV2Factory.InvalidSignature.selector);
        _try(creator, TICK, deadline, signature, 0.0001 ether);
    }

    function test_routerHeartSignerWiringGuards() public {
        KeelHeart heart = new KeelHeart(address(hook), owner);
        vm.expectRevert(KeelV2Factory.NotOwner.selector);
        factory.setRouter(address(router));
        vm.expectRevert(KeelV2Factory.NotOwner.selector);
        factory.setHeart(address(heart));
        vm.expectRevert(KeelV2Factory.NotOwner.selector);
        factory.setSigner(outsider);
        vm.expectRevert(KeelV2Factory.NotOwner.selector);
        factory.setLaunchFee(1);
        vm.startPrank(owner);
        vm.expectRevert(KeelV2Factory.InvalidAddress.selector);
        factory.setRouter(address(0));
        vm.expectRevert(KeelV2Factory.InvalidAddress.selector);
        factory.setRouter(outsider);
        vm.expectRevert(KeelV2Factory.InvalidAddress.selector);
        factory.setHeart(address(0));
        vm.expectRevert(KeelV2Factory.InvalidAddress.selector);
        factory.setHeart(outsider);
        vm.expectRevert(KeelV2Factory.InvalidAddress.selector);
        factory.setSigner(address(0));
        factory.setRouter(address(router));
        factory.setHeart(address(heart));
        vm.expectRevert(KeelV2Factory.AlreadySet.selector);
        factory.setRouter(address(heart));
        vm.expectRevert(KeelV2Factory.AlreadySet.selector);
        factory.setHeart(address(router));
        vm.stopPrank();
        assertEq(factory.router(), address(router));
        assertEq(factory.heart(), address(heart));
        assertEq(factory.signer(), signer);
    }
}
