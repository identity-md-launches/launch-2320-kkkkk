// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {KeelV2Hook} from "./KeelV2Hook.sol";
import {Guard} from "./libraries/Guard.sol";
import {QuoteTransfer} from "./libraries/QuoteTransfer.sol";

interface IWETH9 {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
    function balanceOf(address account) external view returns (uint256);
}

interface IUniswapV3PoolMinimal {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);
}

interface IKeelFactoryRouting {
    function hook() external view returns (address);
    function poolManager() external view returns (address);
    function quotes(address quote)
        external
        view
        returns (bool enabled, uint8 decimals, int24 minStartTick, int24 maxStartTick);
}

/// @notice Immutable ETH-in / ETH-out router for Keel v2 pools. Buyers never hold the quote.
/// @dev Buy: ETH -> quote (route) -> token (Keel pool). Sell: token -> quote (Keel pool) -> ETH (route).
///      Holds no balance between transactions. The owner only manages routes and the v4 hook allowlist.
contract KeelV2Router is Guard, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    enum RouteKind {
        NONE,
        NATIVE,
        V4,
        V3
    }

    /// @notice Owner input for `setRoute`. Unused fields of a kind must be zero.
    struct Route {
        RouteKind kind;
        PoolKey v4Key;
        address v3Pool;
    }

    struct StoredRoute {
        RouteKind kind;
        bool wethIsToken0;
        address v3Pool;
        PoolKey v4Key;
    }

    struct Ctx {
        address token;
        address quote;
        bool quoteIs0;
        PoolKey keel;
        RouteKind kind;
        PoolKey v4Key;
        address v3Pool;
        bool wethIsToken0;
    }

    struct Op {
        bool isBuy;
        bool simulate;
        bool settleInput;
        address user;
        uint256 amount;
        Ctx ctx;
    }

    error NotOwner();
    error NotPendingOwner();
    error InvalidAddress();
    error InvalidRoute();
    error WiringMismatch();
    error QuoteNotAllowed(address quote);
    error HookNotAllowed(address hooks);
    error RouteNotSet(address quote);
    error UnknownToken(address token);
    error Expired();
    error InvalidAmount();
    error InsufficientOutput(uint256 amountOut, uint256 minimum);
    error PartialFill();
    error ZeroOutput();
    error NonStandardBalance();
    error BalanceChanged();
    error InvalidCallback();
    error OnlySelf();
    error EthTransferFailed();
    error UnexpectedEther();
    /// @notice Carries a simulation result out of a reverted call frame.
    error QuoteResult(uint256 amountOut);

    uint256 private constant _MAX_AMOUNT = uint256(uint128(type(int128).max));
    /// @dev Transient slots: armed PoolManager unlock, and the v3 pool whose callback is expected.
    uint256 private constant _UNLOCK_SLOT = 0x6b65656c2e726f757465722e756e6c6f636b;
    uint256 private constant _V3_SLOT = 0x6b65656c2e726f757465722e76332e706f6f6c;

    IPoolManager public immutable poolManager;
    address public immutable factory;
    KeelV2Hook public immutable hook;
    address public immutable weth;
    address public owner;
    address public pendingOwner;
    mapping(address => bool) public hookAllowed;
    mapping(address => StoredRoute) private _routes;

    event OwnershipTransferStarted(address indexed previousOwner, address indexed pendingOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event HookAllowlistChanged(address indexed hooks, bool allowed);
    event RouteSet(address indexed quote, RouteKind kind, bytes32 v4PoolId, address v3Pool);
    event RouteRemoved(address indexed quote);
    event Bought(address indexed buyer, address indexed token, uint256 ethIn, uint256 tokensOut);
    event Sold(address indexed seller, address indexed token, uint256 tokensIn, uint256 ethOut);

    /// @dev Makes no external call, so it runs on an empty chain. Wiring is checked in `setRoute`.
    constructor(IPoolManager manager_, address factory_, KeelV2Hook hook_, address weth_, address owner_) {
        if (
            address(manager_) == address(0) || factory_ == address(0) || address(hook_) == address(0)
                || weth_ == address(0) || owner_ == address(0)
        ) revert InvalidAddress();
        poolManager = manager_;
        factory = factory_;
        hook = hook_;
        weth = weth_;
        owner = owner_;
        emit OwnershipTransferred(address(0), owner_);
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @dev Only PoolManager (takes of ETH) and WETH (unwraps) may send ETH outside a buy.
    receive() external payable {
        if (msg.sender != address(poolManager) && msg.sender != weth) revert UnexpectedEther();
    }

    // ---------------------------------------------------------------- owner

    function transferOwnership(address next) external onlyOwner {
        if (next == address(0)) revert InvalidAddress();
        pendingOwner = next;
        emit OwnershipTransferStarted(owner, next);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        address previous = owner;
        owner = msg.sender;
        pendingOwner = address(0);
        emit OwnershipTransferred(previous, msg.sender);
    }

    /// @notice Allow or disallow a v4 hook contract for ETH/quote route pools. Starts empty.
    function setHookAllowed(address hooks, bool allowed) external onlyOwner {
        if (hooks == address(0)) revert InvalidAddress();
        hookAllowed[hooks] = allowed;
        emit HookAllowlistChanged(hooks, allowed);
    }

    /// @notice Set, replace (any kind) or remove (`kind = NONE`) the ETH leg for `quote`.
    /// @dev Never touches funds. The quote must be enabled in the factory, whose owner attests it
    ///      has no transfer fee and does not rebase; trades additionally verify every balance change.
    function setRoute(address quote, Route calldata route) external onlyOwner {
        if (route.kind == RouteKind.NONE) {
            if (_routes[quote].kind == RouteKind.NONE) revert RouteNotSet(quote);
            delete _routes[quote];
            emit RouteRemoved(quote);
            return;
        }
        IKeelFactoryRouting f = IKeelFactoryRouting(factory);
        if (f.hook() != address(hook) || f.poolManager() != address(poolManager)) revert WiringMismatch();
        (bool enabled,,,) = f.quotes(quote);
        if (!enabled) revert QuoteNotAllowed(quote);
        PoolKey calldata key = route.v4Key;
        bool emptyKey = Currency.unwrap(key.currency0) == address(0)
            && Currency.unwrap(key.currency1) == address(0) && key.fee == 0 && key.tickSpacing == 0
            && address(key.hooks) == address(0);
        StoredRoute storage stored = _routes[quote];
        bytes32 v4Id;
        if (route.kind == RouteKind.NATIVE) {
            if (quote != address(0) || !emptyKey || route.v3Pool != address(0)) revert InvalidRoute();
            delete _routes[quote];
            stored.kind = RouteKind.NATIVE;
        } else if (route.kind == RouteKind.V4) {
            if (quote == address(0) || route.v3Pool != address(0)) revert InvalidRoute();
            if (Currency.unwrap(key.currency0) != address(0) || Currency.unwrap(key.currency1) != quote) {
                revert InvalidRoute();
            }
            address hooks = address(key.hooks);
            if (hooks != address(0) && !hookAllowed[hooks]) revert HookNotAllowed(hooks);
            PoolId id = key.toId();
            (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(id);
            if (sqrtPriceX96 == 0) revert InvalidRoute();
            v4Id = PoolId.unwrap(id);
            delete _routes[quote];
            stored.kind = RouteKind.V4;
            stored.v4Key = key;
        } else {
            address pool = route.v3Pool;
            if (quote == address(0) || quote == weth || !emptyKey || pool.code.length == 0) {
                revert InvalidRoute();
            }
            address t0 = IUniswapV3PoolMinimal(pool).token0();
            address t1 = IUniswapV3PoolMinimal(pool).token1();
            if (!((t0 == weth && t1 == quote) || (t0 == quote && t1 == weth))) revert InvalidRoute();
            delete _routes[quote];
            stored.kind = RouteKind.V3;
            stored.wethIsToken0 = t0 == weth;
            stored.v3Pool = pool;
        }
        emit RouteSet(quote, route.kind, v4Id, route.v3Pool);
    }

    function routeOf(address quote) external view returns (StoredRoute memory) {
        return _routes[quote];
    }

    // ---------------------------------------------------------------- trading

    /// @notice Spend all `msg.value` ETH on `token`; tokens go to `msg.sender`, who gets heart credit.
    function buy(address token, uint256 minTokensOut, uint256 deadline)
        external
        payable
        nonReentrant
        returns (uint256 tokensOut)
    {
        if (block.timestamp > deadline) revert Expired();
        Ctx memory ctx = _context(token);
        uint256[4] memory before = _balances(ctx);
        before[0] -= msg.value;
        tokensOut = _buy(ctx, msg.value, msg.sender, false);
        if (tokensOut < minTokensOut) revert InsufficientOutput(tokensOut, minTokensOut);
        _checkBalances(ctx, before);
        emit Bought(msg.sender, token, msg.value, tokensOut);
    }

    /// @notice Sell `amountIn` of `token` pulled from `msg.sender`; ETH goes to `msg.sender`.
    function sell(address token, uint256 amountIn, uint256 minEthOut, uint256 deadline)
        external
        nonReentrant
        returns (uint256 ethOut)
    {
        if (block.timestamp > deadline) revert Expired();
        _checkAmount(amountIn);
        Ctx memory ctx = _context(token);
        uint256[4] memory before = _balances(ctx);
        QuoteTransfer.pull(token, msg.sender, amountIn);
        if (QuoteTransfer.balance(token, address(this)) != before[1] + amountIn) revert NonStandardBalance();
        ethOut = _unlockOp(Op(false, false, true, msg.sender, amountIn, ctx));
        if (ctx.kind == RouteKind.V3) IWETH9(weth).withdraw(ethOut);
        if (ethOut < minEthOut) revert InsufficientOutput(ethOut, minEthOut);
        (bool ok,) = msg.sender.call{value: ethOut}("");
        if (!ok) revert EthTransferFailed();
        _checkBalances(ctx, before);
        emit Sold(msg.sender, token, amountIn, ethOut);
    }

    // ---------------------------------------------------------------- quotes

    /// @notice Exact tokens `buy` would deliver to `msg.sender` for `ethIn` in the current state.
    /// @dev Revert-with-result simulation; call with eth_call from the buyer's address.
    function quoteBuy(address token, uint256 ethIn) external nonReentrant returns (uint256 tokensOut) {
        return _quote(abi.encodeCall(this.simulate, (true, token, ethIn, msg.sender)));
    }

    /// @notice Exact ETH `sell` would deliver for `amountIn` tokens in the current state.
    function quoteSell(address token, uint256 amountIn) external nonReentrant returns (uint256 ethOut) {
        return _quote(abi.encodeCall(this.simulate, (false, token, amountIn, msg.sender)));
    }

    /// @notice Self-call only. Always reverts, with `QuoteResult` on success.
    function simulate(bool isBuy, address token, uint256 amount, address user) external {
        if (msg.sender != address(this)) revert OnlySelf();
        Ctx memory ctx = _context(token);
        if (isBuy) {
            _buy(ctx, amount, user, true);
        } else {
            _checkAmount(amount);
            _unlockOp(Op(false, true, false, user, amount, ctx));
        }
        revert InvalidCallback();
    }

    // ---------------------------------------------------------------- callbacks

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager) || _tload(_UNLOCK_SLOT) == 0) revert InvalidCallback();
        _tstore(_UNLOCK_SLOT, 0);
        Op memory op = abi.decode(data, (Op));
        uint256 out = op.isBuy ? _executeBuy(op) : _executeSell(op);
        if (op.simulate) revert QuoteResult(out);
        return abi.encode(out);
    }

    /// @dev Accepted only from the exact v3 pool this router is calling right now, once.
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
        address pool = address(uint160(_tload(_V3_SLOT)));
        if (pool == address(0) || msg.sender != pool) revert InvalidCallback();
        _tstore(_V3_SLOT, 0);
        (bool wethIn, uint256 amountIn, uint256 outBefore, bool continueBuy, Op memory next) =
            abi.decode(data, (bool, uint256, uint256, bool, Op));
        bool zeroForOne = wethIn == next.ctx.wethIsToken0;
        int256 owed = zeroForOne ? amount0Delta : amount1Delta;
        int256 received = zeroForOne ? amount1Delta : amount0Delta;
        if (owed != int256(amountIn)) revert PartialFill();
        if (continueBuy) {
            // Simulated buy: the quote has really arrived; run the Keel leg on it and revert with the result.
            if (received >= 0) revert ZeroOutput();
            uint256 quoteIn = uint256(-received);
            if (QuoteTransfer.balance(next.ctx.quote, address(this)) != outBefore + quoteIn) {
                revert NonStandardBalance();
            }
            next.amount = quoteIn;
            _unlockOp(next);
            revert InvalidCallback();
        }
        QuoteTransfer.pay(wethIn ? weth : next.ctx.quote, pool, amountIn);
    }

    // ---------------------------------------------------------------- internals

    function _buy(Ctx memory ctx, uint256 ethIn, address user, bool simulated) private returns (uint256) {
        _checkAmount(ethIn);
        if (ctx.kind == RouteKind.V3) {
            if (!simulated) IWETH9(weth).deposit{value: ethIn}();
            Op memory next = Op(true, simulated, true, user, 0, ctx);
            uint256 quoteIn = _v3Swap(ctx, true, ethIn, simulated, next);
            next.amount = quoteIn;
            return _unlockOp(next);
        }
        return _unlockOp(Op(true, simulated, !simulated, user, ethIn, ctx));
    }

    function _executeBuy(Op memory op) private returns (uint256 tokensOut) {
        Ctx memory c = op.ctx;
        uint256 quoteIn = op.amount;
        if (c.kind == RouteKind.V3) {
            _settleToken(c.quote, quoteIn);
        } else {
            // Settle input before any take: quotes may have no other PoolManager inventory.
            if (op.settleInput) {
                poolManager.sync(Currency.wrap(address(0)));
                poolManager.settle{value: quoteIn}();
            }
            if (c.kind == RouteKind.V4) quoteIn = _swapExact(c.v4Key, true, quoteIn, "");
        }
        tokensOut = _swapExact(c.keel, c.quoteIs0, quoteIn, abi.encode(op.user));
        if (!op.simulate) poolManager.take(Currency.wrap(c.token), op.user, tokensOut);
    }

    function _executeSell(Op memory op) private returns (uint256 ethOut) {
        Ctx memory c = op.ctx;
        if (op.settleInput) _settleToken(c.token, op.amount);
        uint256 quoteOut = _swapExact(c.keel, !c.quoteIs0, op.amount, "");
        if (c.kind == RouteKind.V3) {
            uint256 quoteBefore = QuoteTransfer.balance(c.quote, address(this));
            poolManager.take(Currency.wrap(c.quote), address(this), quoteOut);
            if (QuoteTransfer.balance(c.quote, address(this)) != quoteBefore + quoteOut) {
                revert NonStandardBalance();
            }
            // WETH stays here until the caller unwraps it after the unlock.
            return _v3Swap(c, false, quoteOut, false, op);
        }
        ethOut = c.kind == RouteKind.V4 ? _swapExact(c.v4Key, false, quoteOut, "") : quoteOut;
        if (!op.simulate) poolManager.take(Currency.wrap(address(0)), address(this), ethOut);
    }

    function _settleToken(address currency, uint256 amount) private {
        poolManager.sync(Currency.wrap(currency));
        QuoteTransfer.pay(currency, address(poolManager), amount);
        if (poolManager.settle() != amount) revert NonStandardBalance();
    }

    /// @dev Exact-input v4 swap that must consume all input and produce a positive output.
    function _swapExact(PoolKey memory key, bool zeroForOne, uint256 amountIn, bytes memory hookData)
        private
        returns (uint256)
    {
        BalanceDelta delta = poolManager.swap(
            key,
            SwapParams(
                zeroForOne,
                -int256(amountIn),
                zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            hookData
        );
        int128 spent = zeroForOne ? delta.amount0() : delta.amount1();
        int128 received = zeroForOne ? delta.amount1() : delta.amount0();
        if (int256(spent) != -int256(amountIn)) revert PartialFill();
        if (received <= 0) revert ZeroOutput();
        return uint256(uint128(received));
    }

    /// @dev Exact-input v3 swap of WETH -> quote (`wethIn`) or quote -> WETH, received by this router.
    function _v3Swap(Ctx memory c, bool wethIn, uint256 amountIn, bool continueBuy, Op memory next)
        private
        returns (uint256 amountOut)
    {
        address pool = c.v3Pool;
        address tokenOut = wethIn ? c.quote : weth;
        bool zeroForOne = wethIn == c.wethIsToken0;
        uint256 outBefore = QuoteTransfer.balance(tokenOut, address(this));
        _tstore(_V3_SLOT, uint256(uint160(pool)));
        (int256 amount0, int256 amount1) = IUniswapV3PoolMinimal(pool)
            .swap(
                address(this),
                zeroForOne,
                int256(amountIn),
                zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1,
                abi.encode(wethIn, amountIn, outBefore, continueBuy, next)
            );
        if (_tload(_V3_SLOT) != 0) revert InvalidCallback();
        int256 spent = zeroForOne ? amount0 : amount1;
        int256 received = zeroForOne ? amount1 : amount0;
        if (spent != int256(amountIn)) revert PartialFill();
        if (received >= 0) revert ZeroOutput();
        amountOut = uint256(-received);
        if (QuoteTransfer.balance(tokenOut, address(this)) != outBefore + amountOut) {
            revert NonStandardBalance();
        }
    }

    function _unlockOp(Op memory op) private returns (uint256) {
        _tstore(_UNLOCK_SLOT, 1);
        bytes memory result = poolManager.unlock(abi.encode(op));
        return abi.decode(result, (uint256));
    }

    function _quote(bytes memory call) private returns (uint256) {
        (bool ok, bytes memory reason) = address(this).call(call);
        if (!ok && reason.length == 36 && bytes4(reason) == QuoteResult.selector) {
            uint256 amountOut;
            assembly ("memory-safe") {
                amountOut := mload(add(reason, 36))
            }
            return amountOut;
        }
        if (ok) revert InvalidCallback();
        assembly ("memory-safe") {
            revert(add(reason, 32), mload(reason))
        }
    }

    /// @dev Derives the Keel pool key (fee 0, tick spacing 60, this hook: the only shape the hook
    ///      registers) and proves it against `hook.poolIdOf(token)`; equal to `factory.launchInfo(token).key`.
    function _context(address token) private view returns (Ctx memory c) {
        bytes32 id = hook.poolIdOf(token);
        if (id == bytes32(0)) revert UnknownToken(token);
        address quote = hook.poolInfo(id).quote;
        c.token = token;
        c.quote = quote;
        c.quoteIs0 = quote < token;
        c.keel = PoolKey(
            Currency.wrap(c.quoteIs0 ? quote : token),
            Currency.wrap(c.quoteIs0 ? token : quote),
            0,
            60,
            IHooks(address(hook))
        );
        if (PoolId.unwrap(c.keel.toId()) != id) revert UnknownToken(token);
        StoredRoute storage r = _routes[quote];
        c.kind = r.kind;
        if (c.kind == RouteKind.NONE) revert RouteNotSet(quote);
        if (c.kind == RouteKind.V4) {
            c.v4Key = r.v4Key;
            address hooks = address(c.v4Key.hooks);
            if (hooks != address(0) && !hookAllowed[hooks]) revert HookNotAllowed(hooks);
        } else if (c.kind == RouteKind.V3) {
            c.v3Pool = r.v3Pool;
            c.wethIsToken0 = r.wethIsToken0;
        }
    }

    function _checkAmount(uint256 amount) private pure {
        if (amount == 0 || amount > _MAX_AMOUNT) revert InvalidAmount();
    }

    /// @dev [ETH, token, quote, WETH] held by this router.
    function _balances(Ctx memory c) private view returns (uint256[4] memory b) {
        b[0] = address(this).balance;
        b[1] = QuoteTransfer.balance(c.token, address(this));
        if (c.quote != address(0)) b[2] = QuoteTransfer.balance(c.quote, address(this));
        if (c.kind == RouteKind.V3) b[3] = QuoteTransfer.balance(weth, address(this));
    }

    function _checkBalances(Ctx memory c, uint256[4] memory before) private view {
        uint256[4] memory afterwards = _balances(c);
        for (uint256 i; i < 4; ++i) {
            if (afterwards[i] != before[i]) revert BalanceChanged();
        }
    }

    function _tstore(uint256 slot, uint256 value) private {
        assembly ("memory-safe") {
            tstore(slot, value)
        }
    }

    function _tload(uint256 slot) private view returns (uint256 value) {
        assembly ("memory-safe") {
            value := tload(slot)
        }
    }
}
