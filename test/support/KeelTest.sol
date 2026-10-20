// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {KeelV2Token} from "../../src/KeelV2Token.sol";
import {KeelV2Factory} from "../../src/KeelV2Factory.sol";
import {KeelV2Hook} from "../../src/KeelV2Hook.sol";
import {FixedRateModule} from "../../src/FixedRateModule.sol";
import {QuoteTransfer} from "../../src/libraries/QuoteTransfer.sol";
import {MockQuote} from "./MockQuote.sol";
import {Router, IERC20Test} from "./Router.sol";

abstract contract KeelTest is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    address internal constant MAINNET_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address internal constant MAINNET_USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal owner = address(0x10001);
    address internal creator = address(0x10002);
    address internal trader = address(0x10003);
    address internal team = address(0x10004);
    address internal successor = address(0x10005);
    address internal outsider = address(0x10006);
    IPoolManager internal manager;
    KeelV2Factory internal factory;
    KeelV2Hook internal hook;
    FixedRateModule internal module;
    Router internal router;
    MockQuote internal usdc;
    MockQuote internal btc;
    MockQuote internal dai;

    function setUp() public virtual {
        // A CLI fork exercises the deployed manager; the same suite uses real vendored v4 core offline.
        manager = MAINNET_MANAGER.code.length == 0
            ? IPoolManager(address(new PoolManager(owner)))
            : IPoolManager(MAINNET_MANAGER);
        factory = new KeelV2Factory(manager, owner, team);
        bytes32 hash =
            keccak256(abi.encodePacked(type(KeelV2Hook).creationCode, abi.encode(manager, address(factory))));
        bytes32 salt;
        uint160 flags = (1 << 12) | (1 << 11) | (1 << 7) | (1 << 6) | (1 << 3) | (1 << 2);
        for (uint256 i;; ++i) {
            salt = bytes32(i);
            address predicted = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, hash))))
            );
            if (uint160(predicted) & Hooks.ALL_HOOK_MASK == flags) break;
            require(i < 500_000, "salt search exhausted");
        }
        hook = new KeelV2Hook{salt: salt}(manager, address(factory));
        module = new FixedRateModule(address(hook));
        factory.initialize(hook, address(module));
        router = new Router(manager);
        usdc = new MockQuote(6);
        btc = new MockQuote(8);
        dai = new MockQuote(18);
        vm.startPrank(owner);
        factory.configureQuote(address(0), true, -600000, 600000, false, false);
        factory.configureQuote(address(usdc), true, -600000, 600000, false, false);
        factory.configureQuote(address(btc), true, -600000, 600000, false, false);
        factory.configureQuote(address(dai), true, -600000, 600000, false, false);
        vm.stopPrank();
        vm.deal(trader, 1000 ether);
        vm.deal(creator, 1000 ether);
        usdc.mint(trader, 1_000_000_000e6);
        btc.mint(trader, 1_000_000_000e8);
        dai.mint(trader, 1_000_000_000e18);
    }

    function _launch(address quote, uint16 rate)
        internal
        returns (KeelV2Token token, bytes32 id, PoolKey memory key)
    {
        int24 tick = quote == address(usdc) || quote == MAINNET_USDC
            ? int24(-414480)
            : quote == address(btc) ? int24(-368400) : int24(-230280);
        vm.startPrank(creator);
        (address deployed, bytes32 poolId) =
            factory.launch("kkkkk", "lllll", "ipfs://keel", quote, tick, rate);
        vm.stopPrank();
        token = KeelV2Token(deployed);
        id = poolId;
        key = factory.launchInfo(deployed).key;
    }

    function _buy(PoolKey memory key, address quote, uint256 amount) internal returns (BalanceDelta) {
        return _swap(key, quote, amount, trader);
    }

    function _sell(PoolKey memory key, address token, uint256 amount) internal returns (BalanceDelta) {
        return _swap(key, token, amount, trader);
    }

    function _swap(PoolKey memory key, address input, uint256 amount, address who)
        internal
        returns (BalanceDelta result)
    {
        bool zeroForOne = Currency.unwrap(key.currency0) == input;
        SwapParams memory params = SwapParams(
            zeroForOne,
            -int256(amount),
            zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        );
        vm.startPrank(who);
        if (input != address(0)) assertTrue(IERC20Test(input).approve(address(router), amount));
        result = router.swap{value: input == address(0) ? amount : 0}(key, params, amount, who);
        vm.stopPrank();
    }

    function _mature() internal {
        vm.warp(vm.getBlockTimestamp() + 601);
    }

    function _assertSolvent(address quote) internal view {
        uint256 balance = QuoteTransfer.balance(quote, address(hook));
        assertGe(balance, hook.totalUnclaimed(quote), "fee liability exceeds custody");
    }
}
