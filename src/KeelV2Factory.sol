// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {KeelV2Token} from "./KeelV2Token.sol";
import {KeelV2Hook} from "./KeelV2Hook.sol";
import {IRulesModule} from "./interfaces/IRulesModule.sol";
import {IQuoteToken} from "./libraries/QuoteTransfer.sol";
import {Guard} from "./libraries/Guard.sol";

contract KeelV2Factory is Guard {
    using PoolIdLibrary for PoolKey;

    error NotOwner();
    error NotPendingOwner();
    error InvalidAddress();
    error OnlyBootstrap();
    error AlreadyInitialized();
    error NotConfigured();
    error InvalidModule();
    error LaunchesPaused();
    error QuoteNotAllowed();
    error UnsupportedQuote();
    error InvalidTicks();
    error InvalidDecay();
    error InvalidRate();
    error InvalidMetadata();
    error OnlyPoolManager();
    error InvalidCallback();
    error InvalidLiquidity();
    error AlreadySet();

    int24 public constant TICK_SPACING = 60;
    int24 public constant MAX_TICK = 887220;
    uint256 public constant SUPPLY = 1_000_000_000 ether;
    IPoolManager public immutable poolManager;
    address private immutable _bootstrap;
    address public owner;
    address public pendingOwner;
    address public teamRecipient;
    address public takeoverContract;
    KeelV2Hook public hook;
    address public currentModule;
    uint32 public decaySeconds = 120;
    bool public launchesPaused;
    bool private _unlocking;

    struct QuoteConfig {
        bool enabled;
        uint8 decimals;
        int24 minStartTick;
        int24 maxStartTick;
    }

    struct LaunchInfo {
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 liquidityTokens;
        uint256 lockedDust;
        string metadata;
    }
    mapping(address => QuoteConfig) public quotes;
    mapping(address => LaunchInfo) private _launches;

    event OwnershipTransferStarted(address indexed previousOwner, address indexed pendingOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event Initialized(address indexed hook, address indexed module);
    event LaunchPauseChanged(bool paused);
    event QuoteConfigured(
        address indexed quote, bool enabled, uint8 decimals, int24 minStartTick, int24 maxStartTick
    );
    event DecayChanged(uint32 decaySeconds);
    event ModuleRegistered(address indexed module);
    event TeamRecipientChanged(address indexed previousRecipient, address indexed newRecipient);
    event TakeoverContractSet(address indexed takeoverContract);
    event Launched(
        address indexed token,
        bytes32 indexed poolId,
        address indexed creator,
        address quote,
        int24 startTick,
        uint16 baseFeeBps,
        string metadata
    );
    event LiquidityLocked(
        address indexed token, uint128 liquidity, uint256 liquidityTokens, uint256 lockedDust
    );

    constructor(IPoolManager manager_, address owner_, address teamRecipient_) {
        if (address(manager_) == address(0) || owner_ == address(0) || teamRecipient_ == address(0)) {
            revert InvalidAddress();
        }
        poolManager = manager_;
        owner = owner_;
        teamRecipient = teamRecipient_;
        _bootstrap = msg.sender;
        emit OwnershipTransferred(address(0), owner_);
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @dev One-time atomic deployer wiring. The bootstrap has no ongoing role or ownership.
    function initialize(KeelV2Hook hook_, address module_) external {
        if (msg.sender != _bootstrap) revert OnlyBootstrap();
        if (address(hook) != address(0)) revert AlreadyInitialized();
        if (hook_.factory() != address(this) || address(hook_.poolManager()) != address(poolManager)) {
            revert InvalidAddress();
        }
        hook = hook_;
        _setModule(module_);
        emit Initialized(address(hook_), module_);
    }

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

    function setLaunchesPaused(bool paused) external onlyOwner {
        launchesPaused = paused;
        emit LaunchPauseChanged(paused);
    }

    /// @notice Owner attests to standard fixed-balance transfers. Known taxed/rebasing quotes are rejected.
    /// @dev No generic on-chain introspection can establish arbitrary token semantics or prevent later upgrades.
    function configureQuote(
        address quote,
        bool enabled,
        int24 minStartTick,
        int24 maxStartTick,
        bool hasTransferFee,
        bool rebases
    ) external onlyOwner {
        if (hasTransferFee || rebases) revert UnsupportedQuote();
        if (
            minStartTick > maxStartTick || minStartTick <= -MAX_TICK || maxStartTick >= MAX_TICK
                || minStartTick % TICK_SPACING != 0 || maxStartTick % TICK_SPACING != 0
        ) revert InvalidTicks();
        uint8 decimals = quotes[quote].decimals;
        if (enabled) {
            decimals = quote == address(0) ? 18 : IQuoteToken(quote).decimals();
            if (decimals != 6 && decimals != 8 && decimals != 18) revert UnsupportedQuote();
        }
        quotes[quote] = QuoteConfig(enabled, decimals, minStartTick, maxStartTick);
        emit QuoteConfigured(quote, enabled, decimals, minStartTick, maxStartTick);
    }

    function setDecaySeconds(uint32 seconds_) external onlyOwner {
        if (seconds_ < 30 || seconds_ > 600) revert InvalidDecay();
        decaySeconds = seconds_;
        emit DecayChanged(seconds_);
    }

    function registerModule(address module_) external onlyOwner {
        if (address(hook) == address(0)) revert NotConfigured();
        _setModule(module_);
    }

    function setTeamRecipient(address next) external onlyOwner {
        if (next == address(0)) revert InvalidAddress();
        address previous = teamRecipient;
        teamRecipient = next;
        emit TeamRecipientChanged(previous, next);
    }

    function setTakeoverContract(address takeover) external onlyOwner {
        if (takeoverContract != address(0)) revert AlreadySet();
        if (takeover == address(0) || takeover.code.length == 0) revert InvalidAddress();
        takeoverContract = takeover;
        emit TakeoverContractSet(takeover);
    }

    function launch(
        string calldata name,
        string calldata symbol,
        string calldata metadata,
        address quote,
        int24 startTick,
        uint16 baseFeeBps
    ) external nonReentrant returns (address token, bytes32 poolId) {
        if (launchesPaused) revert LaunchesPaused();
        if (address(hook) == address(0) || currentModule == address(0)) revert NotConfigured();
        QuoteConfig memory config = quotes[quote];
        if (!config.enabled) revert QuoteNotAllowed();
        if (
            startTick < config.minStartTick || startTick > config.maxStartTick
                || startTick % TICK_SPACING != 0
        ) revert InvalidTicks();
        if (baseFeeBps < 100 || baseFeeBps > 500) revert InvalidRate();
        if (
            bytes(name).length == 0 || bytes(name).length > 64 || bytes(symbol).length == 0
                || bytes(symbol).length > 16 || bytes(metadata).length > 2048
        ) revert InvalidMetadata();
        token = address(new KeelV2Token(name, symbol));
        bool token0 = token < quote;
        PoolKey memory key = PoolKey(
            Currency.wrap(token0 ? token : quote),
            Currency.wrap(token0 ? quote : token),
            0,
            TICK_SPACING,
            IHooks(address(hook))
        );
        int24 lower = token0 ? startTick : -MAX_TICK;
        int24 upper = token0 ? MAX_TICK : -startTick;
        uint128 liquidity = _liquidity(token0, lower, upper);
        LaunchInfo storage info = _launches[token];
        info.key = key;
        info.tickLower = lower;
        info.tickUpper = upper;
        info.liquidity = liquidity;
        info.metadata = metadata;
        poolId = PoolId.unwrap(key.toId());
        hook.registerPool(key, token, quote, msg.sender, currentModule, baseFeeBps, decaySeconds);
        poolManager.initialize(key, TickMath.getSqrtPriceAtTick(token0 ? startTick : -startTick));
        _unlocking = true;
        poolManager.unlock(abi.encode(token));
        _unlocking = false;
        emit Launched(token, poolId, msg.sender, quote, startTick, baseFeeBps, metadata);
    }

    function launchInfo(address token) external view returns (LaunchInfo memory) {
        return _launches[token];
    }

    /// @dev The sole liquidity path. There is no function to remove, poke, transfer, or approve the position.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        if (!_unlocking) revert InvalidCallback();
        _unlocking = false;
        address token = abi.decode(data, (address));
        LaunchInfo storage info = _launches[token];
        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            info.key,
            ModifyLiquidityParams(
                info.tickLower, info.tickUpper, int256(uint256(info.liquidity)), bytes32(0)
            ),
            ""
        );
        bool token0 = Currency.unwrap(info.key.currency0) == token;
        int128 tokenDelta = token0 ? delta.amount0() : delta.amount1();
        int128 quoteDelta = token0 ? delta.amount1() : delta.amount0();
        if (tokenDelta >= 0 || quoteDelta != 0) revert InvalidLiquidity();
        uint256 used = uint256(-int256(tokenDelta));
        if (used > SUPPLY) revert InvalidLiquidity();
        uint256 dust = SUPPLY - used;
        info.liquidityTokens = used;
        info.lockedDust = dust;
        poolManager.sync(Currency.wrap(token));
        if (!KeelV2Token(token).transfer(address(poolManager), SUPPLY)) revert InvalidLiquidity();
        poolManager.settle();
        // Integer liquidity cannot represent an arbitrary exact token amount. Clear the remainder
        // permanently into PoolManager; every supply unit leaves the factory, and none is withdrawable.
        if (dust != 0) poolManager.clear(Currency.wrap(token), dust);
        emit LiquidityLocked(token, info.liquidity, used, dust);
        return "";
    }

    function _setModule(address module_) private {
        if (module_.code.length == 0 || IRulesModule(module_).hook() != address(hook)) {
            revert InvalidModule();
        }
        currentModule = module_;
        emit ModuleRegistered(module_);
    }

    function _liquidity(bool token0, int24 lower, int24 upper) private pure returns (uint128) {
        uint160 a = TickMath.getSqrtPriceAtTick(lower);
        uint160 b = TickMath.getSqrtPriceAtTick(upper);
        uint256 value = token0
            ? FullMath.mulDiv(SUPPLY, FullMath.mulDiv(a, b, 1 << 96), b - a)
            : FullMath.mulDiv(SUPPLY, 1 << 96, b - a);
        if (value == 0 || value > uint256(uint128(type(int128).max))) revert InvalidLiquidity();
        return uint128(value);
    }
}
