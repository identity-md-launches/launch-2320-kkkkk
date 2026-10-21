// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HeartTest} from "./support/HeartTest.sol";
import {PulseMath} from "../src/libraries/PulseMath.sol";
import {PulseRateModule} from "../src/PulseRateModule.sol";
import {RateModuleBase} from "../src/RateModuleBase.sol";
import {KeelV2Hook} from "../src/KeelV2Hook.sol";
import {KeelV2Token} from "../src/KeelV2Token.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

contract PulseMathHarness {
    function decay(uint256 value, uint256 elapsed) external pure returns (uint256) {
        return PulseMath.decay(value, elapsed);
    }

    function exp2Neg(uint256 frac) external pure returns (uint256) {
        return PulseMath.exp2Neg(frac);
    }
}

contract PulseTest is HeartTest {
    PulseMathHarness private math;

    function setUp() public override {
        super.setUp();
        math = new PulseMathHarness();
    }

    function test_decayExactHalfLivesAndCap() public view {
        assertEq(math.decay(1e18, 0), 1e18);
        assertEq(math.decay(1e18, 3600), 5e17);
        assertEq(math.decay(1e18, 7200), 25e16);
        assertEq(math.decay(7e18, 10 * 3600), 7e18 >> 10);
        assertEq(math.decay(1e18, 64 * 3600), 0);
        assertApproxEqRel(
            math.decay(type(uint128).max, 64 * 3600 - 1), uint256(type(uint128).max) >> 64, 1e15
        );
        assertEq(math.decay(type(uint128).max, type(uint256).max), 0);
        assertEq(math.decay(0, 5), 0);
        assertEq(math.exp2Neg(0), 1 << 64);
        assertEq(math.exp2Neg(0x8000), 13043817825332782212);
        assertApproxEqRel(math.decay(1e18, 1800), 707106781186547524, 1e13);
        assertApproxEqRel(math.decay(1e18, 60), 988514020000000000, 2e13);
        assertApproxEqRel(math.decay(1e18, 3599), 500096271849478000, 2e13);
    }

    function testFuzz_decayNeverRevertsAndIsMonotone(uint128 value, uint256 elapsed, uint256 more)
        public
        view
    {
        more = bound(more, 0, type(uint256).max - elapsed);
        uint256 first = math.decay(value, elapsed);
        uint256 later = math.decay(value, elapsed + more);
        assertLe(first, value);
        assertLe(later, first);
        if (elapsed >= 64 hours) assertEq(first, 0);
        if (elapsed == 0) assertEq(first, value);
    }

    function testFuzz_wholeHalfLivesAreExactShifts(uint128 value, uint8 halves) public view {
        halves = uint8(bound(halves, 0, 63));
        assertEq(math.decay(value, uint256(halves) * 3600), uint256(value) >> halves);
    }

    function test_pulseAccumulatesDecaysAndIgnoresSmallBuys() public {
        (, bytes32 id, PoolKey memory key) = _launchMature(address(0));
        assertEq(hook.pulseOf(id), 0);
        _buy(key, address(0), 0.01 ether);
        assertEq(hook.pulseOf(id), 1e18);
        _buy(key, address(0), MIN_ETH - 1);
        assertEq(hook.pulseOf(id), 1e18);
        _routerBuy(key, address(0), 0.01 ether, buyer);
        assertEq(hook.pulseOf(id), 2e18);
        vm.warp(vm.getBlockTimestamp() + 3600);
        assertEq(hook.pulseOf(id), 1e18);
        _buy(key, address(0), 0.01 ether);
        assertEq(hook.pulseOf(id), 2e18);
        (uint128 stored, uint64 updatedAt) = hook.pulseInfo(id);
        assertEq(stored, 2e18);
        assertEq(updatedAt, vm.getBlockTimestamp());
        vm.warp(vm.getBlockTimestamp() + 100 * 3600);
        assertEq(hook.pulseOf(id), 0);
        _buy(key, address(0), 0.01 ether);
        assertEq(hook.pulseOf(id), 1e18);
    }

    function test_pulseCountsEveryBuyWithoutHeart() public {
        (, bytes32 id, PoolKey memory key) = _launchMature(address(0));
        vm.mockCall(address(factory), abi.encodeCall(factory.heart, ()), abi.encode(address(0)));
        _buy(key, address(0), 1000);
        _buy(key, address(0), MIN_ETH - 1);
        assertEq(hook.pulseOf(id), 2e18);
        vm.clearMockedCalls();
    }

    function test_pulseSaturatesInsteadOfOverflowing() public {
        (, bytes32 id, PoolKey memory key) = _launchMature(address(0));
        _buy(key, address(0), 0.01 ether);
        uint256 now_ = vm.getBlockTimestamp();
        bytes32 slot = _pulseSlot(id, uint256(1e18) | (now_ << 128));
        vm.store(address(hook), slot, bytes32(uint256(type(uint128).max - 1) | (now_ << 128)));
        assertEq(hook.pulseOf(id), type(uint128).max - 1);
        _buy(key, address(0), 0.01 ether);
        assertEq(hook.pulseOf(id), type(uint128).max);
        _buy(key, address(0), 0.01 ether);
        assertEq(hook.pulseOf(id), type(uint128).max);
    }

    function _pulseSlot(bytes32 id, uint256 expected) private view returns (bytes32) {
        for (uint256 i; i < 64; ++i) {
            bytes32 slot = keccak256(abi.encode(id, i));
            if (uint256(vm.load(address(hook), slot)) == expected) return slot;
        }
        revert("pulse slot not found");
    }
}

