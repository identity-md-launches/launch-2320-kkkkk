// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HeartTest, BurningHeart, RevertingHeart} from "./support/HeartTest.sol";
import {KeelHeart} from "../src/KeelHeart.sol";
import {KeelV2Hook} from "../src/KeelV2Hook.sol";
import {KeelV2Factory} from "../src/KeelV2Factory.sol";
import {KeelV2Token} from "../src/KeelV2Token.sol";
import {QuoteTransfer} from "../src/libraries/QuoteTransfer.sol";
import {FixedRateModule} from "../src/FixedRateModule.sol";
import {Router} from "./support/Router.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

contract HeartTimerTest is HeartTest {
    function test_routerBuyStartsRoundAndRecordsBuy() public {
        (KeelV2Token token,, PoolKey memory key) = _launchMature(address(0));
        uint256 start = vm.getBlockTimestamp();
        vm.expectEmit(true, true, true, true, address(heart));
        emit KeelHeart.Beat(1, buyer, address(token), address(0), 0.01 ether, start + 300);
        _routerBuy(key, address(0), 0.01 ether, buyer);
        (uint256 round, uint256 deadline, address last, address lastToken) = heart.state();
        assertEq(round, 1);
        assertEq(deadline, start + 300);
        assertEq(last, buyer);
        assertEq(lastToken, address(token));
        assertEq(heart.lastTokens(), token.balanceOf(buyer));
        assertGt(heart.lastTokens(), 0);
    }

    function test_nonRouterAndSpoofedHookDataNeverCount() public {
        (,, PoolKey memory key) = _launchMature(address(0));
        _buy(key, address(0), 0.01 ether);
        assertEq(_deadline(), 0);
        _swapVia(spoofRouter, key, address(0), 0.01 ether, buyer, abi.encode(buyer));
        assertEq(_deadline(), 0);
        _swapVia(router, key, address(0), 0.01 ether, buyer, abi.encodePacked(buyer));
        assertEq(_deadline(), 0);
        _swapVia(router, key, address(0), 0.01 ether, buyer, abi.encode(buyer, uint256(1)));
        assertEq(_deadline(), 0);
        _routerBuy(key, address(0), 0.01 ether, buyer);
        assertEq(_deadline(), vm.getBlockTimestamp() + 300);
    }

    function test_belowMinBuyOrUnlistedThresholdIgnored() public {
        (,, PoolKey memory key) = _launchMature(address(0));
        _routerBuy(key, address(0), MIN_ETH - 1, buyer);
        assertEq(_deadline(), 0);
        (,, PoolKey memory daiKey) = _launchMature(address(dai));
        dai.mint(buyer, 100 ether);
        _routerBuy(daiKey, address(dai), 10 ether, buyer);
        assertEq(_deadline(), 0);
        _routerBuy(key, address(0), MIN_ETH, buyer);
        assertEq(_deadline(), vm.getBlockTimestamp() + 300);
    }

    function test_extensionAndCap() public {
        (,, PoolKey memory key) = _launchMature(address(0));
        uint256 start = vm.getBlockTimestamp();
        _routerBuy(key, address(0), 0.01 ether, buyer);
        _routerBuy(key, address(0), 0.01 ether, other);
        assertEq(_deadline(), start + 330);
        assertEq(_lastBuyer(), other);
        for (uint256 i; i < 20; ++i) {
            _routerBuy(key, address(0), 0.01 ether, buyer);
        }
        assertEq(_deadline(), start + 600);
        vm.warp(start + 100);
        _routerBuy(key, address(0), 0.01 ether, buyer);
        assertEq(_deadline(), start + 630);
        assertEq(_round(), 1);
    }

    function test_sellsNeverTouchTimer() public {
        (KeelV2Token token,, PoolKey memory key) = _launchMature(address(0));
        _routerBuy(key, address(0), 0.01 ether, buyer);
        uint256 deadline = _deadline();
        vm.warp(vm.getBlockTimestamp() + 50);
        _swapVia(router, key, address(token), token.balanceOf(buyer) / 2, buyer, abi.encode(buyer));
        assertEq(_deadline(), deadline);
        assertEq(_lastBuyer(), buyer);
        vm.warp(deadline + 1);
        _swapVia(router, key, address(token), token.balanceOf(buyer) / 2, buyer, abi.encode(buyer));
        assertEq(_deadline(), deadline);
        assertEq(_round(), 1);
    }

    function test_endRequiresExpiredRound() public {
        (,, PoolKey memory key) = _launchMature(address(0));
        vm.expectRevert(KeelHeart.NoRound.selector);
        heart.end();
        _routerBuy(key, address(0), 0.01 ether, buyer);
        vm.warp(_deadline() - 1);
        vm.expectRevert(KeelHeart.RoundRunning.selector);
        heart.end();
        vm.warp(_deadline());
        _nextBlock();
        vm.expectEmit(true, true, true, true, address(heart));
        emit KeelHeart.Flatline(1, buyer, true);
        heart.end();
        assertEq(_deadline(), 0);
        vm.expectRevert(KeelHeart.NoRound.selector);
        heart.end();
        _routerBuy(key, address(0), 0.01 ether, other);
        assertEq(_round(), 2);
    }

    function test_buyAfterDeadlineEndsInsideOnBuyAndStartsNext() public {
        (KeelV2Token token,, PoolKey memory key) = _launchMature(address(0));
        _routerBuy(key, address(0), 0.01 ether, buyer);
        vm.warp(_deadline() + 1000);
        _nextBlock();
        _routerBuy(key, address(0), 0.01 ether, other);
        (address winner, address resultToken, uint256 endBlock, bool eligible, bool claimed) = heart.result(1);
        assertEq(winner, buyer);
        assertEq(resultToken, address(token));
        assertEq(endBlock, vm.getBlockNumber());
        assertTrue(eligible);
        assertFalse(claimed);
        assertEq(_round(), 2);
        assertEq(_deadline(), vm.getBlockTimestamp() + 300);
        assertEq(_lastBuyer(), other);
    }

    function test_onlyHookCallsOnBuy() public {
        vm.expectRevert(KeelHeart.OnlyHook.selector);
        heart.onBuy(address(usdc), address(0), buyer, 1 ether, 1);
    }

    function test_revertingHeartNeverBreaksSwap() public {
        (, bytes32 id, PoolKey memory key) = _launchMature(address(0));
        vm.mockCallRevert(address(heart), abi.encodeWithSelector(KeelHeart.onBuy.selector), "down");
        vm.expectEmit(true, false, false, true, address(hook));
        emit KeelV2Hook.HeartCallFailed(id);
        _routerBuy(key, address(0), 0.01 ether, buyer);
        assertEq(_deadline(), 0);
        assertEq(hook.pulseOf(id), 1e18);
        vm.clearMockedCalls();
        _routerBuy(key, address(0), 0.01 ether, buyer);
        assertEq(_deadline(), vm.getBlockTimestamp() + 300);
    }

    function test_gasBurningAndRevertingHeartsBoundedByStipend() public {
        address[2] memory hearts = [address(new BurningHeart()), address(new RevertingHeart())];
        uint256[2] memory used;
        (KeelV2Factory savedFactory, KeelV2Hook savedHook, Router savedRouter) = (factory, hook, router);
        for (uint256 i; i < hearts.length; ++i) {
            factory = new KeelV2Factory(manager, owner, team);
            hook = _deployHook(factory);
            factory.initialize(hook, address(new FixedRateModule(address(hook))));
            router = new Router(manager);
            vm.startPrank(owner);
            factory.setSigner(signer);
            factory.configureQuote(address(0), true, -600000, 600000, false, false);
            factory.setRouter(address(router));
            factory.setHeart(hearts[i]);
            vm.stopPrank();
            (KeelV2Token token, bytes32 id, PoolKey memory key) = _launch(address(0), 300);
            _mature();
            uint256 before = gasleft();
            vm.expectEmit(true, false, false, true, address(hook));
            emit KeelV2Hook.HeartCallFailed(id);
            _routerBuy(key, address(0), 0.01 ether, buyer);
            used[i] = before - gasleft();
            assertGt(token.balanceOf(buyer), 0);
            assertEq(hook.pulseOf(id), 1e18);
        }
        (factory, hook, router) = (savedFactory, savedHook, savedRouter);
        // Burning every unit of the stipend costs at most the stipend more than an instant revert.
        assertGt(used[0], used[1]);
        assertLt(used[0] - used[1], 215_000, "heart consumed more than the stipend");
        assertLt(used[1], 600_000);
    }

    function _deployHook(KeelV2Factory f) private returns (KeelV2Hook) {
        bytes32 hash =
            keccak256(abi.encodePacked(type(KeelV2Hook).creationCode, abi.encode(manager, address(f))));
        bytes32 salt;
        for (uint256 i;; ++i) {
            salt = bytes32(i);
            address predicted = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, hash))))
            );
            if (uint160(predicted) & ((1 << 14) - 1) == hook.PERMISSION_FLAGS()) break;
        }
        return new KeelV2Hook{salt: salt}(manager, address(f));
    }
}

