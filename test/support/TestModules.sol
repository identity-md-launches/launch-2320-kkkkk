// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IRulesModule} from "../../src/interfaces/IRulesModule.sol";
import {KeelV2Hook} from "../../src/KeelV2Hook.sol";

contract AccrualSensitiveModule is IRulesModule {
    address public immutable hook;

    constructor(address hook_) {
        hook = hook_;
    }

    function initialize(bytes32, uint16) external view {
        require(msg.sender == hook);
    }

    function feeBps(bytes32, bool, bytes calldata) external view returns (uint16) {
        return KeelV2Hook(payable(hook)).totalUnclaimed(address(0)) == 0 ? 100 : 200;
    }
}

contract InvalidRateModule is IRulesModule {
    address public immutable hook;

    constructor(address hook_) {
        hook = hook_;
    }

    function initialize(bytes32, uint16) external view {
        require(msg.sender == hook);
    }

    function feeBps(bytes32, bool, bytes calldata) external pure returns (uint16) {
        return 501;
    }
}
