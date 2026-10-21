// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {KeelTest} from "./support/KeelTest.sol";
import {FixedRateModule} from "../src/FixedRateModule.sol";
import {RateModuleBase} from "../src/RateModuleBase.sol";
import {KeelV2Token} from "../src/KeelV2Token.sol";
import {KeelV2Hook} from "../src/KeelV2Hook.sol";
import {KeelV2Factory} from "../src/KeelV2Factory.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

contract TakeoverCaller {
    function take(KeelV2Hook hook, address token, address next) external {
        hook.setCreatorByTakeover(token, next);
    }
}

contract RulesTest is KeelTest {
    function test_lowerImmediateCancelsPending() public {
        (, bytes32 id,) = _launch(address(0), 300);
        vm.startPrank(creator);
        module.scheduleRaise(id, 400);
        module.lowerRate(id, 100);
        assertEq(module.feeBps(id, true, ""), 100);
        (, uint16 pending, uint256 eta) = module.rates(id);
        assertEq(pending, 0);
        assertEq(eta, 0);
        vm.expectRevert(RateModuleBase.NoPendingRaise.selector);
        module.applyRaise(id);
        vm.stopPrank();
    }

    function test_raiseDelayAndBoundaryAndCancellation() public {
        (, bytes32 id,) = _launch(address(0), 300);
        uint256 start = vm.getBlockTimestamp();
        vm.startPrank(creator);
        module.scheduleRaise(id, 400);
        assertEq(module.feeBps(id, false, ""), 300);
        vm.warp(start + 1 days - 1);
        vm.expectRevert(RateModuleBase.RaiseNotReady.selector);
        module.applyRaise(id);
        vm.warp(start + 1 days);
        module.applyRaise(id);
        assertEq(module.feeBps(id, true, ""), 400);
        module.scheduleRaise(id, 500);
        module.cancelRaise(id);
        vm.warp(start + 3 days);
        vm.expectRevert(RateModuleBase.NoPendingRaise.selector);
        module.applyRaise(id);
        vm.stopPrank();
    }

    function test_rateGuardsAndUnauthorized() public {
        (, bytes32 id,) = _launch(address(0), 300);
        vm.expectRevert(KeelV2Hook.NotCreator.selector);
        module.lowerRate(id, 200);
        vm.startPrank(creator);
        vm.expectRevert(RateModuleBase.InvalidRate.selector);
        module.lowerRate(id, 99);
        vm.expectRevert(RateModuleBase.InvalidRate.selector);
        module.lowerRate(id, 300);
        vm.expectRevert(RateModuleBase.InvalidRate.selector);
        module.scheduleRaise(id, 401);
        vm.expectRevert(RateModuleBase.InvalidRate.selector);
        module.scheduleRaise(id, 501);
        vm.expectRevert(RateModuleBase.InvalidRate.selector);
        module.scheduleRaise(id, 300);
        vm.expectRevert(RateModuleBase.NoPendingRaise.selector);
        module.cancelRaise(id);
        vm.stopPrank();
        vm.expectRevert(RateModuleBase.OnlyHook.selector);
        module.initialize(id, 100);
        vm.expectRevert(RateModuleBase.UnknownPool.selector);
        module.feeBps(bytes32(uint256(7)), true, "");
    }

    function test_rescheduleRestartsRaiseDelay() public {
        (, bytes32 id,) = _launch(address(0), 300);
        uint256 start = vm.getBlockTimestamp();
        vm.startPrank(creator);
        module.scheduleRaise(id, 350);
        vm.warp(start + 23 hours);
        module.scheduleRaise(id, 400);
        vm.warp(start + 24 hours);
        vm.expectRevert(RateModuleBase.RaiseNotReady.selector);
        module.applyRaise(id);
        vm.warp(start + 47 hours);
        module.applyRaise(id);
        assertEq(module.feeBps(id, true, ""), 400);
        vm.stopPrank();
    }

    function test_allCreatorActionsRefreshActivity() public {
        (KeelV2Token token, bytes32 id,) = _launch(address(0), 300);
        uint256 start = vm.getBlockTimestamp();
        vm.startPrank(creator);
        vm.warp(start + 1);
        module.scheduleRaise(id, 400);
        assertEq(hook.poolInfo(id).lastActive, start + 1);
        vm.warp(start + 2);
        module.cancelRaise(id);
        assertEq(hook.poolInfo(id).lastActive, start + 2);
        vm.warp(start + 3);
        module.lowerRate(id, 200);
        assertEq(hook.poolInfo(id).lastActive, start + 3);
        vm.warp(start + 4);
        module.scheduleRaise(id, 300);
        vm.warp(start + 4 + 1 days);
        module.applyRaise(id);
        assertEq(hook.poolInfo(id).lastActive, vm.getBlockTimestamp());
        vm.warp(start + 5 + 1 days);
        hook.ping(address(token));
        assertEq(hook.poolInfo(id).lastActive, vm.getBlockTimestamp());
        vm.stopPrank();
    }

    function test_creatorTransferAndPendingRaiseControl() public {
        (KeelV2Token token, bytes32 id,) = _launch(address(0), 300);
        vm.startPrank(creator);
        module.scheduleRaise(id, 400);
        vm.expectRevert(KeelV2Hook.InvalidAddress.selector);
        hook.transferCreator(address(token), address(0));
        hook.transferCreator(address(token), successor);
        vm.expectRevert(KeelV2Hook.NotCreator.selector);
        hook.ping(address(token));
        vm.expectRevert(KeelV2Hook.NotCreator.selector);
        module.cancelRaise(id);
        vm.stopPrank();
        vm.startPrank(successor);
        hook.ping(address(token));
        module.cancelRaise(id);
        module.lowerRate(id, 200);
        vm.stopPrank();
        assertEq(hook.poolInfo(id).creator, successor);
    }

    function test_moduleImmutablePerPool() public {
        (, bytes32 first,) = _launch(address(0), 300);
        FixedRateModule nextModule = new FixedRateModule(address(hook));
        vm.prank(owner);
        factory.registerModule(address(nextModule));
        (, bytes32 second,) = _launch(address(0), 400);
        assertEq(hook.poolInfo(first).module, address(module));
        assertEq(hook.poolInfo(second).module, address(nextModule));
        vm.startPrank(creator);
        module.lowerRate(first, 200);
        nextModule.lowerRate(second, 300);
        vm.stopPrank();
        assertEq(module.feeBps(first, true, ""), 200);
        assertEq(nextModule.feeBps(second, true, ""), 300);
        vm.expectRevert(KeelV2Hook.OnlyModule.selector);
        vm.prank(address(nextModule));
        hook.creatorAction(first, creator);
    }

    function test_takeoverUnknownEarlyBoundaryAndSuccess() public {
        (KeelV2Token token, bytes32 id, PoolKey memory key) = _launch(address(0), 300);
        _mature();
        _buy(key, address(0), 0.01 ether);
        uint256 oldFees = hook.creatorFees(address(token), creator);
        TakeoverCaller takeover = new TakeoverCaller();
        vm.expectRevert(KeelV2Hook.NotTakeover.selector);
        takeover.take(hook, address(token), successor);
        vm.prank(owner);
        factory.setTakeoverContract(address(takeover));
        vm.expectRevert(KeelV2Hook.NotTakeover.selector);
        hook.setCreatorByTakeover(address(token), successor);
        uint256 last = hook.poolInfo(id).lastActive;
        vm.warp(last + 30 days);
        vm.expectRevert(KeelV2Hook.CreatorStillActive.selector);
        takeover.take(hook, address(token), successor);
        vm.warp(last + 30 days + 1);
        takeover.take(hook, address(token), successor);
        assertEq(hook.poolInfo(id).creator, successor);
        assertEq(hook.creatorFees(address(token), creator), oldFees);
        assertEq(hook.creatorFees(address(token), successor), 0);
        _buy(key, address(0), 0.01 ether);
        assertGt(hook.creatorFees(address(token), successor), 0);
        vm.prank(creator);
        hook.claimCreator(address(token), outsider);
        assertEq(outsider.balance, oldFees);
        assertEq(hook.poolInfo(id).lastActive, last + 30 days + 1);
        _assertSolvent(address(0));
    }

    function test_pingAndModuleActionDelayTakeover() public {
        (KeelV2Token token, bytes32 id,) = _launch(address(0), 300);
        TakeoverCaller takeover = new TakeoverCaller();
        vm.prank(owner);
        factory.setTakeoverContract(address(takeover));
        vm.warp(vm.getBlockTimestamp() + 30 days);
        vm.prank(creator);
        module.lowerRate(id, 200);
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.expectRevert(KeelV2Hook.CreatorStillActive.selector);
        takeover.take(hook, address(token), successor);
    }
}
