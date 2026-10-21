// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {IRulesModule, IKeelGovernance, IPulseSource} from "./interfaces/IRulesModule.sol";
import {IKeelHeart} from "./interfaces/IKeelHeart.sol";
import {Guard} from "./libraries/Guard.sol";
import {QuoteTransfer} from "./libraries/QuoteTransfer.sol";
import {PulseMath} from "./libraries/PulseMath.sol";

/// @notice Immutable shared hook. All fee assets and beneficiary credits live here.
contract KeelV2Hook is Guard, IPulseSource {
    using PoolIdLibrary for PoolKey;

    error OnlyPoolManager();
    error OnlyFactory();
    error OnlyModule();
    error UnknownPool();
    error AlreadyRegistered();
    error NotCreator();
    error NotTakeover();
    error CreatorStillActive();
    error InvalidAddress();
    error InvalidPool();
    error InvalidRate();
    error ExactInputOnly();
    error InvalidAmount();
    error PartialBuy();
    error NoFees();
    error InsolventQuote();

    uint256 public constant BPS = 10_000;
    uint16 public constant START_RATE = 9900;
    uint256 public constant INACTIVITY = 30 days;
    uint160 public constant PERMISSION_FLAGS =
        (1 << 12) | (1 << 11) | (1 << 7) | (1 << 6) | (1 << 3) | (1 << 2);
    /// @notice Hard ceiling on the gas a heart notification may consume.
    uint256 public constant HEART_GAS = 200_000;
    uint256 public constant ONE_BEAT = 1e18;
    IPoolManager public immutable poolManager;
    address public immutable factory;

    struct Pool {
        address token;
        address quote;
        address module;
        address creator;
        uint256 launchedAt;
        uint256 lastActive;
        uint32 decaySeconds;
        uint16 launchBaseRate;
    }
    mapping(bytes32 => Pool) private _pools;
    mapping(address => bytes32) public poolIdOf;
    mapping(address => mapping(address => uint256)) public creatorFees;
    mapping(address => mapping(address => uint256)) public teamFees;
    mapping(address => uint256) public totalUnclaimed;
    mapping(bytes32 => uint256) public creatorEarned;
    mapping(bytes32 => uint256) public teamEarned;

    struct PendingBuy {
        uint128 gross;
        uint128 net;
    }

    struct Pulse {
        uint128 pulse;
        uint64 updatedAt;
    }

    mapping(bytes32 => PendingBuy) private _pendingBuys;
    mapping(bytes32 => Pulse) private _pulses;

    event HeartCallFailed(bytes32 indexed poolId);
    event PoolRegistered(
        bytes32 indexed poolId,
        address indexed token,
        address indexed creator,
        address quote,
        address module,
        uint16 baseFeeBps,
        uint32 decaySeconds
    );
    event FeesAccrued(
        bytes32 indexed poolId,
        address indexed creator,
        address indexed team,
        uint256 creatorAmount,
        uint256 teamAmount
    );
    event CreatorClaimed(
        address indexed token, address indexed beneficiary, address indexed to, uint256 amount
    );
    event TeamClaimed(address indexed quote, address indexed beneficiary, address indexed to, uint256 amount);
    event CreatorTransferred(
        address indexed token, address indexed previousCreator, address indexed newCreator, bool takeover
    );
    event CreatorActivity(address indexed token, address indexed creator, uint256 timestamp);

    constructor(IPoolManager manager_, address factory_) {
        if (address(manager_) == address(0) || factory_ == address(0)) revert InvalidAddress();
        poolManager = manager_;
        factory = factory_;
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        _;
    }

    receive() external payable onlyPoolManager {}

    function getHookPermissions() public pure returns (Hooks.Permissions memory p) {
        p.afterInitialize = true;
        p.beforeAddLiquidity = true;
        p.beforeSwap = true;
        p.afterSwap = true;
        p.beforeSwapReturnDelta = true;
        p.afterSwapReturnDelta = true;
    }

    function poolInfo(bytes32 id) external view returns (Pool memory) {
        return _pool(id);
    }

    function registerPool(
        PoolKey calldata key,
        address token,
        address quote,
        address creator,
        address module,
        uint16 baseFeeBps,
        uint32 decaySeconds
    ) external nonReentrant {
        if (msg.sender != factory) revert OnlyFactory();
        if (token == address(0) || creator == address(0) || module == address(0)) revert InvalidAddress();
        if (address(key.hooks) != address(this) || key.fee != 0 || token == quote || key.tickSpacing != 60) {
            revert InvalidPool();
        }
        if (!((Currency.unwrap(key.currency0) == token && Currency.unwrap(key.currency1) == quote)
                    || (Currency.unwrap(key.currency1) == token && Currency.unwrap(key.currency0) == quote))) revert InvalidPool();
        if (baseFeeBps < 100 || baseFeeBps > 500 || decaySeconds < 30 || decaySeconds > 600) {
            revert InvalidRate();
        }
        bytes32 id = PoolId.unwrap(key.toId());
        if (_pools[id].token != address(0) || poolIdOf[token] != bytes32(0)) revert AlreadyRegistered();
        _pools[id] =
            Pool(token, quote, module, creator, block.timestamp, block.timestamp, decaySeconds, baseFeeBps);
        poolIdOf[token] = id;
        IRulesModule(module).initialize(id, baseFeeBps);
        emit PoolRegistered(id, token, creator, quote, module, baseFeeBps, decaySeconds);
    }

    function afterInitialize(address sender, PoolKey calldata key, uint160, int24)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        if (sender != factory) revert OnlyFactory();
        _pool(PoolId.unwrap(key.toId()));
        return IHooks.afterInitialize.selector;
    }

    function beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        bytes calldata
    ) external view onlyPoolManager returns (bytes4) {
        if (sender != factory) revert OnlyFactory();
        _pool(PoolId.unwrap(key.toId()));
        return IHooks.beforeAddLiquidity.selector;
    }

    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata context)
        external
        onlyPoolManager
        nonReentrant
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (params.amountSpecified >= 0) revert ExactInputOnly();
        if (params.amountSpecified < -int256(type(int128).max)) revert InvalidAmount();
        bytes32 id = PoolId.unwrap(key.toId());
        Pool storage pool = _pool(id);
        bool isBuy = _isBuy(pool, key, params.zeroForOne);
        if (!isBuy) return (IHooks.beforeSwap.selector, toBeforeSwapDelta(0, 0), 0);
        (uint16 base, uint16 effective) = _rates(id, pool, true, context);
        uint256 amount = uint256(-params.amountSpecified);
        (uint256 fee, uint256 creatorAmount) = splitFee(amount, base, effective);
        if (fee >= amount) revert InvalidAmount();
        _pendingBuys[id] = PendingBuy(uint128(amount), uint128(amount - fee));
        _accrue(id, pool, fee, creatorAmount);
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(int128(int256(fee)), 0), 0);
    }

    function afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata context
    ) external onlyPoolManager nonReentrant returns (bytes4, int128) {
        bytes32 id = PoolId.unwrap(key.toId());
        Pool storage pool = _pool(id);
        bool isBuy = _isBuy(pool, key, params.zeroForOne);
        bool quoteIsZero = Currency.unwrap(key.currency0) == pool.quote;
        int128 quoteDelta = quoteIsZero ? delta.amount0() : delta.amount1();
        if (isBuy) {
            // Reject partial fills: the input fee must never be charged on unspent quote.
            // Snapshot before the swap: a future module may quote from changing pool state.
            PendingBuy memory pending = _pendingBuys[id];
            delete _pendingBuys[id];
            if (pending.net == 0 || int256(quoteDelta) != -int256(uint256(pending.net))) revert PartialBuy();
            int128 tokenDelta = quoteIsZero ? delta.amount1() : delta.amount0();
            _beat(id, pool, sender, pending.gross, tokenDelta > 0 ? uint256(uint128(tokenDelta)) : 0, context);
            return (IHooks.afterSwap.selector, 0);
        }
        if (quoteDelta <= 0) return (IHooks.afterSwap.selector, 0);
        (uint16 base, uint16 effective) = _rates(id, pool, false, context);
        (uint256 total, uint256 creatorAmount) = splitFee(uint128(quoteDelta), base, effective);
        _accrue(id, pool, total, creatorAmount);
        return (IHooks.afterSwap.selector, int128(int256(total)));
    }

    /// @notice Quotes raw currency units; no decimal normalization or price oracle is involved.
    function splitFee(uint256 amount, uint16 base, uint16 effective)
        public
        pure
        returns (uint256 total, uint256 creatorAmount)
    {
        if (base < 100 || base > 500 || effective < base || effective > START_RATE) revert InvalidRate();
        total = FullMath.mulDivRoundingUp(amount, effective, BPS);
        uint256 baseAmount = FullMath.mulDivRoundingUp(amount, base, BPS);
        creatorAmount = FullMath.mulDiv(baseAmount, 80, 100);
    }

    function rates(bytes32 id, bool isBuy, bytes calldata context)
        external
        view
        returns (uint16 base, uint16 effective)
    {
        return _rates(id, _pool(id), isBuy, context);
    }

    /// @inheritdoc IPulseSource
    function pulseOf(bytes32 id) public view returns (uint256) {
        Pulse memory pulse = _pulses[id];
        return PulseMath.decay(pulse.pulse, block.timestamp - pulse.updatedAt);
    }

    function pulseInfo(bytes32 id) external view returns (uint128 pulse, uint64 updatedAt) {
        Pulse memory stored = _pulses[id];
        return (stored.pulse, stored.updatedAt);
    }

    function transferCreator(address token, address newCreator) external nonReentrant {
        Pool storage pool = _pool(poolIdOf[token]);
        _checkCreator(pool, msg.sender);
        _setCreator(pool, newCreator, false);
    }

    function ping(address token) external nonReentrant {
        Pool storage pool = _pool(poolIdOf[token]);
        _checkCreator(pool, msg.sender);
        _touch(pool);
    }

    function creatorAction(bytes32 id, address actor) external nonReentrant {
        Pool storage pool = _pool(id);
        if (msg.sender != pool.module) revert OnlyModule();
        _checkCreator(pool, actor);
        _touch(pool);
    }

    function setCreatorByTakeover(address token, address newCreator) external nonReentrant {
        address takeover = IKeelGovernance(factory).takeoverContract();
        if (takeover == address(0) || msg.sender != takeover) revert NotTakeover();
        Pool storage pool = _pool(poolIdOf[token]);
        if (block.timestamp <= pool.lastActive + INACTIVITY) revert CreatorStillActive();
        _setCreator(pool, newCreator, true);
    }

    function claimCreator(address token, address to) external nonReentrant {
        Pool storage pool = _pool(poolIdOf[token]);
        uint256 amount = creatorFees[token][msg.sender];
        if (amount == 0) revert NoFees();
        creatorFees[token][msg.sender] = 0;
        totalUnclaimed[pool.quote] -= amount;
        if (msg.sender == pool.creator) _touch(pool);
        _pay(pool.quote, to, amount);
        emit CreatorClaimed(token, msg.sender, to, amount);
    }

    function claimTeam(address quote, address to) external nonReentrant {
        uint256 amount = teamFees[quote][msg.sender];
        if (amount == 0) revert NoFees();
        teamFees[quote][msg.sender] = 0;
        totalUnclaimed[quote] -= amount;
        _pay(quote, to, amount);
        emit TeamClaimed(quote, msg.sender, to, amount);
    }

    function _rates(bytes32 id, Pool storage pool, bool isBuy, bytes calldata context)
        private
        view
        returns (uint16 base, uint16 effective)
    {
        base = IRulesModule(pool.module).feeBps(id, isBuy, context);
        if (base < 100 || base > 500) revert InvalidRate();
        effective = base;
        uint256 elapsed = block.timestamp - pool.launchedAt;
        if (elapsed < pool.decaySeconds) {
            // Anchor the line to the launch rate. Lowering does not restart the launch clock.
            uint256 scheduled = pool.launchBaseRate
                + FullMath.mulDivRoundingUp(
                    START_RATE - pool.launchBaseRate, pool.decaySeconds - elapsed, pool.decaySeconds
                );
            if (scheduled > effective) effective = uint16(scheduled);
        }
    }

    /// @dev Pulse and heart accounting for a completed buy. Never reverts because of the heart.
    function _beat(
        bytes32 id,
        Pool storage pool,
        address sender,
        uint256 gross,
        uint256 tokensOut,
        bytes calldata context
    ) private {
        address heart = IKeelGovernance(factory).heart();
        if (heart != address(0)) {
            uint256 threshold;
            try IKeelHeart(heart).minBuy(pool.quote) returns (uint256 value) {
                threshold = value;
            } catch {
                emit HeartCallFailed(id);
                return;
            }
            if (gross < threshold) return;
        }
        Pulse storage pulse = _pulses[id];
        uint256 current = PulseMath.decay(pulse.pulse, block.timestamp - pulse.updatedAt) + ONE_BEAT;
        pulse.pulse = current > type(uint128).max ? type(uint128).max : uint128(current);
        pulse.updatedAt = uint64(block.timestamp);
        // Only the configured router can name a buyer, and only with exactly one ABI-encoded address.
        if (heart == address(0) || context.length != 32 || sender != IKeelGovernance(factory).router()) {
            return;
        }
        address buyer = abi.decode(context, (address));
        try IKeelHeart(heart).onBuy{gas: HEART_GAS}(pool.token, pool.quote, buyer, gross, tokensOut) {}
        catch {
            emit HeartCallFailed(id);
        }
    }

    function _accrue(bytes32 id, Pool storage pool, uint256 fee, uint256 creatorAmount) private {
        address team = IKeelGovernance(factory).teamRecipient();
        uint256 teamAmount = fee - creatorAmount;
        creatorFees[pool.token][pool.creator] += creatorAmount;
        teamFees[pool.quote][team] += teamAmount;
        creatorEarned[id] += creatorAmount;
        teamEarned[id] += teamAmount;
        totalUnclaimed[pool.quote] += fee;
        uint256 beforeBalance = QuoteTransfer.balance(pool.quote, address(this));
        poolManager.take(Currency.wrap(pool.quote), address(this), fee);
        uint256 afterBalance = QuoteTransfer.balance(pool.quote, address(this));
        if (afterBalance != beforeBalance + fee) revert QuoteTransfer.NonStandardQuote();
        if (afterBalance < totalUnclaimed[pool.quote]) revert InsolventQuote();
        emit FeesAccrued(id, pool.creator, team, creatorAmount, teamAmount);
    }

    function _pay(address quote, address to, uint256 amount) private {
        if (to == address(0) || to == address(this)) revert InvalidAddress();
        uint256 beforeSelf = QuoteTransfer.balance(quote, address(this));
        uint256 beforeRecipient = quote == address(0) ? 0 : QuoteTransfer.balance(quote, to);
        if (beforeSelf < totalUnclaimed[quote] + amount) {
            revert InsolventQuote();
        }
        QuoteTransfer.pay(quote, to, amount);
        // Both callers hold the hook's nonReentrant lock across these exact-transfer checks.
        if (
            quote != address(0)
                && (QuoteTransfer.balance(quote, address(this)) != beforeSelf - amount
                    || QuoteTransfer.balance(quote, to) != beforeRecipient + amount)
        ) revert QuoteTransfer.NonStandardQuote();
        if (QuoteTransfer.balance(quote, address(this)) < totalUnclaimed[quote]) revert InsolventQuote();
    }

    function _isBuy(Pool storage pool, PoolKey calldata key, bool zeroForOne) private view returns (bool) {
        return (Currency.unwrap(key.currency0) == pool.quote) == zeroForOne;
    }

    function _pool(bytes32 id) private view returns (Pool storage pool) {
        pool = _pools[id];
        if (pool.token == address(0)) revert UnknownPool();
    }

    function _checkCreator(Pool storage pool, address actor) private view {
        if (actor != pool.creator) revert NotCreator();
    }

    function _touch(Pool storage pool) private {
        pool.lastActive = block.timestamp;
        emit CreatorActivity(pool.token, pool.creator, block.timestamp);
    }

    function _setCreator(Pool storage pool, address next, bool takeover) private {
        if (next == address(0)) revert InvalidAddress();
        address previous = pool.creator;
        pool.creator = next;
        _touch(pool);
        emit CreatorTransferred(pool.token, previous, next, takeover);
    }
}
