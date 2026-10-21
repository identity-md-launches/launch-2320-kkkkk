// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {RateModuleBase} from "./RateModuleBase.sol";

/// @notice A rate-only module: the fee is the creator's current rate.
contract FixedRateModule is RateModuleBase {
    constructor(address hook_) RateModuleBase(hook_) {}

    function feeBps(bytes32 poolId, bool, bytes calldata) external view returns (uint16) {
        return currentRate(poolId);
    }
}
