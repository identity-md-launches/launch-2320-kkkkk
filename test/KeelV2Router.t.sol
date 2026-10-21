// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {RouterTest, MockQuoteLike} from "./support/RouterTest.sol";
import {MockV3Pool, EvilV3Pool, RebasingQuote, EthRejecter} from "./support/RouterMocks.sol";
import {IERC20Test} from "./support/Router.sol";
import {KeelV2Router} from "../src/KeelV2Router.sol";
import {KeelV2Hook} from "../src/KeelV2Hook.sol";
import {KeelV2Token} from "../src/KeelV2Token.sol";
import {Guard} from "../src/libraries/Guard.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @dev Seller whose ETH receipt tries to re-enter the router.
contract Reenterer {
    KeelV2Router internal immutable router;
    address internal immutable token;
    bool public attempted;

    constructor(KeelV2Router router_, address token_) {
        router = router_;
        token = token_;
    }

    function sellAll(uint256 amount) external {
        require(IERC20Test(token).approve(address(router), amount));
        router.sell(token, amount, 0, block.timestamp);
    }

    receive() external payable {
        attempted = true;
        router.buy{value: msg.value}(token, 0, block.timestamp);
    }
}

contract KeelV2RouterTest is RouterTest {
    // ------------------------------------------------------------ happy paths, exact quotes

    function _roundTrip(KeelV2Token token, uint256 ethIn) internal {
        uint256 quoted = _qbuy(buyer, token, ethIn);
        uint256 ethBefore = buyer.balance;
        uint256 tokensBefore = token.balanceOf(buyer);
        vm.expectEmit(true, true, false, true, address(kr));
        emit KeelV2Router.Bought(buyer, address(token), ethIn, quoted);
        uint256 out = _rbuy(buyer, token, ethIn);
        assertEq(out, quoted, "buy == quoteBuy");
        assertEq(token.balanceOf(buyer) - tokensBefore, out, "tokens delivered");
        assertEq(ethBefore - buyer.balance, ethIn, "ETH spent");
        _assertRouterEmpty();

        uint256 amount = out / 2;
        uint256 quotedEth = _qsell(buyer, token, amount);
        ethBefore = buyer.balance;
        vm.startPrank(buyer);
        token.approve(address(kr), amount);
        vm.expectEmit(true, true, false, true, address(kr));
        emit KeelV2Router.Sold(buyer, address(token), amount, quotedEth);
        uint256 ethOut = kr.sell(address(token), amount, quotedEth, _deadline());
        vm.stopPrank();
        assertEq(ethOut, quotedEth, "sell == quoteSell");
        assertEq(buyer.balance - ethBefore, ethOut, "ETH delivered");
        assertEq(token.balanceOf(buyer), tokensBefore + out - amount);
        assertGt(ethOut, 0);
        _assertRouterEmpty();
    }

    function test_native_buySell_matchesQuotes() public {
        _roundTrip(ethToken, 0.001 ether);
        _roundTrip(ethToken, 0.5 ether);
    }

    function test_v4_buySell_matchesQuotes() public {
        _roundTrip(usdcToken, 0.001 ether);
        _roundTrip(usdcToken, 0.5 ether);
    }

    function test_v3_buySell_matchesQuotes() public {
        _roundTrip(btcToken, 0.001 ether);
        _roundTrip(btcToken, 0.5 ether);
    }

    function testFuzz_quotesExact(uint8 which, uint256 ethIn, uint256 sellBps) public {
        KeelV2Token token = _tokens()[which % 3];
        ethIn = bound(ethIn, 1e12, 20 ether);
        sellBps = bound(sellBps, 1, 10_000);
        uint256 quoted = _qbuy(buyer, token, ethIn);
        assertEq(_rbuy(buyer, token, ethIn), quoted);
        uint256 amount = token.balanceOf(buyer) * sellBps / 10_000;
        vm.assume(amount != 0);
        try kr.quoteSell(address(token), amount) returns (uint256 quotedEth) {
            assertEq(_rsell(buyer, token, amount), quotedEth);
        } catch {
            // A sell that rounds to zero ETH reverts in both the quote and the trade.
            vm.startPrank(buyer);
            token.approve(address(kr), amount);
            vm.expectRevert();
            kr.sell(address(token), amount, 0, _deadline());
            vm.stopPrank();
        }
        _assertRouterEmpty();
    }

    /// @dev The quote covers the hook's decaying launch fee too: quote and trade in a fresh pool.
    function test_quoteCoversLaunchFee() public {
        (KeelV2Token fresh,,) = _launch(address(usdc), 250);
        vm.warp(vm.getBlockTimestamp() + 30);
        uint256 quoted = _qbuy(buyer, fresh, 0.1 ether);
        assertEq(_rbuy(buyer, fresh, 0.1 ether), quoted);
        vm.warp(vm.getBlockTimestamp() + 1000);
        uint256 later = _qbuy(buyer, fresh, 0.1 ether);
        assertGt(later, 0);
    }

    function test_quotesAreNotStateChanging() public {
        uint256 a = _qbuy(buyer, usdcToken, 1 ether);
        uint256 b = _qbuy(buyer, usdcToken, 1 ether);
        assertEq(a, b);
        assertEq(heart.eligibleRounds(), 0);
        assertEq(_lastBuyer(), address(0), "a quote never credits the heart");
        _assertRouterEmpty();
    }

    // ------------------------------------------------------------ heart credit

    function test_heartCreditGoesToBuyer_native() public {
        _rbuy(buyer, ethToken, 0.01 ether);
        assertEq(_lastBuyer(), buyer);
        _rbuy(other, ethToken, 0.01 ether);
        assertEq(_lastBuyer(), other);
        assertTrue(_lastBuyer() != address(kr));
    }

    function test_heartCreditGoesToBuyer_v4Quote() public {
        _rbuy(other, usdcToken, 0.01 ether);
        assertEq(_lastBuyer(), other);
        (,,, address lastToken) = heart.state();
        assertEq(lastToken, address(usdcToken));
    }

    function test_sellNeverTouchesHeart() public {
        _rbuy(buyer, ethToken, 0.01 ether);
        uint256 amount = ethToken.balanceOf(buyer);
        vm.prank(buyer);
        ethToken.transfer(other, amount);
        _rsell(other, ethToken, amount);
        assertEq(_lastBuyer(), buyer, "sell does not take the heart");
    }

    function test_spoofedHookDataGivesNoCredit() public {
        _swapVia(
            spoofRouter,
            factory.launchInfo(address(ethToken)).key,
            address(0),
            0.01 ether,
            other,
            abi.encode(buyer)
        );
        assertEq(_lastBuyer(), address(0), "direct pool call naming someone else is ignored");
        _rbuy(buyer, ethToken, 0.01 ether);
        _swapVia(
            spoofRouter,
            factory.launchInfo(address(ethToken)).key,
            address(0),
            0.01 ether,
            other,
            abi.encode(other)
        );
        assertEq(_lastBuyer(), buyer);
    }

    function test_buyBelowHeartMinimumStillTrades() public {
        _rbuy(buyer, ethToken, 0.0001 ether);
        assertEq(_lastBuyer(), address(0));
        _assertRouterEmpty();
    }

    // ------------------------------------------------------------ slippage and deadline

    function test_slippageReverts() public {
        for (uint256 i; i < 3; ++i) {
            KeelV2Token token = _tokens()[i];
            uint256 quoted = _qbuy(buyer, token, 0.1 ether);
            vm.prank(buyer);
            vm.expectRevert(
                abi.encodeWithSelector(KeelV2Router.InsufficientOutput.selector, quoted, quoted + 1)
            );
            kr.buy{value: 0.1 ether}(address(token), quoted + 1, _deadline());
            _rbuy(buyer, token, 0.1 ether);
            uint256 amount = token.balanceOf(buyer);
            uint256 quotedEth = _qsell(buyer, token, amount);
            vm.startPrank(buyer);
            token.approve(address(kr), amount);
            vm.expectRevert(
                abi.encodeWithSelector(KeelV2Router.InsufficientOutput.selector, quotedEth, quotedEth + 1)
            );
            kr.sell(address(token), amount, quotedEth + 1, _deadline());
            vm.stopPrank();
            _assertRouterEmpty();
        }
    }

    function test_deadlineReverts() public {
        uint256 past = vm.getBlockTimestamp() - 1;
        vm.prank(buyer);
        vm.expectRevert(KeelV2Router.Expired.selector);
        kr.buy{value: 0.1 ether}(address(ethToken), 0, past);
        _rbuy(buyer, ethToken, 0.1 ether);
        vm.startPrank(buyer);
        ethToken.approve(address(kr), 1e18);
        vm.expectRevert(KeelV2Router.Expired.selector);
        kr.sell(address(ethToken), 1e18, 0, past);
        // The deadline itself is still valid.
        kr.sell(address(ethToken), 1e18, 0, vm.getBlockTimestamp());
        vm.stopPrank();
    }

    // ------------------------------------------------------------ edge amounts

    function test_oneWeiBuysRevertAndLeaveNothing() public {
        for (uint256 i; i < 3; ++i) {
            vm.prank(buyer);
            vm.expectRevert();
            kr.buy{value: 1}(address(_tokens()[i]), 0, _deadline());
            vm.prank(buyer);
            vm.expectRevert();
            kr.quoteBuy(address(_tokens()[i]), 1);
        }
        vm.prank(buyer);
        vm.expectRevert(KeelV2Router.InvalidAmount.selector);
        kr.buy{value: 0}(address(ethToken), 0, _deadline());
        _assertRouterEmpty();
    }

    function test_tinySellsRoundingToZeroRevert() public {
        for (uint256 i; i < 3; ++i) {
            KeelV2Token token = _tokens()[i];
            _rbuy(buyer, token, 0.01 ether);
            vm.startPrank(buyer);
            token.approve(address(kr), 1);
            vm.expectRevert();
            kr.sell(address(token), 1, 0, _deadline());
            vm.expectRevert();
            kr.quoteSell(address(token), 1);
            vm.expectRevert(KeelV2Router.InvalidAmount.selector);
            kr.sell(address(token), 0, 0, _deadline());
            vm.stopPrank();
        }
        _assertRouterEmpty();
    }

    function test_largestAmounts() public {
        // The whole of a large wallet into each pool, then the whole position back out.
        vm.deal(buyer, 10_000 ether);
        uint256[3] memory sizes = [uint256(1000 ether), 50 ether, 100 ether];
        // NATIVE quoteBuy cannot settle ETH inside eth_call: the hook's fee take needs PoolManager to
        // already hold that much ETH (here ~91 ETH of LP inventory; on mainnet thousands). The trade
        // itself settles first and is unaffected.
        vm.prank(buyer);
        vm.expectRevert();
        kr.quoteBuy(address(ethToken), 5000 ether);
        uint256 bigOut = _rbuy(buyer, ethToken, 5000 ether);
        assertGt(bigOut, 0);
        assertEq(_qbuy(buyer, ethToken, 5000 ether), _rbuy(buyer, ethToken, 5000 ether), "quotable once held");
        _rsell(buyer, ethToken, ethToken.balanceOf(buyer) - bigOut);
        _rsell(buyer, ethToken, bigOut);
        _assertRouterEmpty();
        for (uint256 i; i < 3; ++i) {
            KeelV2Token token = _tokens()[i];
            uint256 quoted = _qbuy(buyer, token, sizes[i]);
            uint256 out = _rbuy(buyer, token, sizes[i]);
            assertEq(out, quoted);
            uint256 quotedEth = _qsell(buyer, token, out);
            assertEq(_rsell(buyer, token, out), quotedEth);
            _assertRouterEmpty();
        }
        // Above int128 the router refuses before touching any pool.
        vm.prank(buyer);
        vm.expectRevert(KeelV2Router.InvalidAmount.selector);
        kr.quoteBuy(address(ethToken), uint256(uint128(type(int128).max)) + 1);
        vm.prank(buyer);
        vm.expectRevert(KeelV2Router.InvalidAmount.selector);
        kr.sell(address(ethToken), uint256(uint128(type(int128).max)) + 1, 0, _deadline());
    }

    function test_sellingMoreThanBoughtRevertsAsPartialFill() public {
        // Only `out` tokens left the pool; selling more cannot fill in full.
        uint256 out = _rbuy(buyer, ethToken, 1 ether);
        deal(address(ethToken), other, out * 3);
        vm.startPrank(other);
        ethToken.approve(address(kr), out * 3);
        vm.expectRevert(KeelV2Router.PartialFill.selector);
        kr.sell(address(ethToken), out * 3, 0, _deadline());
        vm.stopPrank();
        _assertRouterEmpty();
    }

    function test_v3PartialFillReverts() public {
        btcPool.setMaxInput(0.05 ether);
        vm.prank(buyer);
        vm.expectRevert(KeelV2Router.PartialFill.selector);
        kr.buy{value: 0.1 ether}(address(btcToken), 0, _deadline());
        vm.prank(buyer);
        vm.expectRevert(KeelV2Router.PartialFill.selector);
        kr.quoteBuy(address(btcToken), 0.1 ether);
        btcPool.setMaxInput(0);
        _rbuy(buyer, btcToken, 0.1 ether);
        _assertRouterEmpty();
    }

    function test_v4PartialFillReverts() public {
        // A thin ETH/USDC pool with liquidity in one narrow band.
        PoolKey memory thin =
            PoolKey(Currency.wrap(address(0)), Currency.wrap(address(usdc)), 500, 10, IHooks(address(0)));
        _addV4Pool(thin, USDC_TICK, USDC_TICK - 100, USDC_TICK + 100, 1e13);
        vm.prank(owner);
        kr.setRoute(address(usdc), _v4(thin));
        vm.prank(buyer);
        vm.expectRevert(KeelV2Router.PartialFill.selector);
        kr.buy{value: 100 ether}(address(usdcToken), 0, _deadline());
        _roundTrip(usdcToken, 0.0001 ether);
    }

    // ------------------------------------------------------------ non-standard quotes

    function test_feeOnTransferQuoteReverts_v4() public {
        uint256 out = _rbuy(buyer, usdcToken, 0.1 ether);
        usdc.setTaxed(true);
        vm.prank(buyer);
        vm.expectRevert();
        kr.buy{value: 0.1 ether}(address(usdcToken), 0, _deadline());
        vm.startPrank(buyer);
        usdcToken.approve(address(kr), out);
        vm.expectRevert();
        kr.sell(address(usdcToken), out, 0, _deadline());
        vm.stopPrank();
        _assertRouterEmpty();
    }

    function test_feeOnTransferQuoteReverts_v3() public {
        uint256 out = _rbuy(buyer, btcToken, 0.1 ether);
        btc.setTaxed(true);
        vm.prank(buyer);
        vm.expectRevert(KeelV2Router.NonStandardBalance.selector);
        kr.buy{value: 0.1 ether}(address(btcToken), 0, _deadline());
        vm.startPrank(buyer);
        btcToken.approve(address(kr), out);
        vm.expectRevert();
        kr.sell(address(btcToken), out, 0, _deadline());
        vm.stopPrank();
        _assertRouterEmpty();
    }

    function test_rebasingQuoteReverts() public {
        RebasingQuote rbs = new RebasingQuote();
        vm.prank(owner);
        factory.configureQuote(address(rbs), true, -600000, 600000, false, false);
        MockV3Pool pool = _v3Pool(address(rbs), 100 ether, 100_000e18);
        vm.prank(owner);
        kr.setRoute(address(rbs), _v3(address(pool)));
        (KeelV2Token token,,) = _launch(address(rbs), 300);
        _mature();
        uint256 quoted = _qbuy(buyer, token, 0.1 ether);
        assertEq(_rbuy(buyer, token, 0.1 ether), quoted);
        rbs.setRebaseFor(address(kr));
        vm.prank(buyer);
        vm.expectRevert(KeelV2Router.NonStandardBalance.selector);
        kr.buy{value: 0.1 ether}(address(token), 0, _deadline());
        assertEq(rbs.balanceOf(address(kr)), 0);
        assertEq(address(kr).balance, 0);
    }

    function test_unattestedQuoteRefusedAtSetRoute() public {
        MockV3Pool pool = _v3Pool(address(dai), 1 ether, 1000e18);
        vm.startPrank(owner);
        factory.configureQuote(address(dai), false, -600000, 600000, false, false);
        vm.expectRevert(abi.encodeWithSelector(KeelV2Router.QuoteNotAllowed.selector, address(dai)));
        kr.setRoute(address(dai), _v3(address(pool)));
        // The factory itself refuses a quote declared taxed or rebasing.
        vm.expectRevert();
        factory.configureQuote(address(dai), true, -600000, 600000, true, false);
        vm.stopPrank();
    }

    // ------------------------------------------------------------ routes and hooks

    function test_routeValidation() public {
        vm.startPrank(owner);
        KeelV2Router.Route memory r = _native();
        vm.expectRevert(KeelV2Router.InvalidRoute.selector);
        kr.setRoute(address(usdc), r);
        r.v3Pool = address(btcPool);
        vm.expectRevert(KeelV2Router.InvalidRoute.selector);
        kr.setRoute(address(0), r);
        // v4 key must be native/quote.
        PoolKey memory wrong = usdcKey;
        wrong.currency1 = Currency.wrap(address(btc));
        vm.expectRevert(KeelV2Router.InvalidRoute.selector);
        kr.setRoute(address(usdc), _v4(wrong));
        vm.expectRevert(KeelV2Router.InvalidRoute.selector);
        kr.setRoute(address(0), _v4(usdcKey));
        // uninitialized v4 pool
        PoolKey memory empty = usdcKey;
        empty.fee = 100;
        empty.tickSpacing = 1;
        vm.expectRevert(KeelV2Router.InvalidRoute.selector);
        kr.setRoute(address(usdc), _v4(empty));
        // v3 pool of other tokens, an EOA, or WETH itself
        vm.expectRevert(KeelV2Router.InvalidRoute.selector);
        kr.setRoute(address(usdc), _v3(address(btcPool)));
        vm.expectRevert(KeelV2Router.InvalidRoute.selector);
        kr.setRoute(address(usdc), _v3(address(0xBEEF)));
        vm.expectRevert(KeelV2Router.InvalidRoute.selector);
        kr.setRoute(address(0), _v3(address(btcPool)));
        vm.stopPrank();
    }

    function test_hookAllowlist() public {
        address someHook = address(uint160(0xC0));
        PoolKey memory hooked = usdcKey;
        hooked.hooks = IHooks(someHook);
        vm.startPrank(owner);
        assertFalse(kr.hookAllowed(someHook), "starts empty");
        vm.expectRevert(abi.encodeWithSelector(KeelV2Router.HookNotAllowed.selector, someHook));
        kr.setRoute(address(usdc), _v4(hooked));
        vm.expectEmit(true, false, false, true, address(kr));
        emit KeelV2Router.HookAllowlistChanged(someHook, true);
        kr.setHookAllowed(someHook, true);
        // Passes the allowlist; this pool is not initialized.
        vm.expectRevert(KeelV2Router.InvalidRoute.selector);
        kr.setRoute(address(usdc), _v4(hooked));
        vm.expectEmit(true, false, false, true, address(kr));
        emit KeelV2Router.HookAllowlistChanged(someHook, false);
        kr.setHookAllowed(someHook, false);
        vm.expectRevert(KeelV2Router.InvalidAddress.selector);
        kr.setHookAllowed(address(0), true);
        vm.stopPrank();
        vm.prank(outsider);
        vm.expectRevert(KeelV2Router.NotOwner.selector);
        kr.setHookAllowed(someHook, true);
    }

    function test_routeReplacementAndRemoval() public {
        _roundTrip(usdcToken, 0.1 ether);
        // Replace the USDC leg: v4 -> v3.
        MockV3Pool usdcPool = _v3Pool(address(usdc), 100 ether, 300_000e6);
        vm.prank(owner);
        vm.expectEmit(true, false, false, true, address(kr));
        emit KeelV2Router.RouteSet(address(usdc), KeelV2Router.RouteKind.V3, bytes32(0), address(usdcPool));
        kr.setRoute(address(usdc), _v3(address(usdcPool)));
        KeelV2Router.StoredRoute memory stored = kr.routeOf(address(usdc));
        assertEq(uint8(stored.kind), uint8(KeelV2Router.RouteKind.V3));
        assertEq(Currency.unwrap(stored.v4Key.currency1), address(0), "old v4 key cleared");
        uint256 usdcInPool = usdc.balanceOf(address(usdcPool));
        _roundTrip(usdcToken, 0.1 ether);
        assertGt(usdc.balanceOf(address(usdcPool)), 0);
        assertTrue(usdc.balanceOf(address(usdcPool)) != usdcInPool, "new route used");
        // And back to v4.
        vm.prank(owner);
        kr.setRoute(address(usdc), _v4(usdcKey));
        stored = kr.routeOf(address(usdc));
        assertEq(stored.v3Pool, address(0), "old v3 pool cleared");
        _roundTrip(usdcToken, 0.1 ether);
        // Remove: trades revert, funds untouched.
        uint256 held = usdcToken.balanceOf(buyer);
        vm.prank(owner);
        vm.expectEmit(true, false, false, false, address(kr));
        emit KeelV2Router.RouteRemoved(address(usdc));
        kr.setRoute(address(usdc), KeelV2Router.Route(KeelV2Router.RouteKind.NONE, usdcKey, address(0)));
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(KeelV2Router.RouteNotSet.selector, address(usdc)));
        kr.buy{value: 0.1 ether}(address(usdcToken), 0, _deadline());
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(KeelV2Router.RouteNotSet.selector, address(usdc)));
        kr.sell(address(usdcToken), 1, 0, _deadline());
        assertEq(usdcToken.balanceOf(buyer), held);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(KeelV2Router.RouteNotSet.selector, address(usdc)));
        kr.setRoute(address(usdc), KeelV2Router.Route(KeelV2Router.RouteKind.NONE, usdcKey, address(0)));
        _assertRouterEmpty();
    }

    function test_onlyOwnerSetsRoutes() public {
        vm.prank(outsider);
        vm.expectRevert(KeelV2Router.NotOwner.selector);
        kr.setRoute(address(0), _native());
    }

    function test_unknownToken() public {
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(KeelV2Router.UnknownToken.selector, address(usdc)));
        kr.buy{value: 1 ether}(address(usdc), 0, _deadline());
    }

    // ------------------------------------------------------------ ownership and wiring

    function test_twoStepOwnership() public {
        vm.prank(outsider);
        vm.expectRevert(KeelV2Router.NotOwner.selector);
        kr.transferOwnership(outsider);
        vm.prank(owner);
        vm.expectRevert(KeelV2Router.InvalidAddress.selector);
        kr.transferOwnership(address(0));
        vm.prank(owner);
        kr.transferOwnership(successor);
        assertEq(kr.owner(), owner);
        vm.prank(outsider);
        vm.expectRevert(KeelV2Router.NotPendingOwner.selector);
        kr.acceptOwnership();
        vm.prank(successor);
        kr.acceptOwnership();
        assertEq(kr.owner(), successor);
        assertEq(kr.pendingOwner(), address(0));
        vm.prank(owner);
        vm.expectRevert(KeelV2Router.NotOwner.selector);
        kr.setRoute(address(0), _native());
        vm.prank(successor);
        kr.setRoute(address(0), _native());
    }

    function test_constructorAndWiring() public {
        vm.expectRevert(KeelV2Router.InvalidAddress.selector);
        new KeelV2Router(IPoolManager(address(0)), address(factory), hook, address(weth), owner);
        vm.expectRevert(KeelV2Router.InvalidAddress.selector);
        new KeelV2Router(manager, address(factory), hook, address(weth), address(0));
        vm.expectRevert(KeelV2Router.InvalidAddress.selector);
        new KeelV2Router(manager, address(factory), hook, address(0), owner);
        KeelV2Router wrong = new KeelV2Router(
            manager, address(factory), KeelV2Hook(payable(address(0x1234))), address(weth), owner
        );
        vm.prank(owner);
        vm.expectRevert(KeelV2Router.WiringMismatch.selector);
        wrong.setRoute(address(0), _native());
        assertEq(kr.owner(), owner);
        assertEq(address(kr.poolManager()), address(manager));
        assertEq(kr.factory(), address(factory));
        assertEq(address(kr.hook()), address(hook));
        assertEq(kr.weth(), address(weth));
        assertEq(factory.router(), address(kr));
    }

    // ------------------------------------------------------------ callbacks and safety

    function test_unlockCallbackOnlyDuringOwnCall() public {
        vm.prank(address(manager));
        vm.expectRevert(KeelV2Router.InvalidCallback.selector);
        kr.unlockCallback("");
        vm.prank(outsider);
        vm.expectRevert(KeelV2Router.InvalidCallback.selector);
        kr.unlockCallback("");
    }

    function test_v3CallbackOnlyFromActivePool() public {
        vm.prank(address(btcPool));
        vm.expectRevert(KeelV2Router.InvalidCallback.selector);
        kr.uniswapV3SwapCallback(1, -1, "");
        vm.prank(outsider);
        vm.expectRevert(KeelV2Router.InvalidCallback.selector);
        kr.uniswapV3SwapCallback(1, -1, "");
    }

    function test_v3ForgedDeltaAndSkippedCallbackRejected() public {
        EvilV3Pool evil = new EvilV3Pool(address(weth), address(btc));
        vm.prank(owner);
        kr.setRoute(address(btc), _v3(address(evil)));
        vm.prank(buyer);
        vm.expectRevert(KeelV2Router.PartialFill.selector);
        kr.buy{value: 1 ether}(address(btcToken), 0, _deadline());
        vm.prank(owner);
        kr.setRoute(address(btc), _v3(address(btcPool)));
        btcPool.setSkipCallback(true);
        vm.prank(buyer);
        vm.expectRevert();
        kr.buy{value: 1 ether}(address(btcToken), 0, _deadline());
        _assertRouterEmpty();
    }

    function test_simulateIsSelfOnly() public {
        vm.prank(outsider);
        vm.expectRevert(KeelV2Router.OnlySelf.selector);
        kr.simulate(true, address(ethToken), 1 ether, outsider);
    }

    function test_rejectsStrayEther() public {
        vm.prank(outsider);
        (bool ok,) = address(kr).call{value: 1 ether}("");
        assertFalse(ok);
        assertEq(address(kr).balance, 0);
    }

    function test_sellToEthRejectingContractReverts() public {
        EthRejecter rejecter = new EthRejecter();
        uint256 out = _rbuy(buyer, ethToken, 0.1 ether);
        vm.prank(buyer);
        ethToken.transfer(address(rejecter), out);
        rejecter.approve(address(ethToken), address(kr), out);
        vm.expectRevert(KeelV2Router.EthTransferFailed.selector);
        rejecter.sell(
            address(kr), abi.encodeCall(KeelV2Router.sell, (address(ethToken), out, 0, _deadline()))
        );
        assertEq(ethToken.balanceOf(address(rejecter)), out);
        _assertRouterEmpty();
    }

    function test_reentrancyBlocked() public {
        Reenterer attacker = new Reenterer(kr, address(ethToken));
        uint256 out = _rbuy(buyer, ethToken, 0.1 ether);
        vm.prank(buyer);
        ethToken.transfer(address(attacker), out);
        vm.expectRevert(KeelV2Router.EthTransferFailed.selector);
        attacker.sellAll(out);
        _assertRouterEmpty();
    }

    function test_forcedBalanceDoesNotBreakOrLeak() public {
        // Tokens pushed to the router by a third party are not swept or spent: balance deltas stay zero.
        uint256 out = _rbuy(buyer, ethToken, 0.1 ether);
        vm.prank(buyer);
        ethToken.transfer(address(kr), 1e18);
        uint256 again = _rbuy(other, ethToken, 0.1 ether);
        assertGt(again, 0);
        assertEq(ethToken.balanceOf(address(kr)), 1e18);
        _rsell(buyer, ethToken, out - 1e18);
        assertEq(ethToken.balanceOf(address(kr)), 1e18);
    }
}