contract PulseRateModuleTest is HeartTest {
    PulseRateModule private pulseModule;

    function setUp() public override {
        super.setUp();
        pulseModule = new PulseRateModule(address(hook));
        vm.prank(owner);
        factory.registerModule(address(pulseModule));
    }

    function _mockPulse(bytes32 id, uint256 value) private {
        vm.mockCall(address(hook), abi.encodeCall(hook.pulseOf, (id)), abi.encode(value));
    }

    function test_boundsAtZeroHotAndAbove() public {
        (, bytes32 id,) = _launch(address(0), 500);
        assertEq(pulseModule.HOT(), 6e18);
        _mockPulse(id, 0);
        assertEq(pulseModule.feeBps(id, true, ""), 100);
        _mockPulse(id, 3e18);
        assertEq(pulseModule.feeBps(id, false, ""), 300);
        _mockPulse(id, 6e18);
        assertEq(pulseModule.feeBps(id, true, ""), 500);
        _mockPulse(id, 60e18);
        assertEq(pulseModule.feeBps(id, true, ""), 500);
        _mockPulse(id, type(uint256).max);
        assertEq(pulseModule.feeBps(id, true, ""), 500);
        vm.clearMockedCalls();
        vm.prank(creator);
        pulseModule.lowerRate(id, 100);
        _mockPulse(id, 60e18);
        assertEq(pulseModule.feeBps(id, true, ""), 100);
        vm.clearMockedCalls();
        vm.expectRevert(RateModuleBase.UnknownPool.selector);
        pulseModule.feeBps(bytes32(uint256(1)), true, "");
    }

    function testFuzz_alwaysWithinRateBounds(uint16 rawRate, uint256 pulse) public {
        uint16 rate = uint16(bound(rawRate, 100, 500));
        (, bytes32 id,) = _launch(address(0), rate);
        _mockPulse(id, pulse);
        uint16 fee = pulseModule.feeBps(id, true, "");
        assertGe(fee, 100);
        assertLe(fee, rate);
        uint256 capped = pulse > 6e18 ? 6e18 : pulse;
        assertEq(fee, 100 + (uint256(rate) - 100) * capped / 6e18);
        vm.clearMockedCalls();
    }

    function test_liveFeeFollowsRealPulseAndCreatorControls() public {
        (KeelV2Token token, bytes32 id, PoolKey memory key) = _launch(address(0), 400);
        _mature();
        assertEq(pulseModule.feeBps(id, true, ""), 100);
        _buy(key, address(0), 0.01 ether);
        assertEq(hook.totalUnclaimed(address(0)), 0.0001 ether);
        assertEq(pulseModule.feeBps(id, true, ""), 150);
        for (uint256 i; i < 6; ++i) {
            _buy(key, address(0), 0.01 ether);
        }
        assertEq(pulseModule.feeBps(id, true, ""), 400);
        uint256 before = hook.totalUnclaimed(address(0));
        _buy(key, address(0), 0.01 ether);
        assertEq(hook.totalUnclaimed(address(0)) - before, 0.0004 ether);
        vm.startPrank(creator);
        pulseModule.scheduleRaise(id, 500);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        pulseModule.applyRaise(id);
        vm.stopPrank();
        assertLt(hook.pulseOf(id), 1e12);
        assertEq(pulseModule.feeBps(id, true, ""), 100);
        _buy(key, address(0), 0.01 ether);
        _sell(key, address(token), token.balanceOf(trader) / 2);
        assertEq(hook.poolInfo(id).module, address(pulseModule));
        vm.expectRevert(KeelV2Hook.NotCreator.selector);
        pulseModule.lowerRate(id, 100);
    }
}
