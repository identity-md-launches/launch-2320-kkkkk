// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {RateModuleBase} from "./RateModuleBase.sol";
import {IPulseSource} from "./interfaces/IRulesModule.sol";

/// @notice Fee scales with the pool's pulse: 100 bps when quiet, the creator's rate at HOT or above.
contract PulseRateModule is RateModuleBase {
    uint256 public constant HOT = 6e18;

    constructor(address hook_) RateModuleBase(hook_) {}

    /// @dev feeBps = 100 + (rate - 100) * min(pulse, HOT) / HOT. View only; reads the hook's pulse.
    function feeBps(bytes32 poolId, bool, bytes calldata) external view returns (uint16) {
        uint256 rate = currentRate(poolId);
        uint256 pulse = IPulseSource(hook).pulseOf(poolId);
        if (pulse > HOT) pulse = HOT;
        return uint16(MIN_RATE + (rate - MIN_RATE) * pulse / HOT);
    }
}
