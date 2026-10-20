// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

abstract contract Guard {
    error ReentrantCall();
    uint256 private _entered;

    modifier nonReentrant() {
        if (_entered != 0) revert ReentrantCall();
        _entered = 1;
        _;
        _entered = 0;
    }
}
