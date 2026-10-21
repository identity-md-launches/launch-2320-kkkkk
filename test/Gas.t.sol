// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {KeelTest} from "./support/KeelTest.sol";
import {KeelHeart} from "../src/KeelHeart.sol";
import {KeelV2Token} from "../src/KeelV2Token.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Router} from "./support/Router.sol";

/// @dev Each test performs exactly one swap through the test router; `forge snapshot` records it.
abstract contract GasBase is KeelTest {
    KeelV2Token internal token;
    PoolKey internal key;
    address internal buyer = address(0x20001);
    Router internal spoofRouter;

    function setUp() public virtual override {
        super.setUp();
        spoofRouter = new Router(manager);
        vm.prank(owner);
        factory.setRouter(address(router));
        (token,, key) = _launch(address(0), 300);
        _mature();
        vm.deal(buyer, 100 ether);
        _buy(key, address(0), 0.01 ether);
        vm.roll(vm.getBlockNumber() + 1);
    }

    function test_gas_plainBuyNoHookData() public {
        _buy(key, address(0), 0.01 ether);
    }

    function test_gas_routerBuyNamed() public {
        _routerBuy(key, address(0), 0.01 ether, buyer);
    }

    function test_gas_nonRouterBuyNamed() public {
        _swapVia(spoofRouter, key, address(0), 0.01 ether, buyer, abi.encode(buyer));
    }

    function test_gas_sell() public {
        _sell(key, address(token), token.balanceOf(trader) / 2);
    }
}

contract GasWithoutHeartTest is GasBase {}

contract GasWithHeartTest is GasBase {
    KeelHeart internal heart;

    function setUp() public virtual override {
        super.setUp();
        heart = new KeelHeart(address(hook), owner);
        vm.startPrank(owner);
        factory.setHeart(address(heart));
        heart.addQuote(address(0));
        heart.setMinBuy(address(0), 0.001 ether);
        vm.stopPrank();
        vm.deal(outsider, 1 ether);
        vm.prank(outsider);
        heart.fund{value: 1 ether}(address(0), 1 ether);
    }

    /// @dev A counted buy while a round is running (timer extension).
    function test_gas_routerBuyRoundRunning() public {
        _routerBuy(key, address(0), 0.01 ether, buyer);
        vm.warp(vm.getBlockTimestamp() + 1);
        _routerBuy(key, address(0), 0.01 ether, buyer);
    }

    /// @dev A counted buy that ends the previous round inside onBuy and starts the next one.
    function test_gas_routerBuyEndsRoundInsideOnBuy() public {
        _routerBuy(key, address(0), 0.01 ether, buyer);
        vm.warp(vm.getBlockTimestamp() + 601);
        vm.roll(vm.getBlockNumber() + 1);
        _routerBuy(key, address(0), 0.01 ether, buyer);
    }
}
