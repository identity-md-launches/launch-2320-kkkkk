// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {KeelTest} from "./support/KeelTest.sol";
import {Router} from "./support/Router.sol";
import {KeelV2Token} from "../src/KeelV2Token.sol";
import {KeelV2Hook} from "../src/KeelV2Hook.sol";
import {KeelV2Factory} from "../src/KeelV2Factory.sol";
import {FixedRateModule} from "../src/FixedRateModule.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

contract FeeHandler is Test {
    KeelV2Token public token;
    KeelV2Hook public hook;
    KeelV2Factory public factory;
    Router public router;
    PoolKey private _key;
    address public trader;
    address public firstCreator;
    address public secondCreator;
    address public firstTeam;
    address public secondTeam;
    uint256 public buys;
    uint256 public sells;
    uint256 public claims;

    constructor(
        KeelV2Token token_,
        KeelV2Hook hook_,
        KeelV2Factory factory_,
        Router router_,
        PoolKey memory key_,
        address trader_,
        address creator_,
        address team_
    ) {
        token = token_;
        hook = hook_;
        factory = factory_;
        router = router_;
        _key = key_;
        trader = trader_;
        firstCreator = creator_;
        firstTeam = team_;
        secondCreator = address(0xCAFE01);
        secondTeam = address(0xCAFE02);
    }

    function buy(uint96 rawAmount) external {
        uint256 amount = bound(rawAmount, 1e14, 2e16);
        bool zeroForOne = Currency.unwrap(_key.currency0) == address(0);
        vm.prank(trader);
        router.swap{value: amount}(
            _key,
            SwapParams(
                zeroForOne,
                -int256(amount),
                zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            amount,
            trader
        );
        ++buys;
    }

    function sell(uint96 rawAmount) external {
        uint256 balance = token.balanceOf(trader);
        if (balance < 2) return;
        uint256 amount = bound(rawAmount, 1, balance / 2);
        bool zeroForOne = Currency.unwrap(_key.currency0) == address(token);
        vm.startPrank(trader);
        token.approve(address(router), amount);
        router.swap(
            _key,
            SwapParams(
                zeroForOne,
                -int256(amount),
                zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            amount,
            trader
        );
        vm.stopPrank();
        ++sells;
    }

    function claim(uint8 who) external {
        address beneficiary = who % 4 == 0
            ? firstCreator
            : who % 4 == 1 ? secondCreator : who % 4 == 2 ? firstTeam : secondTeam;
        if (who % 4 < 2) {
            if (hook.creatorFees(address(token), beneficiary) == 0) return;
            vm.prank(beneficiary);
            hook.claimCreator(address(token), beneficiary);
        } else {
            if (hook.teamFees(address(0), beneficiary) == 0) return;
            vm.prank(beneficiary);
            hook.claimTeam(address(0), beneficiary);
        }
        ++claims;
    }

    function transferCreator() external {
        bytes32 id = hook.poolIdOf(address(token));
        address current = hook.poolInfo(id).creator;
        address next = current == firstCreator ? secondCreator : firstCreator;
        vm.prank(current);
        hook.transferCreator(address(token), next);
    }

    function transferTeam() external {
        address next = factory.teamRecipient() == firstTeam ? secondTeam : firstTeam;
        address governor = factory.owner();
        vm.prank(governor);
        factory.setTeamRecipient(next);
    }

    function lower(uint16 rawRate) external {
        bytes32 id = hook.poolIdOf(address(token));
        KeelV2Hook.Pool memory pool = hook.poolInfo(id);
        FixedRateModule module = FixedRateModule(pool.module);
        uint16 current = module.feeBps(id, true, "");
        if (current <= 100) return;
        uint16 next = uint16(bound(rawRate, 100, current - 1));
        vm.prank(pool.creator);
        module.lowerRate(id, next);
    }

    function advance(uint32 seconds_) external {
        vm.warp(vm.getBlockTimestamp() + bound(seconds_, 0, 2 days));
    }
}

contract FeeInvariantTest is KeelTest {
    using StateLibrary for IPoolManager;
    FeeHandler private handler;
    KeelV2Token private token;
    bytes32 private id;
    KeelV2Factory.LaunchInfo private info;

    function setUp() public override {
        super.setUp();
        PoolKey memory key;
        (token, id, key) = _launch(address(0), 500);
        info = factory.launchInfo(address(token));
        handler = new FeeHandler(token, hook, factory, router, key, trader, creator, team);
        vm.deal(address(handler), 1000 ether);
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = FeeHandler.buy.selector;
        selectors[1] = FeeHandler.sell.selector;
        selectors[2] = FeeHandler.claim.selector;
        selectors[3] = FeeHandler.transferCreator.selector;
        selectors[4] = FeeHandler.transferTeam.selector;
        selectors[5] = FeeHandler.lower.selector;
        selectors[6] = FeeHandler.advance.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariant_feesFullyBackedAndExactlyAttributed() public view {
        uint256 attributed = hook.creatorFees(address(token), creator)
            + hook.creatorFees(address(token), handler.secondCreator()) + hook.teamFees(address(0), team)
            + hook.teamFees(address(0), handler.secondTeam());
        assertEq(hook.totalUnclaimed(address(0)), attributed);
        assertEq(address(hook).balance, attributed);
    }

    function invariant_fixedSupplyAndLockedPosition() public view {
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(manager)) + token.balanceOf(trader), 1e27);
        assertEq(token.balanceOf(address(factory)), 0);
        assertEq(token.balanceOf(address(router)), 0);
        (uint128 position,,) = manager.getPositionInfo(
            PoolId.wrap(id), address(factory), info.tickLower, info.tickUpper, bytes32(0)
        );
        assertEq(position, info.liquidity);
    }
}
