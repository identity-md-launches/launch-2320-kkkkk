// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccrualSensitiveModule, InvalidRateModule} from "./support/TestModules.sol";
import {KeelTest} from "./support/KeelTest.sol";
import {KeelV2Token} from "../src/KeelV2Token.sol";
import {KeelV2Hook} from "../src/KeelV2Hook.sol";
import {QuoteTransfer} from "../src/libraries/QuoteTransfer.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

contract ClaimReceiver {
    KeelV2Hook public immutable hook;
    bool public attempted;
    bool public reentered;
    bool public reject;

    constructor(KeelV2Hook hook_) {
        hook = hook_;
    }

    function setReject(bool value) external {
        reject = value;
    }

    receive() external payable {
        require(!reject, "receiver rejected");
        attempted = true;
        (reentered,) = address(hook).call(abi.encodeCall(hook.claimTeam, (address(0), address(this))));
    }
}

contract FeesTest is KeelTest {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    function test_buySellFeeSplitForAllDecimals() public {
        address[4] memory quotes = [address(0), address(usdc), address(btc), address(dai)];
        uint256[4] memory amounts =
            [uint256(0.01 ether + 7), uint256(1e6 + 7), uint256(1e8 + 7), uint256(1 ether + 7)];
        for (uint256 i; i < quotes.length; ++i) {
            (KeelV2Token token, bytes32 id, PoolKey memory key) = _launch(quotes[i], 333);
            _mature();
            _buy(key, quotes[i], amounts[i]);
            uint256 fee = (amounts[i] * 333 + 9999) / 10000;
            uint256 creatorFee = fee * 80 / 100;
            assertEq(hook.creatorFees(address(token), creator), creatorFee);
            assertEq(hook.teamFees(quotes[i], team), fee - creatorFee);
            uint256 managerBefore = QuoteTransfer.balance(quotes[i], address(manager));
            uint256 traderBefore = QuoteTransfer.balance(quotes[i], trader);
            _sell(key, address(token), token.balanceOf(trader) / 2);
            uint256 grossOutput = managerBefore - QuoteTransfer.balance(quotes[i], address(manager));
            uint256 sellFee = (grossOutput * 333 + 9999) / 10000;
            uint256 sellCreator = sellFee * 80 / 100;
            assertEq(QuoteTransfer.balance(quotes[i], trader) - traderBefore, grossOutput - sellFee);
            assertEq(hook.creatorEarned(id), creatorFee + sellCreator);
            assertEq(hook.teamEarned(id), fee + sellFee - creatorFee - sellCreator);
            assertEq(hook.totalUnclaimed(quotes[i]), fee + sellFee);
            _assertSolvent(quotes[i]);
        }
    }

    function test_scheduleAtSeveralTimesAndExtraAllToTeam() public {
        (KeelV2Token token, bytes32 id, PoolKey memory key) = _launch(address(0), 300);
        uint256 start = vm.getBlockTimestamp();
        uint256[5] memory times = [uint256(0), 30, 60, 119, 120];
        uint16[5] memory expected = [uint16(9900), 7500, 5100, 380, 300];
        uint256 amount = 0.001 ether + 1;
        uint256 cumulativeCreator;
        uint256 cumulativeFee;
        for (uint256 i; i < times.length; ++i) {
            vm.warp(start + times[i]);
            (uint16 base, uint16 effective) = hook.rates(id, true, "");
            assertEq(base, 300);
            assertEq(effective, expected[i]);
            _buy(key, address(0), amount);
            cumulativeCreator += ((amount * 300 + 9999) / 10000) * 80 / 100;
            cumulativeFee += (amount * expected[i] + 9999) / 10000;
            assertEq(hook.creatorFees(address(token), creator), cumulativeCreator);
            assertEq(hook.teamFees(address(0), team), cumulativeFee - cumulativeCreator);
        }
    }

    function test_lowerDuringScheduleDoesNotRestartClock() public {
        (KeelV2Token token, bytes32 id, PoolKey memory key) = _launch(address(0), 300);
        uint256 start = vm.getBlockTimestamp();
        vm.warp(start + 60);
        vm.prank(creator);
        module.lowerRate(id, 100);
        (uint16 base, uint16 rate) = hook.rates(id, true, "");
        assertEq(base, 100);
        assertEq(rate, 5100);
        assertEq(hook.poolInfo(id).launchedAt, start);
        _buy(key, address(0), 0.01 ether);
        assertEq(hook.creatorFees(address(token), creator), 0.00008 ether);
        assertEq(hook.teamFees(address(0), team), 0.00502 ether);
        vm.warp(start + 119);
        (, rate) = hook.rates(id, true, "");
        assertEq(rate, 380);
        vm.warp(start + 120);
        (, rate) = hook.rates(id, true, "");
        assertEq(rate, 100);
    }

    function test_scheduledRateRoundsUp() public {
        (, bytes32 id,) = _launch(address(0), 333);
        vm.warp(vm.getBlockTimestamp() + 37);
        (, uint16 rate) = hook.rates(id, true, "");
        assertEq(rate, 333 + (uint256(9900 - 333) * 83 + 119) / 120);
    }

    function test_raiseChangesSwapRateAfterExplicitApplication() public {
        (, bytes32 id, PoolKey memory key) = _launch(address(0), 100);
        vm.prank(creator);
        module.scheduleRaise(id, 200);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        (uint16 base,) = hook.rates(id, true, "");
        assertEq(base, 100);
        vm.prank(creator);
        module.applyRaise(id);
        _buy(key, address(0), 0.01 ether);
        assertEq(hook.totalUnclaimed(address(0)), 0.0002 ether);
    }

    function test_noCreatorOwnerOrTeamExemption() public {
        (,, PoolKey memory key) = _launch(address(0), 300);
        _mature();
        address[3] memory actors = [creator, owner, team];
        for (uint256 i; i < actors.length; ++i) {
            vm.deal(actors[i], 1 ether);
            _swap(key, address(0), 0.01 ether, actors[i]);
        }
        assertEq(hook.totalUnclaimed(address(0)), 0.0009 ether);
    }

    function test_exactOutputAndTinyBuyRevert() public {
        (,, PoolKey memory key) = _launch(address(0), 300);
        bool zeroForOne = Currency.unwrap(key.currency0) == address(0);
        SwapParams memory params =
            SwapParams(zeroForOne, 1, zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1);
        vm.startPrank(trader);
        vm.expectRevert();
        router.swap{value: 100}(key, params, 100, trader);
        params.amountSpecified = -1;
        vm.expectRevert();
        router.swap{value: 1}(key, params, 1, trader);
        vm.stopPrank();
        assertEq(hook.totalUnclaimed(address(0)), 0);
    }

    function test_partialBuyRevertsWithoutAccruingFee() public {
        (, bytes32 id, PoolKey memory key) = _launch(address(0), 300);
        _mature();
        (uint160 price,,,) = manager.getSlot0(PoolId.wrap(id));
        bool zeroForOne = Currency.unwrap(key.currency0) == address(0);
        SwapParams memory params =
            SwapParams(zeroForOne, -int256(0.1 ether), zeroForOne ? price - 1 : price + 1);
        vm.startPrank(trader);
        vm.expectRevert();
        router.swap{value: 0.1 ether}(key, params, 0.1 ether, trader);
        vm.stopPrank();
        assertEq(hook.totalUnclaimed(address(0)), 0);
    }

    function test_creatorAndTeamClaimsToContractsReentrancyAndFailure() public {
        (KeelV2Token token, bytes32 id, PoolKey memory key) = _launch(address(0), 300);
        _mature();
        _buy(key, address(0), 0.01 ether);
        ClaimReceiver receiver = new ClaimReceiver(hook);
        receiver.setReject(true);
        uint256 credit = hook.creatorFees(address(token), creator);
        vm.startPrank(creator);
        vm.expectRevert(QuoteTransfer.TransferFailed.selector);
        hook.claimCreator(address(token), address(receiver));
        vm.stopPrank();
        assertEq(hook.creatorFees(address(token), creator), credit);
        receiver.setReject(false);
        vm.warp(vm.getBlockTimestamp() + 10);
        vm.prank(creator);
        hook.claimCreator(address(token), address(receiver));
        assertEq(address(receiver).balance, credit);
        assertTrue(receiver.attempted());
        assertFalse(receiver.reentered());
        assertEq(hook.poolInfo(id).lastActive, vm.getBlockTimestamp());
        vm.prank(team);
        hook.claimTeam(address(0), address(receiver));
        assertEq(address(receiver).balance, 0.0003 ether);
        assertEq(hook.totalUnclaimed(address(0)), 0);
        assertEq(address(hook).balance, 0);
        vm.expectRevert(KeelV2Hook.NoFees.selector);
        vm.prank(creator);
        hook.claimCreator(address(token), creator);
    }

    function test_erc20ClaimsAndInvalidRecipients() public {
        (KeelV2Token token,, PoolKey memory key) = _launch(address(usdc), 300);
        _mature();
        _buy(key, address(usdc), 1e6 + 1);
        uint256 creatorCredit = hook.creatorFees(address(token), creator);
        uint256 teamCredit = hook.teamFees(address(usdc), team);
        vm.startPrank(creator);
        vm.expectRevert(KeelV2Hook.InvalidAddress.selector);
        hook.claimCreator(address(token), address(0));
        vm.expectRevert(KeelV2Hook.InvalidAddress.selector);
        hook.claimCreator(address(token), address(hook));
        hook.claimCreator(address(token), outsider);
        vm.stopPrank();
        vm.prank(team);
        hook.claimTeam(address(usdc), outsider);
        assertEq(usdc.balanceOf(outsider), creatorCredit + teamCredit);
        assertEq(hook.totalUnclaimed(address(usdc)), 0);
    }

    function test_teamRecipientChangePreservesAccruedOwnership() public {
        (,, PoolKey memory key) = _launch(address(0), 300);
        _mature();
        _buy(key, address(0), 0.01 ether);
        uint256 oldCredit = hook.teamFees(address(0), team);
        vm.prank(owner);
        factory.setTeamRecipient(successor);
        assertEq(hook.teamFees(address(0), team), oldCredit);
        assertEq(hook.teamFees(address(0), successor), 0);
        _buy(key, address(0), 0.01 ether);
        assertEq(hook.teamFees(address(0), successor), oldCredit);
        vm.prank(team);
        hook.claimTeam(address(0), outsider);
        vm.prank(successor);
        hook.claimTeam(address(0), outsider);
        assertEq(outsider.balance, oldCredit * 2);
        _assertSolvent(address(0));
    }

    function test_creatorTransferPreservesOldCreditAndActivity() public {
        (KeelV2Token token, bytes32 id, PoolKey memory key) = _launch(address(0), 300);
        _mature();
        _buy(key, address(0), 0.01 ether);
        uint256 oldCredit = hook.creatorFees(address(token), creator);
        vm.prank(creator);
        hook.transferCreator(address(token), successor);
        uint256 changedAt = hook.poolInfo(id).lastActive;
        vm.warp(vm.getBlockTimestamp() + 100);
        vm.prank(creator);
        hook.claimCreator(address(token), outsider);
        assertEq(hook.poolInfo(id).lastActive, changedAt);
        assertEq(outsider.balance, oldCredit);
        _buy(key, address(0), 0.01 ether);
        assertEq(hook.creatorFees(address(token), successor), oldCredit);
    }

    function testFuzz_roundingConserves(uint128 amount, uint16 rawBase, uint16 rawEffective) public view {
        uint16 base = uint16(bound(rawBase, 100, 500));
        uint16 effective = uint16(bound(rawEffective, base, 9900));
        (uint256 total, uint256 creatorAmount) = hook.splitFee(amount, base, effective);
        uint256 expectedTotal = (uint256(amount) * effective + 9999) / 10000;
        uint256 baseFee = (uint256(amount) * base + 9999) / 10000;
        assertEq(total, expectedTotal);
        assertEq(creatorAmount, baseFee * 80 / 100);
        assertLe(creatorAmount, total);
        assertLe(total, amount);
        uint256 teamAmount = total - creatorAmount;
        assertEq(creatorAmount + teamAmount, total);
    }

    function testFuzz_balanceInvariant(uint96[6] memory values, uint8 rawQuote, uint16 rawRate) public {
        uint8 which = uint8(bound(rawQuote, 0, 3));
        address quote =
            which == 0 ? address(0) : which == 1 ? address(usdc) : which == 2 ? address(btc) : address(dai);
        uint256 unit = which == 1 ? 1e6 : which == 2 ? 1e8 : 1e18;
        (KeelV2Token token,, PoolKey memory key) = _launch(quote, uint16(bound(rawRate, 100, 500)));
        for (uint256 i; i < values.length; ++i) {
            vm.warp(vm.getBlockTimestamp() + values[i] % 61);
            _buy(key, quote, bound(values[i], unit / 1000, unit / 100));
            _assertSolvent(quote);
            if (i % 2 == 1) {
                uint256 balance = token.balanceOf(trader);
                _sell(key, address(token), balance / 2);
                _assertSolvent(quote);
            }
            if (i % 3 == 2) {
                if (hook.creatorFees(address(token), creator) != 0) {
                    vm.prank(creator);
                    hook.claimCreator(address(token), creator);
                }
                if (hook.teamFees(quote, team) != 0) {
                    vm.prank(team);
                    hook.claimTeam(quote, team);
                }
                _assertSolvent(quote);
            }
            assertEq(
                hook.totalUnclaimed(quote),
                hook.creatorFees(address(token), creator) + hook.teamFees(quote, team)
            );
            assertEq(token.totalSupply(), 1e27);
        }
    }

    function test_buyUsesSingleRateSnapshot() public {
        AccrualSensitiveModule nextModule = new AccrualSensitiveModule(address(hook));
        vm.prank(owner);
        factory.registerModule(address(nextModule));
        (,, PoolKey memory key) = _launch(address(0), 100);
        _mature();
        _buy(key, address(0), 0.01 ether);
        assertEq(hook.totalUnclaimed(address(0)), 0.0001 ether);
        _buy(key, address(0), 0.01 ether);
        assertEq(hook.totalUnclaimed(address(0)), 0.0003 ether);
    }

    function test_invalidModuleRateCannotCollectFees() public {
        InvalidRateModule badModule = new InvalidRateModule(address(hook));
        vm.prank(owner);
        factory.registerModule(address(badModule));
        (,, PoolKey memory key) = _launch(address(0), 100);
        _mature();
        bool zeroForOne = Currency.unwrap(key.currency0) == address(0);
        SwapParams memory params = SwapParams(
            zeroForOne,
            -int256(0.01 ether),
            zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        );
        vm.startPrank(trader);
        vm.expectRevert();
        router.swap{value: 0.01 ether}(key, params, 0.01 ether, trader);
        vm.stopPrank();
        assertEq(hook.totalUnclaimed(address(0)), 0);
    }

    function test_taxedReceiptRollsBackSwapAndFeeCredits() public {
        (KeelV2Token token,, PoolKey memory key) = _launch(address(usdc), 300);
        _mature();
        usdc.setTaxFrom(address(manager));
        usdc.setTaxed(true);
        bool zeroForOne = Currency.unwrap(key.currency0) == address(usdc);
        SwapParams memory params = SwapParams(
            zeroForOne, -int256(1e6), zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        );
        vm.startPrank(trader);
        usdc.approve(address(router), 1e6);
        vm.expectRevert();
        router.swap(key, params, 1e6, trader);
        vm.stopPrank();
        assertEq(hook.totalUnclaimed(address(usdc)), 0);
        assertEq(usdc.balanceOf(address(hook)), 0);
        assertEq(token.balanceOf(trader), 0);
    }

    function test_taxedOrFailedPayoutPreservesCredit() public {
        (KeelV2Token token,, PoolKey memory key) = _launch(address(usdc), 300);
        _mature();
        _buy(key, address(usdc), 1e6);
        uint256 credit = hook.creatorFees(address(token), creator);
        usdc.setTaxFrom(address(hook));
        usdc.setTaxed(true);
        vm.expectRevert(QuoteTransfer.NonStandardQuote.selector);
        vm.prank(creator);
        hook.claimCreator(address(token), outsider);
        assertEq(hook.creatorFees(address(token), creator), credit);
        usdc.setTaxed(false);
        usdc.setFailTransfers(true);
        vm.expectRevert(QuoteTransfer.TransferFailed.selector);
        vm.prank(creator);
        hook.claimCreator(address(token), outsider);
        assertEq(hook.creatorFees(address(token), creator), credit);
        usdc.setFailTransfers(false);
        vm.prank(creator);
        hook.claimCreator(address(token), outsider);
        assertEq(usdc.balanceOf(outsider), credit);
        _assertSolvent(address(usdc));
    }

    function test_negativeRebasePreventsPreferentialClaim() public {
        (KeelV2Token token,, PoolKey memory key) = _launch(address(usdc), 300);
        _mature();
        _buy(key, address(usdc), 1e6);
        uint256 credit = hook.creatorFees(address(token), creator);
        usdc.rebaseDown(address(hook), 1);
        vm.expectRevert(KeelV2Hook.InsolventQuote.selector);
        vm.prank(creator);
        hook.claimCreator(address(token), outsider);
        assertEq(hook.creatorFees(address(token), creator), credit);
        // Rebase assets are prohibited; this proves fail-closed handling if an attested asset changes.
        usdc.mint(address(hook), 1);
        _assertSolvent(address(usdc));
    }

    function test_multiplePoolsSameQuoteAggregateClaims() public {
        (KeelV2Token first, bytes32 firstId, PoolKey memory key1) = _launch(address(0), 100);
        (KeelV2Token second, bytes32 secondId, PoolKey memory key2) = _launch(address(0), 500);
        _mature();
        _buy(key1, address(0), 0.01 ether);
        _buy(key2, address(0), 0.01 ether);
        assertEq(hook.creatorEarned(firstId), 0.00008 ether);
        assertEq(hook.creatorEarned(secondId), 0.0004 ether);
        assertEq(hook.teamFees(address(0), team), 0.00012 ether);
        assertEq(hook.totalUnclaimed(address(0)), 0.0006 ether);
        vm.prank(team);
        hook.claimTeam(address(0), outsider);
        vm.startPrank(creator);
        hook.claimCreator(address(first), outsider);
        hook.claimCreator(address(second), outsider);
        vm.stopPrank();
        assertEq(outsider.balance, 0.0006 ether);
        _assertSolvent(address(0));
    }

    function test_reentrancyCannotClaimAnotherLiveCredit() public {
        ClaimReceiver receiver = new ClaimReceiver(hook);
        vm.prank(owner);
        factory.setTeamRecipient(address(receiver));
        (KeelV2Token token,, PoolKey memory key) = _launch(address(0), 300);
        _mature();
        _buy(key, address(0), 0.01 ether);
        uint256 creatorCredit = hook.creatorFees(address(token), creator);
        uint256 teamCredit = hook.teamFees(address(0), address(receiver));
        assertGt(teamCredit, 0);
        vm.prank(creator);
        hook.claimCreator(address(token), address(receiver));
        assertTrue(receiver.attempted());
        assertFalse(receiver.reentered());
        // The team recipient also received the launch fee when the pool was created.
        assertEq(address(receiver).balance, creatorCredit + 0.0001 ether);
        assertEq(hook.teamFees(address(0), address(receiver)), teamCredit);
        _assertSolvent(address(0));
    }

    function test_unauthorizedClaimsCannotRedirectCredits() public {
        (KeelV2Token token,, PoolKey memory key) = _launch(address(0), 300);
        _mature();
        _buy(key, address(0), 0.01 ether);
        vm.startPrank(owner);
        vm.expectRevert(KeelV2Hook.NoFees.selector);
        hook.claimCreator(address(token), owner);
        vm.expectRevert(KeelV2Hook.NoFees.selector);
        hook.claimTeam(address(0), owner);
        vm.stopPrank();
        assertEq(hook.creatorFees(address(token), creator), 0.00024 ether);
        assertEq(hook.teamFees(address(0), team), 0.00006 ether);
    }
}
