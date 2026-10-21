// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {KeelTest} from "./support/KeelTest.sol";
import {IERC20Test} from "./support/Router.sol";
import {KeelV2Router} from "../src/KeelV2Router.sol";
import {KeelV2Token} from "../src/KeelV2Token.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @dev Opt-in: forge test --fork-url <mainnet archive RPC> --fork-block-number 22000000 --match-contract RouterMainnetForkTest
///      Skips without a fork. Uses real WETH9, the USDC/WETH 0.05% v3 pool and the ETH/USDC 0.05% v4 pool.
contract RouterMainnetForkTest is KeelTest {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant V3_USDC_WETH_500 = 0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640;
    KeelV2Router internal kr;

    function _fork() internal returns (bool) {
        if (address(manager) != MAINNET_MANAGER || block.chainid != 1) {
            vm.skip(true);
            return false;
        }
        kr = new KeelV2Router(manager, address(factory), hook, WETH, owner);
        vm.startPrank(owner);
        factory.setRouter(address(kr));
        factory.configureQuote(MAINNET_USDC, true, -600000, 600000, false, false);
        vm.stopPrank();
        vm.deal(trader, 100 ether);
        return true;
    }

    function _trade(KeelV2Token token) internal {
        vm.startPrank(trader);
        uint256 quoted = kr.quoteBuy(address(token), 0.5 ether);
        uint256 out = kr.buy{value: 0.5 ether}(address(token), quoted, block.timestamp);
        assertEq(out, quoted);
        uint256 quotedEth = kr.quoteSell(address(token), out / 2);
        token.approve(address(kr), out / 2);
        uint256 ethOut = kr.sell(address(token), out / 2, quotedEth, block.timestamp);
        assertEq(ethOut, quotedEth);
        vm.stopPrank();
        assertEq(address(kr).balance, 0);
        assertEq(IERC20Test(WETH).balanceOf(address(kr)), 0);
        assertEq(IERC20Test(MAINNET_USDC).balanceOf(address(kr)), 0);
        assertEq(token.balanceOf(address(kr)), 0);
    }

    function test_fork_v3UsdcRoute() public {
        if (!_fork()) return;
        vm.prank(owner);
        kr.setRoute(
            MAINNET_USDC, KeelV2Router.Route(KeelV2Router.RouteKind.V3, _emptyKey(), V3_USDC_WETH_500)
        );
        (KeelV2Token token,,) = _launch(MAINNET_USDC, 300);
        _mature();
        _trade(token);
    }

    function test_fork_v4UsdcRoute() public {
        if (!_fork()) return;
        PoolKey memory key =
            PoolKey(Currency.wrap(address(0)), Currency.wrap(MAINNET_USDC), 500, 10, IHooks(address(0)));
        (uint160 price,,,) = manager.getSlot0(key.toId());
        if (price == 0) {
            vm.skip(true);
            return;
        }
        vm.prank(owner);
        kr.setRoute(MAINNET_USDC, KeelV2Router.Route(KeelV2Router.RouteKind.V4, key, address(0)));
        (KeelV2Token token,,) = _launch(MAINNET_USDC, 300);
        _mature();
        _trade(token);
    }

    function test_fork_nativeRoute() public {
        if (!_fork()) return;
        vm.prank(owner);
        kr.setRoute(address(0), KeelV2Router.Route(KeelV2Router.RouteKind.NATIVE, _emptyKey(), address(0)));
        (KeelV2Token token,,) = _launch(address(0), 300);
        _mature();
        _trade(token);
    }

    function _emptyKey() internal pure returns (PoolKey memory key) {}
}
