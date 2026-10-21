// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HeartTest} from "./support/HeartTest.sol";
import {Router} from "./support/Router.sol";
import {MockQuote} from "./support/MockQuote.sol";
import {KeelHeart} from "../src/KeelHeart.sol";
import {KeelV2Hook} from "../src/KeelV2Hook.sol";
import {KeelV2Token} from "../src/KeelV2Token.sol";
import {QuoteTransfer} from "../src/libraries/QuoteTransfer.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

contract HeartHandler is Test {
    KeelHeart public heart;
    KeelV2Hook public hook;
    Router public router;
    MockQuote public usdc;
    KeelV2Token[2] public tokens;
    PoolKey[2] private _keys;
    address[3] public buyers;
    uint256 public ends;
    uint256 public claims;
    uint256 public funded;

    constructor(
        KeelHeart heart_,
        KeelV2Hook hook_,
        Router router_,
        MockQuote usdc_,
        KeelV2Token[2] memory tokens_,
        PoolKey[2] memory keys_
    ) {
        heart = heart_;
        hook = hook_;
        router = router_;
        usdc = usdc_;
        tokens = tokens_;
        _keys = keys_;
        buyers = [address(0x30001), address(0x30002), address(0x30003)];
        for (uint256 i; i < 3; ++i) {
            vm.deal(buyers[i], 10_000 ether);
            usdc_.mint(buyers[i], 1_000_000e6);
        }
    }

    function buy(uint8 pool, uint8 who, uint96 rawAmount, bool named) external {
        uint256 p = pool % 2;
        address buyer = buyers[who % 3];
        address quote = p == 0 ? address(0) : address(usdc);
        uint256 amount = p == 0 ? bound(rawAmount, 1e14, 5e16) : bound(rawAmount, 1e5, 50e6);
        _swap(p, quote, amount, buyer, named ? abi.encode(buyer) : bytes(""));
    }

    function sell(uint8 pool, uint8 who, uint96 rawAmount) external {
        uint256 p = pool % 2;
        address seller = buyers[who % 3];
        uint256 balance = tokens[p].balanceOf(seller);
        if (balance < 2) return;
        _swap(p, address(tokens[p]), bound(rawAmount, 1, balance / 2), seller, "");
    }

    function fund(bool eth, uint96 rawAmount) external {
        address quote = eth ? address(0) : address(usdc);
        uint256 amount = eth ? bound(rawAmount, 1, 1 ether) : bound(rawAmount, 1, 1000e6);
        address from = buyers[0];
        vm.startPrank(from);
        if (eth) {
            heart.fund{value: amount}(quote, amount);
        } else {
            usdc.approve(address(heart), amount);
            heart.fund(quote, amount);
        }
        vm.stopPrank();
        funded += 1;
    }

    function end() external {
        (, uint256 deadline,,) = heart.state();
        if (deadline == 0 || vm.getBlockTimestamp() < deadline) return;
        heart.end();
        ends += 1;
    }

    function claim(uint8 rawRound) external {
        (uint256 round,,,) = heart.state();
        if (round == 0) return;
        uint256 target = bound(rawRound, 1, round);
        (address winner,,, bool eligible, bool claimed) = heart.result(target);
        if (winner == address(0) || !eligible || claimed) return;
        vm.prank(winner);
        heart.claim(target, winner);
        claims += 1;
    }

    function advance(uint16 seconds_, uint8 blocks) external {
        vm.warp(vm.getBlockTimestamp() + bound(seconds_, 0, 700));
        vm.roll(vm.getBlockNumber() + bound(blocks, 0, 3));
    }

    function _swap(uint256 p, address input, uint256 amount, address who, bytes memory data) private {
        PoolKey memory key = _keys[p];
        bool zeroForOne = Currency.unwrap(key.currency0) == input;
        SwapParams memory params = SwapParams(
            zeroForOne,
            -int256(amount),
            zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        );
        vm.startPrank(who);
        if (input != address(0)) MockQuote(input).approve(address(router), amount);
        router.swap{value: input == address(0) ? amount : 0}(key, params, amount, who, data);
        vm.stopPrank();
    }
}

contract HeartInvariantTest is HeartTest {
    HeartHandler private handler;

    function setUp() public override {
        super.setUp();
        KeelV2Token[2] memory tokens;
        PoolKey[2] memory keys;
        (tokens[0],, keys[0]) = _launchMature(address(0));
        (tokens[1],, keys[1]) = _launchMature(address(usdc));
        handler = new HeartHandler(heart, hook, router, usdc, tokens, keys);
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = HeartHandler.buy.selector;
        selectors[1] = HeartHandler.sell.selector;
        selectors[2] = HeartHandler.fund.selector;
        selectors[3] = HeartHandler.end.selector;
        selectors[4] = HeartHandler.claim.selector;
        selectors[5] = HeartHandler.advance.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariant_heartSolventAndConserved() public view {
        address[] memory quotes = heart.quoteList();
        (uint256 round, uint256 deadline,,) = heart.state();
        for (uint256 q; q < quotes.length; ++q) {
            uint256 unpaid;
            for (uint256 r = 1; r <= round; ++r) {
                (address winner,,, bool eligible, bool claimed) = heart.result(r);
                if (winner != address(0) && eligible && !claimed) unpaid += heart.prizeOf(r, quotes[q]);
            }
            uint256 liability = heart.liability(quotes[q]);
            assertEq(liability, heart.potOf(quotes[q]) + unpaid, "pot plus prizes must equal liability");
            assertGe(QuoteTransfer.balance(quotes[q], address(heart)), liability, "heart insolvent");
        }
        if (deadline != 0) assertLe(deadline, vm.getBlockTimestamp() + 600);
    }

    function invariant_hookSolvent() public view {
        _assertSolvent(address(0));
        _assertSolvent(address(usdc));
    }
}

contract SwapIdentityTest is HeartTest {
    function testFuzz_swapResultIdenticalWithOrWithoutHeart(uint96[4] memory amounts, uint8 flags) public {
        (KeelV2Token token,, PoolKey memory key) = _launchMature(address(0));
        vm.prank(outsider);
        heart.fund{value: 1 ether}(address(0), 1 ether);
        uint256 snapshot = vm.snapshotState();
        BalanceDelta[4] memory withHeart = _run(key, token, amounts, flags);
        uint256 deadline = _deadline();
        vm.revertToState(snapshot);
        vm.mockCall(address(factory), abi.encodeCall(factory.heart, ()), abi.encode(address(0)));
        BalanceDelta[4] memory without = _run(key, token, amounts, flags);
        vm.clearMockedCalls();
        assertEq(_deadline(), 0);
        for (uint256 i; i < 4; ++i) {
            assertEq(BalanceDelta.unwrap(withHeart[i]), BalanceDelta.unwrap(without[i]));
        }
        if (flags & 1 == 0) assertGt(deadline, 0);
    }

    function _run(PoolKey memory key, KeelV2Token token, uint96[4] memory amounts, uint8 flags)
        private
        returns (BalanceDelta[4] memory deltas)
    {
        for (uint256 i; i < 4; ++i) {
            uint256 amount = bound(amounts[i], 0.001 ether, 0.1 ether);
            bool sell = (flags >> i) & 1 == 1 && token.balanceOf(buyer) > 1;
            if (sell) {
                deltas[i] = _swapVia(router, key, address(token), token.balanceOf(buyer) / 2, buyer, "");
            } else {
                deltas[i] = _routerBuy(key, address(0), amount, buyer);
            }
            vm.warp(vm.getBlockTimestamp() + (amounts[i] % 400));
            vm.roll(vm.getBlockNumber() + 1);
        }
    }
}
