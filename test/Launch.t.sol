// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {KeelTest} from "./support/KeelTest.sol";
import {MockQuote} from "./support/MockQuote.sol";
import {KeelV2Token} from "../src/KeelV2Token.sol";
import {KeelV2Factory} from "../src/KeelV2Factory.sol";
import {KeelV2Hook} from "../src/KeelV2Hook.sol";
import {FixedRateModule} from "../src/FixedRateModule.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

contract LaunchTest is KeelTest {
    using StateLibrary for IPoolManager;

    function test_launchETHWholeSupplyLockedAndCheckpointed() public {
        (KeelV2Token token, bytes32 id, PoolKey memory key) = _launch(address(0), 300);
        KeelV2Factory.LaunchInfo memory info = factory.launchInfo(address(token));
        assertEq(token.balanceOf(address(manager)), 1e27);
        assertEq(token.balanceOf(address(factory)), 0);
        assertEq(token.balanceOf(creator), 0);
        assertEq(info.liquidityTokens + info.lockedDust, 1e27);
        assertGt(info.liquidityTokens, 1e27 - 1e12);
        assertGt(info.liquidity, 0);
        assertEq(info.metadata, "ipfs://keel");
        assertEq(key.fee, 0);
        assertEq(address(key.hooks), address(hook));
        assertEq(hook.poolInfo(id).creator, creator);
        (uint128 position,,) = manager.getPositionInfo(
            PoolId.wrap(id), address(factory), info.tickLower, info.tickUpper, bytes32(0)
        );
        assertEq(position, info.liquidity);
        uint256 launchBlock = vm.getBlockNumber();
        vm.roll(launchBlock + 1);
        assertEq(token.balanceAt(address(manager), launchBlock), 1e27);
        assertEq(token.balanceAt(address(factory), launchBlock), 0);
    }

    function test_launch6and8and18DecimalQuotes() public {
        address[3] memory bases = [address(usdc), address(btc), address(dai)];
        for (uint256 i; i < bases.length; ++i) {
            (KeelV2Token token,, PoolKey memory key) = _launch(bases[i], 100);
            assertEq(token.balanceOf(address(manager)), 1e27);
            assertTrue(
                Currency.unwrap(key.currency0) == bases[i] || Currency.unwrap(key.currency1) == bases[i]
            );
            _mature();
            uint256 amount = i == 0 ? 1e6 : i == 1 ? 1e8 : 1 ether;
            _buy(key, bases[i], amount);
            assertGt(token.balanceOf(trader), 0);
            _sell(key, address(token), token.balanceOf(trader) / 2);
            _assertSolvent(bases[i]);
        }
    }

    function test_bothAddressOrderings() public {
        bool seenToken0;
        bool seenToken1;
        for (uint256 i; i < 30 && !(seenToken0 && seenToken1); ++i) {
            (KeelV2Token token,, PoolKey memory key) = _launch(address(usdc), 300);
            if (Currency.unwrap(key.currency0) == address(token)) seenToken0 = true;
            else seenToken1 = true;
            _mature();
            _buy(key, address(usdc), 1e6);
            _sell(key, address(token), token.balanceOf(trader) / 2);
        }
        assertTrue(seenToken0 && seenToken1, "did not exercise both price orientations");
    }

    function test_outsideAddAndRemoveRevert() public {
        (KeelV2Token token, bytes32 id, PoolKey memory key) = _launch(address(0), 300);
        KeelV2Factory.LaunchInfo memory info = factory.launchInfo(address(token));
        vm.expectRevert();
        router.modify(key, ModifyLiquidityParams(info.tickLower, info.tickUpper, 1, bytes32(0)));
        vm.expectRevert();
        router.modify(key, ModifyLiquidityParams(info.tickLower, info.tickUpper, -1, bytes32(0)));
        (uint128 position,,) = manager.getPositionInfo(
            PoolId.wrap(id), address(factory), info.tickLower, info.tickUpper, bytes32(0)
        );
        assertEq(position, info.liquidity);
        (bool ok,) = address(factory)
            .call(abi.encodeWithSignature("removeLiquidity(address,uint128)", address(token), info.liquidity));
        assertFalse(ok);
    }

    function test_pauseOnlyNewLaunches() public {
        (,, PoolKey memory key) = _launch(address(0), 300);
        vm.prank(owner);
        factory.setLaunchesPaused(true);
        vm.expectRevert(KeelV2Factory.LaunchesPaused.selector);
        factory.launch("k", "l", "", address(0), -230280, 300);
        _mature();
        _buy(key, address(0), 0.01 ether);
        vm.prank(owner);
        factory.setLaunchesPaused(false);
        _launch(address(0), 300);
    }

    function test_launchValidation() public {
        vm.expectRevert(KeelV2Factory.QuoteNotAllowed.selector);
        factory.launch("k", "l", "", outsider, -230280, 300);
        vm.expectRevert(KeelV2Factory.InvalidTicks.selector);
        factory.launch("k", "l", "", address(0), -230281, 300);
        vm.expectRevert(KeelV2Factory.InvalidTicks.selector);
        factory.launch("k", "l", "", address(0), -600060, 300);
        vm.expectRevert(KeelV2Factory.InvalidRate.selector);
        factory.launch("k", "l", "", address(0), -230280, 99);
        vm.expectRevert(KeelV2Factory.InvalidRate.selector);
        factory.launch("k", "l", "", address(0), -230280, 501);
        vm.expectRevert(KeelV2Factory.InvalidMetadata.selector);
        factory.launch("", "l", "", address(0), -230280, 300);
        KeelV2Factory unconfigured = new KeelV2Factory(manager, owner, team);
        vm.expectRevert(KeelV2Factory.NotConfigured.selector);
        unconfigured.launch("k", "l", "", address(0), -230280, 300);
    }

    function test_quoteClassificationAndBounds() public {
        MockQuote badDecimals = new MockQuote(9);
        vm.startPrank(owner);
        vm.expectRevert(KeelV2Factory.UnsupportedQuote.selector);
        factory.configureQuote(address(usdc), true, -600000, 600000, true, false);
        vm.expectRevert(KeelV2Factory.UnsupportedQuote.selector);
        factory.configureQuote(address(usdc), true, -600000, 600000, false, true);
        vm.expectRevert(KeelV2Factory.UnsupportedQuote.selector);
        factory.configureQuote(address(badDecimals), true, -600000, 600000, false, false);
        vm.expectRevert(KeelV2Factory.InvalidTicks.selector);
        factory.configureQuote(address(0), true, -887220, 600000, false, false);
        vm.expectRevert(KeelV2Factory.InvalidTicks.selector);
        factory.configureQuote(address(0), true, 60, 0, false, false);
        vm.expectRevert(KeelV2Factory.InvalidTicks.selector);
        factory.configureQuote(address(0), true, 1, 600000, false, false);
        factory.configureQuote(address(0), true, -230280, -230280, false, false);
        vm.stopPrank();
        _launch(address(0), 300);
        vm.expectRevert(KeelV2Factory.InvalidTicks.selector);
        factory.launch("k", "l", "", address(0), -230220, 300);
    }

    function test_ownerPowersApplyOnlyToFuturePools() public {
        (KeelV2Token token, bytes32 id, PoolKey memory key) = _launch(address(0), 300);
        vm.startPrank(owner);
        factory.setDecaySeconds(600);
        factory.configureQuote(address(0), false, 0, 60000, false, false);
        factory.registerModule(address(new FixedRateModule(address(hook))));
        vm.expectRevert(KeelV2Hook.NotCreator.selector);
        hook.transferCreator(address(token), owner);
        vm.expectRevert(KeelV2Hook.NotCreator.selector);
        module.lowerRate(id, 100);
        vm.stopPrank();
        KeelV2Hook.Pool memory pool = hook.poolInfo(id);
        assertEq(pool.module, address(module));
        assertEq(pool.decaySeconds, 120);
        assertEq(pool.creator, creator);
        _mature();
        _buy(key, address(0), 0.01 ether);
    }

    function test_ownerGuardsAndTwoStep() public {
        vm.expectRevert(KeelV2Factory.NotOwner.selector);
        factory.setLaunchesPaused(true);
        vm.expectRevert(KeelV2Factory.NotOwner.selector);
        factory.configureQuote(address(0), false, 0, 60, false, false);
        vm.expectRevert(KeelV2Factory.NotOwner.selector);
        factory.setDecaySeconds(30);
        vm.expectRevert(KeelV2Factory.NotOwner.selector);
        factory.registerModule(address(module));
        vm.expectRevert(KeelV2Factory.NotOwner.selector);
        factory.setTeamRecipient(outsider);
        vm.expectRevert(KeelV2Factory.NotOwner.selector);
        factory.setTakeoverContract(address(router));
        vm.expectRevert(KeelV2Factory.NotOwner.selector);
        factory.transferOwnership(successor);
        vm.startPrank(owner);
        vm.expectRevert(KeelV2Factory.InvalidAddress.selector);
        factory.transferOwnership(address(0));
        factory.transferOwnership(successor);
        vm.stopPrank();
        assertEq(factory.owner(), owner);
        vm.expectRevert(KeelV2Factory.NotPendingOwner.selector);
        factory.acceptOwnership();
        vm.prank(successor);
        factory.acceptOwnership();
        assertEq(factory.owner(), successor);
        assertEq(factory.pendingOwner(), address(0));
        vm.expectRevert(KeelV2Factory.NotOwner.selector);
        vm.prank(owner);
        factory.setLaunchesPaused(true);
    }

    function test_decayModuleAndTakeoverGuards() public {
        vm.startPrank(owner);
        vm.expectRevert(KeelV2Factory.InvalidDecay.selector);
        factory.setDecaySeconds(29);
        vm.expectRevert(KeelV2Factory.InvalidDecay.selector);
        factory.setDecaySeconds(601);
        factory.setDecaySeconds(30);
        factory.setDecaySeconds(600);
        vm.expectRevert(KeelV2Factory.InvalidModule.selector);
        factory.registerModule(address(0));
        FixedRateModule wrongHook = new FixedRateModule(outsider);
        vm.expectRevert(KeelV2Factory.InvalidModule.selector);
        factory.registerModule(address(wrongHook));
        vm.expectRevert(KeelV2Factory.InvalidAddress.selector);
        factory.setTeamRecipient(address(0));
        vm.expectRevert(KeelV2Factory.InvalidAddress.selector);
        factory.setTakeoverContract(outsider);
        factory.setTakeoverContract(address(router));
        vm.expectRevert(KeelV2Factory.AlreadySet.selector);
        factory.setTakeoverContract(address(module));
        vm.stopPrank();
        vm.expectRevert(KeelV2Factory.AlreadyInitialized.selector);
        factory.initialize(hook, address(module));
    }

    function test_callbackAndUnknownPoolGuards() public {
        (,, PoolKey memory key) = _launch(address(0), 300);
        vm.expectRevert(KeelV2Hook.OnlyPoolManager.selector);
        hook.afterInitialize(address(factory), key, 1, 0);
        vm.expectRevert(KeelV2Hook.OnlyPoolManager.selector);
        hook.beforeSwap(trader, key, SwapParams(true, -1, 1), "");
        vm.expectRevert(KeelV2Factory.OnlyPoolManager.selector);
        factory.unlockCallback(abi.encode(address(usdc)));
        vm.expectRevert(KeelV2Factory.InvalidCallback.selector);
        vm.prank(address(manager));
        factory.unlockCallback(abi.encode(address(usdc)));
        PoolKey memory unknown =
            PoolKey(Currency.wrap(address(0)), Currency.wrap(address(usdc)), 0, 60, IHooks(address(hook)));
        vm.expectRevert();
        manager.initialize(unknown, TickMath.getSqrtPriceAtTick(0));
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(hook).call{value: 1}("");
        assertFalse(ok);
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, hook.PERMISSION_FLAGS());
    }

    function test_canDisableQuoteWhoseMetadataBreaks() public {
        vm.mockCallRevert(address(usdc), abi.encodeWithSignature("decimals()"), "broken metadata");
        vm.prank(owner);
        factory.configureQuote(address(usdc), false, -600000, 600000, false, false);
        (bool enabled, uint8 decimals,,) = factory.quotes(address(usdc));
        assertFalse(enabled);
        assertEq(decimals, 6);
    }

    function test_realSwapsCheckpointPoolManagerAndTrader() public {
        (KeelV2Token token,, PoolKey memory key) = _launch(address(0), 300);
        _mature();
        uint256 launchBlock = vm.getBlockNumber();
        vm.roll(launchBlock + 1);
        _buy(key, address(0), 0.01 ether);
        uint256 bought = token.balanceOf(trader);
        _sell(key, address(token), bought / 2);
        uint256 remaining = token.balanceOf(trader);
        vm.roll(launchBlock + 2);
        assertEq(token.balanceAt(address(manager), launchBlock), 1e27);
        assertEq(token.balanceAt(trader, launchBlock), 0);
        assertEq(token.balanceAt(address(manager), launchBlock + 1), 1e27 - remaining);
        assertEq(token.balanceAt(trader, launchBlock + 1), remaining);
    }
}
