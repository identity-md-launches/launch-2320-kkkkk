// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IRulesModule, ICreatorActivity} from "./interfaces/IRulesModule.sol";

/// @notice Creator-controlled base rate shared by the rate modules. No owner, assets, delegatecalls
///         or payable functions. Concrete modules only decide how the rate maps to a fee.
abstract contract RateModuleBase is IRulesModule {
    error OnlyHook();
    error UnknownPool();
    error AlreadyInitialized();
    error InvalidRate();
    error NoPendingRaise();
    error RaiseNotReady();
    error ZeroAddress();

    uint16 public constant MIN_RATE = 100;
    uint16 public constant MAX_RATE = 500;
    uint16 public constant MAX_RAISE = 100;
    uint256 public constant RAISE_DELAY = 24 hours;
    address public immutable hook;

    struct Rate {
        uint16 current;
        uint16 pending;
        uint256 applyAfter;
    }

    mapping(bytes32 => Rate) public rates;

    event RateInitialized(bytes32 indexed poolId, uint16 rate);
    event RateLowered(bytes32 indexed poolId, uint16 rate);
    event RaiseScheduled(bytes32 indexed poolId, uint16 rate, uint256 applyAfter);
    event RaiseCancelled(bytes32 indexed poolId);
    event RaiseApplied(bytes32 indexed poolId, uint16 rate);

    constructor(address hook_) {
        if (hook_ == address(0)) revert ZeroAddress();
        hook = hook_;
    }

    function initialize(bytes32 poolId, uint16 baseFeeBps) external {
        if (msg.sender != hook) revert OnlyHook();
        if (rates[poolId].current != 0) revert AlreadyInitialized();
        _checkRate(baseFeeBps);
        rates[poolId].current = baseFeeBps;
        emit RateInitialized(poolId, baseFeeBps);
    }

    function lowerRate(bytes32 poolId, uint16 newRate) external {
        _creator(poolId);
        Rate storage rate = rates[poolId];
        _checkRate(newRate);
        if (newRate >= rate.current) revert InvalidRate();
        _cancel(poolId, rate);
        rate.current = newRate;
        emit RateLowered(poolId, newRate);
    }

    function scheduleRaise(bytes32 poolId, uint16 newRate) external {
        _creator(poolId);
        Rate storage rate = rates[poolId];
        _checkRate(newRate);
        if (newRate <= rate.current || newRate > rate.current + MAX_RAISE) revert InvalidRate();
        rate.pending = newRate;
        rate.applyAfter = block.timestamp + RAISE_DELAY;
        emit RaiseScheduled(poolId, newRate, rate.applyAfter);
    }

    function cancelRaise(bytes32 poolId) external {
        _creator(poolId);
        Rate storage rate = rates[poolId];
        if (rate.pending == 0) revert NoPendingRaise();
        _cancel(poolId, rate);
    }

    /// @dev Explicit creator application after the delay; scheduling alone does not change the rate.
    function applyRaise(bytes32 poolId) external {
        _creator(poolId);
        Rate storage rate = rates[poolId];
        if (rate.pending == 0) revert NoPendingRaise();
        if (block.timestamp < rate.applyAfter) revert RaiseNotReady();
        rate.current = rate.pending;
        rate.pending = 0;
        rate.applyAfter = 0;
        emit RaiseApplied(poolId, rate.current);
    }

    /// @notice The creator's current rate, 100..500 bps.
    function currentRate(bytes32 poolId) public view returns (uint16 rate) {
        rate = rates[poolId].current;
        if (rate == 0) revert UnknownPool();
    }

    function _creator(bytes32 poolId) private {
        if (rates[poolId].current == 0) revert UnknownPool();
        ICreatorActivity(hook).creatorAction(poolId, msg.sender);
    }

    function _checkRate(uint16 rate) private pure {
        if (rate < MIN_RATE || rate > MAX_RATE) revert InvalidRate();
    }

    function _cancel(bytes32 poolId, Rate storage rate) private {
        if (rate.pending != 0) {
            rate.pending = 0;
            rate.applyAfter = 0;
            emit RaiseCancelled(poolId);
        }
    }
}
