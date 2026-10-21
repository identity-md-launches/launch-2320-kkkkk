// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {KeelTest} from "./KeelTest.sol";
import {Router, IERC20Test} from "./Router.sol";
import {MockWETH, MockV3Pool, LiquidityHelper} from "./RouterMocks.sol";
import {KeelHeart} from "../../src/KeelHeart.sol";
import {KeelV2Router} from "../../src/KeelV2Router.sol";
import {KeelV2Token} from "../../src/KeelV2Token.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @dev Production router wired into the factory, a heart, and one pool per route type:
///      ETH (NATIVE), USDC (v4 ETH/USDC pool), BTC (mock v3 WETH/BTC pool).
abstract contract RouterTest is KeelTest {
    KeelHeart internal heart;
    KeelV2Router internal kr;
    MockWETH internal weth;
    LiquidityHelper internal lp;
    Router internal spoofRouter;
    MockV3Pool internal btcPool;
    PoolKey internal usdcKey;
    KeelV2Token internal ethToken;
    KeelV2Token internal usdcToken;
    KeelV2Token internal btcToken;
    address internal buyer = address(0x20001);
    address internal other = address(0x20002);
    int24 internal constant USDC_TICK = -196260;

    function setUp() public virtual override {
        super.setUp();
        weth = new MockWETH();
        lp = new LiquidityHelper(manager);
        spoofRouter = new Router(manager);
        heart = new KeelHeart(address(hook), owner);
        kr = new KeelV2Router(manager, address(factory), hook, address(weth), owner);
        vm.startPrank(owner);
        factory.setRouter(address(kr));
        factory.setHeart(address(heart));
        heart.addQuote(address(0));
        heart.addQuote(address(usdc));
        heart.setMinBuy(address(0), 0.001 ether);
        heart.setMinBuy(address(usdc), 1e6);
        vm.stopPrank();

        // v4 ETH/USDC at ~3000 USDC per ETH, full range, ~91 ETH + ~274k USDC.
        usdcKey =
            PoolKey(Currency.wrap(address(0)), Currency.wrap(address(usdc)), 3000, 60, IHooks(address(0)));
        _addV4Pool(usdcKey, USDC_TICK, -887220, 887220, 5e15);

        // v3 WETH/BTC at 30 ETH per BTC: 300 WETH and 10 BTC.
        btcPool = _v3Pool(address(btc), 300 ether, 10e8);

        vm.startPrank(owner);
        kr.setRoute(address(0), _native());
        kr.setRoute(address(usdc), _v4(usdcKey));
        kr.setRoute(address(btc), _v3(address(btcPool)));
        vm.stopPrank();

        (ethToken,,) = _launch(address(0), 300);
        (usdcToken,,) = _launch(address(usdc), 300);
        (btcToken,,) = _launch(address(btc), 300);
        _mature();
        vm.deal(buyer, 1000 ether);
        vm.deal(other, 1000 ether);
    }

    function _addV4Pool(PoolKey memory key, int24 tick, int24 lower, int24 upper, uint128 liquidity)
        internal
    {
        manager.initialize(key, TickMath.getSqrtPriceAtTick(tick));
        vm.deal(address(lp), 10_000 ether);
        MockQuoteLike(Currency.unwrap(key.currency1)).mint(address(lp), 1e30);
        lp.add(key, ModifyLiquidityParams(lower, upper, int256(uint256(liquidity)), bytes32(0)));
    }

    function _v3Pool(address quote, uint256 wethAmount, uint256 quoteAmount)
        internal
        returns (MockV3Pool pool)
    {
        pool = new MockV3Pool(address(weth), quote, 3000);
        vm.deal(address(this), address(this).balance + wethAmount);
        weth.deposit{value: wethAmount}();
        weth.transfer(address(pool), wethAmount);
        MockQuoteLike(quote).mint(address(pool), quoteAmount);
        pool.sync();
    }

    function _native() internal pure returns (KeelV2Router.Route memory r) {
        r.kind = KeelV2Router.RouteKind.NATIVE;
    }

    function _v4(PoolKey memory key) internal pure returns (KeelV2Router.Route memory r) {
        r.kind = KeelV2Router.RouteKind.V4;
        r.v4Key = key;
    }

    function _v3(address pool) internal pure returns (KeelV2Router.Route memory r) {
        r.kind = KeelV2Router.RouteKind.V3;
        r.v3Pool = pool;
    }

    function _deadline() internal view returns (uint256) {
        return vm.getBlockTimestamp() + 1 hours;
    }

    function _rbuy(address who, KeelV2Token token, uint256 ethIn) internal returns (uint256 out) {
        vm.prank(who);
        out = kr.buy{value: ethIn}(address(token), 0, _deadline());
    }

    function _rsell(address who, KeelV2Token token, uint256 amount) internal returns (uint256 out) {
        vm.startPrank(who);
        token.approve(address(kr), amount);
        out = kr.sell(address(token), amount, 0, _deadline());
        vm.stopPrank();
    }

    function _qbuy(address who, KeelV2Token token, uint256 ethIn) internal returns (uint256) {
        vm.prank(who);
        return kr.quoteBuy(address(token), ethIn);
    }

    function _qsell(address who, KeelV2Token token, uint256 amount) internal returns (uint256) {
        vm.prank(who);
        return kr.quoteSell(address(token), amount);
    }

    function _lastBuyer() internal view returns (address who) {
        (,, who,) = heart.state();
    }

    function _assertRouterEmpty() internal view {
        address r = address(kr);
        assertEq(r.balance, 0, "router ETH");
        assertEq(weth.balanceOf(r), 0, "router WETH");
        assertEq(usdc.balanceOf(r), 0, "router USDC");
        assertEq(btc.balanceOf(r), 0, "router BTC");
        assertEq(dai.balanceOf(r), 0, "router DAI");
        assertEq(ethToken.balanceOf(r), 0, "router ETH-pool token");
        assertEq(usdcToken.balanceOf(r), 0, "router USDC-pool token");
        assertEq(btcToken.balanceOf(r), 0, "router BTC-pool token");
    }

    function _tokens() internal view returns (KeelV2Token[3] memory list) {
        list = [ethToken, usdcToken, btcToken];
    }
}

interface MockQuoteLike {
    function mint(address to, uint256 amount) external;
}
