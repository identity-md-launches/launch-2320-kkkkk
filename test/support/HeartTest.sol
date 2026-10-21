// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {KeelTest} from "./KeelTest.sol";
import {Router} from "./Router.sol";
import {KeelHeart} from "../../src/KeelHeart.sol";
import {KeelV2Token} from "../../src/KeelV2Token.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @dev A heart that accepts every buy and burns all the gas it is given.
contract BurningHeart {
    uint256 public sink;

    function minBuy(address) external pure returns (uint256) {
        return 1;
    }

    function onBuy(address, address, address, uint256, uint256) external {
        while (true) sink += 1;
    }
}

/// @dev A heart whose notifications always revert.
contract RevertingHeart {
    function minBuy(address) external pure returns (uint256) {
        return 1;
    }

    function onBuy(address, address, address, uint256, uint256) external pure {
        revert("heart down");
    }
}

abstract contract HeartTest is KeelTest {
    KeelHeart internal heart;
    Router internal spoofRouter;
    address internal buyer = address(0x20001);
    address internal other = address(0x20002);
    uint256 internal constant MIN_ETH = 0.001 ether;
    uint256 internal constant MIN_USDC = 1e6;

    function setUp() public virtual override {
        super.setUp();
        heart = new KeelHeart(address(hook), owner);
        spoofRouter = new Router(manager);
        vm.startPrank(owner);
        factory.setRouter(address(router));
        factory.setHeart(address(heart));
        heart.addQuote(address(0));
        heart.addQuote(address(usdc));
        heart.setMinBuy(address(0), MIN_ETH);
        heart.setMinBuy(address(usdc), MIN_USDC);
        vm.stopPrank();
        vm.deal(buyer, 1000 ether);
        vm.deal(other, 1000 ether);
        vm.deal(outsider, 1000 ether);
        usdc.mint(buyer, 1_000_000e6);
        usdc.mint(other, 1_000_000e6);
    }

    function _launchMature(address quote)
        internal
        returns (KeelV2Token token, bytes32 id, PoolKey memory key)
    {
        (token, id, key) = _launch(quote, 300);
        _mature();
    }

    function _deadline() internal view returns (uint256 deadline) {
        (, deadline,,) = heart.state();
    }

    function _round() internal view returns (uint256 round) {
        (round,,,) = heart.state();
    }

    function _lastBuyer() internal view returns (address who) {
        (,, who,) = heart.state();
    }

    function _nextBlock() internal {
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 12);
    }

    function _endRound() internal {
        vm.warp(_deadline());
        _nextBlock();
        heart.end();
    }
}
