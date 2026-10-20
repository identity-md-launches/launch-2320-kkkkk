// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {KeelTest} from "./support/KeelTest.sol";
import {KeelV2Token} from "../src/KeelV2Token.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IERC20Test} from "./support/Router.sol";

/// @dev Opt-in via forge test --fork-url ... --fork-block-number 22000000.
/// The entire ordinary suite also runs against deployed PoolManager when a CLI fork is supplied.
contract MainnetForkTest is KeelTest {
    function test_mainnetRealUSDCAndETH() public {
        if (address(manager) != MAINNET_MANAGER) {
            vm.skip(true);
            return;
        }
        assertEq(block.chainid, 1);
        vm.prank(owner);
        factory.configureQuote(MAINNET_USDC, true, -600000, 600000, false, false);
        deal(MAINNET_USDC, trader, 100_000e6);
        (KeelV2Token token,, PoolKey memory key) = _launch(MAINNET_USDC, 333);
        _mature();
        _buy(key, MAINNET_USDC, 100e6 + 1);
        _sell(key, address(token), token.balanceOf(trader) / 2);
        uint256 credit = hook.creatorFees(address(token), creator);
        vm.prank(creator);
        hook.claimCreator(address(token), outsider);
        assertEq(IERC20Test(MAINNET_USDC).balanceOf(outsider), credit);
        _assertSolvent(MAINNET_USDC);
        (,, PoolKey memory ethKey) = _launch(address(0), 300);
        _buy(ethKey, address(0), 0.01 ether);
        _assertSolvent(address(0));
    }
}