contract HeartWinnerTest is HeartTest {
    KeelV2Token private token;
    PoolKey private key;

    function setUp() public override {
        super.setUp();
        (token,, key) = _launchMature(address(0));
        vm.prank(outsider);
        heart.fund{value: 1 ether}(address(0), 1 ether);
    }

    function _start() private {
        _nextBlock();
        _routerBuy(key, address(0), 0.01 ether, buyer);
        _nextBlock();
    }

    function _assertResult(bool eligible) private view {
        (address winner,,, bool wasEligible,) = heart.result(1);
        assertEq(winner, buyer);
        assertEq(wasEligible, eligible);
        assertEq(heart.prizeOf(1, address(0)), eligible ? 0.7 ether : 0);
        assertEq(heart.potOf(address(0)), eligible ? 0.3 ether : 1 ether);
    }

    function test_holderWins() public {
        _start();
        _endRound();
        _assertResult(true);
    }

    function test_soldPartBeforeEndLoses() public {
        _start();
        _swapVia(router, key, address(token), 1, buyer, "");
        _endRound();
        _assertResult(false);
    }

    function test_soldAndBoughtBackBeforeEndWins() public {
        _start();
        uint256 held = heart.lastTokens();
        _swapVia(router, key, address(token), token.balanceOf(buyer), buyer, "");
        _nextBlock();
        _routerBuy(key, address(0), 0.02 ether, other);
        _swapVia(router, key, address(0), 0.03 ether, buyer, "");
        assertGe(token.balanceOf(buyer), held);
        _endRound();
        (address winner,,, bool eligible,) = heart.result(1);
        assertEq(winner, other);
        assertTrue(eligible);
        _start();
        _swapVia(router, key, address(token), token.balanceOf(buyer), buyer, "");
        _nextBlock();
        _swapVia(router, key, address(0), 0.05 ether, buyer, "");
        assertGe(token.balanceOf(buyer), heart.lastTokens());
        _endRound();
        (winner,,, eligible,) = heart.result(2);
        assertEq(winner, buyer);
        assertTrue(eligible);
    }

    function test_receivedByTransferCounts() public {
        _start();
        _swapVia(router, key, address(token), token.balanceOf(buyer), buyer, "");
        _swapVia(router, key, address(0), 0.05 ether, other, "");
        uint256 held = token.balanceOf(other);
        vm.prank(other);
        token.transfer(buyer, held);
        assertGe(token.balanceOf(buyer), heart.lastTokens());
        _endRound();
        _assertResult(true);
    }

    function test_movesInsideEndBlockDoNotCount() public {
        _start();
        vm.warp(_deadline());
        _nextBlock();
        uint256 held = token.balanceOf(buyer);
        vm.prank(buyer);
        token.transfer(other, held);
        heart.end();
        _assertResult(true);
        uint256 returned = token.balanceOf(other);
        vm.prank(other);
        token.transfer(buyer, returned);
        _start();
        _swapVia(router, key, address(token), token.balanceOf(buyer), buyer, "");
        vm.warp(_deadline());
        _nextBlock();
        _swapVia(router, key, address(0), 0.05 ether, buyer, "");
        assertGe(token.balanceOf(buyer), heart.lastTokens());
        heart.end();
        (address winner,,, bool eligible,) = heart.result(2);
        assertEq(winner, buyer);
        assertFalse(eligible);
        assertEq(heart.potOf(address(0)), 0.3 ether);
    }

    function test_endLongAfterDeadlineStillChecksPreviousBlock() public {
        _start();
        vm.warp(_deadline() + 30 days);
        vm.roll(vm.getBlockNumber() + 200_000);
        heart.end();
        _assertResult(true);
        (,, uint256 endBlock,,) = heart.result(1);
        assertEq(endBlock, vm.getBlockNumber());
    }
}

contract HeartPotTest is HeartTest {
    KeelV2Token private token;
    PoolKey private key;

    function setUp() public override {
        super.setUp();
        (token,, key) = _launchMature(address(0));
    }

    function _winRound(address who) private {
        _nextBlock();
        _routerBuy(key, address(0), 0.01 ether, who);
        _endRound();
    }

    function test_fundingRules() public {
        vm.startPrank(outsider);
        vm.expectRevert(KeelHeart.QuoteNotListed.selector);
        heart.fund(address(dai), 1 ether);
        vm.expectRevert(KeelHeart.InvalidAmount.selector);
        heart.fund{value: 1 ether}(address(0), 2 ether);
        vm.expectRevert(KeelHeart.InvalidAmount.selector);
        heart.fund(address(0), 0);
        vm.expectRevert(KeelHeart.InvalidAmount.selector);
        heart.fund{value: 1}(address(usdc), 1e6);
        vm.stopPrank();
        usdc.mint(outsider, 10e6);
        vm.startPrank(outsider);
        usdc.approve(address(heart), 10e6);
        usdc.setTaxed(true);
        vm.expectRevert(QuoteTransfer.NonStandardQuote.selector);
        heart.fund(address(usdc), 10e6);
        usdc.setTaxed(false);
        vm.expectEmit(true, true, true, true, address(heart));
        emit KeelHeart.Funded(0, address(usdc), outsider, 10e6);
        heart.fund(address(usdc), 10e6);
        heart.fund{value: 2 ether}(address(0), 2 ether);
        vm.stopPrank();
        assertEq(heart.potOf(address(usdc)), 10e6);
        assertEq(heart.potOf(address(0)), 2 ether);
        assertEq(heart.liability(address(0)), 2 ether);
        assertEq(heart.liability(address(usdc)), 10e6);
        assertEq(heart.anchorCount(address(0)), 1);
    }

    function test_splitClaimAndCarryAcrossRounds() public {
        usdc.mint(outsider, 100e6);
        vm.startPrank(outsider);
        usdc.approve(address(heart), 100e6);
        heart.fund(address(usdc), 100e6);
        heart.fund{value: 1 ether}(address(0), 1 ether);
        vm.stopPrank();
        _winRound(buyer);
        assertEq(heart.prizeOf(1, address(0)), 0.7 ether);
        assertEq(heart.prizeOf(1, address(usdc)), 70e6);
        assertEq(heart.potOf(address(0)), 0.3 ether);
        assertEq(heart.potOf(address(usdc)), 30e6);
        vm.prank(outsider);
        heart.fund{value: 0.7 ether}(address(0), 0.7 ether);
        assertEq(heart.potOf(address(0)), 1 ether);
        assertEq(heart.anchorCount(address(0)), 2);
        _winRound(other);
        assertEq(heart.prizeOf(2, address(0)), 0.7 ether);
        assertEq(heart.prizeOf(2, address(usdc)), 21e6);
        assertEq(heart.potOf(address(usdc)), 9e6);
        assertEq(heart.prizeOf(1, address(0)), 0.7 ether);
        vm.expectRevert(KeelHeart.NotWinner.selector);
        heart.claim(1, outsider);
        vm.expectRevert(KeelHeart.NotWinner.selector);
        vm.prank(buyer);
        heart.claim(2, outsider);
        vm.expectRevert(KeelHeart.NotWinner.selector);
        vm.prank(buyer);
        heart.claim(3, outsider);
        vm.startPrank(buyer);
        vm.expectRevert(KeelHeart.InvalidAddress.selector);
        heart.claim(1, address(0));
        vm.expectEmit(true, true, true, true, address(heart));
        emit KeelHeart.Claimed(1, buyer, successor);
        heart.claim(1, successor);
        vm.expectRevert(KeelHeart.AlreadyClaimed.selector);
        heart.claim(1, successor);
        vm.stopPrank();
        assertEq(successor.balance, 0.7 ether);
        assertEq(usdc.balanceOf(successor), 70e6);
        (,,,, bool claimed) = heart.result(1);
        assertTrue(claimed);
        assertEq(heart.liability(address(0)), 1 ether);
        assertEq(heart.liability(address(usdc)), 30e6);
        vm.prank(other);
        heart.claim(2, other);
        assertEq(other.balance, 1000 ether - 0.01 ether + 0.7 ether);
        assertEq(usdc.balanceOf(other), 1_000_000e6 + 21e6);
        assertEq(address(heart).balance, 0.3 ether);
        assertEq(usdc.balanceOf(address(heart)), 9e6);
        assertEq(heart.liability(address(0)), 0.3 ether);
        assertEq(heart.potOf(address(0)), 0.3 ether);
        assertEq(heart.eligibleRounds(), 2);
    }

    function test_ineligibleRoundCarriesWholePotAndCannotClaim() public {
        vm.prank(outsider);
        heart.fund{value: 1 ether}(address(0), 1 ether);
        _nextBlock();
        _routerBuy(key, address(0), 0.01 ether, buyer);
        _swapVia(router, key, address(token), 1, buyer, "");
        _endRound();
        assertEq(heart.potOf(address(0)), 1 ether);
        assertEq(heart.prizeOf(1, address(0)), 0);
        vm.expectRevert(KeelHeart.NotEligible.selector);
        vm.prank(buyer);
        heart.claim(1, buyer);
        _winRound(other);
        assertEq(heart.prizeOf(2, address(0)), 0.7 ether);
        assertEq(heart.eligibleRounds(), 1);
    }

    function test_manyEmptyRoundsThenFunding() public {
        for (uint256 i; i < 5; ++i) {
            _winRound(buyer);
        }
        vm.prank(outsider);
        heart.fund{value: 1 ether}(address(0), 1 ether);
        assertEq(heart.prizeOf(5, address(0)), 0);
        _winRound(other);
        assertEq(heart.prizeOf(6, address(0)), 0.7 ether);
        vm.prank(buyer);
        heart.claim(3, buyer);
        assertEq(buyer.balance, 1000 ether - 5 * 0.01 ether);
    }

    function test_rejectedRecipientAndTaxedPayoutRollBack() public {
        vm.prank(outsider);
        heart.fund{value: 1 ether}(address(0), 1 ether);
        usdc.mint(outsider, 100e6);
        vm.startPrank(outsider);
        usdc.approve(address(heart), 100e6);
        heart.fund(address(usdc), 100e6);
        vm.stopPrank();
        _winRound(buyer);
        vm.startPrank(buyer);
        vm.expectRevert(QuoteTransfer.TransferFailed.selector);
        heart.claim(1, address(hook));
        usdc.setTaxFrom(address(heart));
        usdc.setTaxed(true);
        vm.expectRevert(QuoteTransfer.NonStandardQuote.selector);
        heart.claim(1, successor);
        usdc.setTaxed(false);
        usdc.rebaseDown(address(heart), 1);
        vm.expectRevert(KeelHeart.Insolvent.selector);
        heart.claim(1, successor);
        usdc.mint(address(heart), 1);
        heart.claim(1, successor);
        vm.stopPrank();
        assertEq(usdc.balanceOf(successor), 70e6);
    }

    function test_ownerPowersAndLimits() public {
        vm.expectRevert(KeelHeart.NotOwner.selector);
        heart.setMinBuy(address(0), 1);
        vm.expectRevert(KeelHeart.NotOwner.selector);
        heart.addQuote(address(dai));
        vm.expectRevert(KeelHeart.NotOwner.selector);
        heart.transferOwnership(successor);
        vm.startPrank(owner);
        vm.expectRevert(KeelHeart.AlreadyListed.selector);
        heart.addQuote(address(0));
        for (uint256 i = 2; i < 16; ++i) {
            heart.addQuote(address(uint160(0xF000 + i)));
        }
        vm.expectRevert(KeelHeart.TooManyQuotes.selector);
        heart.addQuote(address(dai));
        assertEq(heart.quoteList().length, 16);
        vm.expectRevert(KeelHeart.InvalidAddress.selector);
        heart.transferOwnership(address(0));
        heart.transferOwnership(successor);
        vm.stopPrank();
        assertEq(heart.owner(), owner);
        vm.expectRevert(KeelHeart.NotPendingOwner.selector);
        heart.acceptOwnership();
        vm.prank(successor);
        heart.acceptOwnership();
        assertEq(heart.owner(), successor);
        vm.prank(successor);
        heart.setMinBuy(address(0), 5);
        assertEq(heart.minBuy(address(0)), 5);
        vm.expectRevert(KeelHeart.InvalidAddress.selector);
        new KeelHeart(address(0), owner);
        vm.expectRevert(KeelHeart.InvalidAddress.selector);
        new KeelHeart(address(hook), address(0));
    }

    function test_onBuyGasOnEveryPath() public {
        vm.prank(outsider);
        heart.fund{value: 1 ether}(address(0), 1 ether);
        uint256 limit = 120_000;
        vm.startPrank(address(hook));
        assertLe(_measure(address(token), address(0), buyer, MIN_ETH - 1, 5), limit, "ignored");
        assertLe(_measure(address(token), address(dai), buyer, 1 ether, 5), limit, "unlisted");
        assertLe(_measure(address(token), address(0), buyer, 0.01 ether, 5), limit, "round start");
        assertLe(_measure(address(token), address(0), other, 0.01 ether, 7), limit, "extension");
        assertLe(_measure(address(token), address(0), buyer, 0.01 ether, 1e27), limit, "extension");
        vm.stopPrank();
        vm.warp(_deadline() + 1);
        // Give the next winner a long checkpoint history so the holding check is at its most expensive.
        vm.deal(other, 2000 ether);
        for (uint256 i; i < 400; ++i) {
            vm.roll(vm.getBlockNumber() + 1);
            _swapVia(router, key, address(0), 0.001 ether, other, "");
        }
        vm.roll(vm.getBlockNumber() + 1);
        vm.startPrank(address(hook));
        assertLe(_measure(address(token), address(0), buyer, 0.01 ether, 5), limit, "ineligible end");
        (,,, bool eligible,) = heart.result(1);
        assertFalse(eligible);
        assertLe(_measure(address(token), address(0), other, 0.01 ether, 1), limit, "extension");
        vm.warp(_deadline() + 1);
        vm.roll(vm.getBlockNumber() + 1);
        assertLe(_measure(address(token), address(0), buyer, 0.01 ether, 3), limit, "eligible end");
        vm.stopPrank();
        (,,, eligible,) = heart.result(2);
        assertTrue(eligible);
        assertEq(_round(), 3);
        assertEq(token.checkpointCount(other), 400);
    }

    function _measure(address t, address quote, address who, uint256 gross, uint256 tokensOut)
        private
        returns (uint256 used)
    {
        uint256 before = gasleft();
        heart.onBuy(t, quote, who, gross, tokensOut);
        used = before - gasleft();
        emit log_named_uint("onBuy gas", used);
    }
}
