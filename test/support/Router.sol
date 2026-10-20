// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Guard} from "../../src/libraries/Guard.sol";

interface IERC20Test {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
}

/// @dev Test-only router: prefunds input so fee custody also works with an otherwise empty PoolManager.
contract Router is Guard {
    IPoolManager public immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    receive() external payable {
        require(msg.sender == address(manager));
    }

    function swap(PoolKey memory key, SwapParams memory params, uint256 deposit, address to)
        external
        payable
        nonReentrant
        returns (BalanceDelta delta)
    {
        Currency input = params.zeroForOne ? key.currency0 : key.currency1;
        if (Currency.unwrap(input) == address(0)) {
            require(msg.value == deposit);
        } else {
            require(msg.value == 0);
            uint256 beforeBalance = input.balanceOfSelf();
            require(IERC20Test(Currency.unwrap(input)).transferFrom(msg.sender, address(this), deposit));
            require(input.balanceOfSelf() == beforeBalance + deposit);
        }
        bytes memory result = manager.unlock(abi.encode(uint8(0), abi.encode(key, params, deposit, to)));
        delta = abi.decode(result, (BalanceDelta));
    }

    function modify(PoolKey memory key, ModifyLiquidityParams memory params) external {
        manager.unlock(abi.encode(uint8(1), abi.encode(key, params)));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (uint8 action, bytes memory payload) = abi.decode(data, (uint8, bytes));
        if (action == 1) {
            (PoolKey memory liquidityKey, ModifyLiquidityParams memory liquidityParams) =
                abi.decode(payload, (PoolKey, ModifyLiquidityParams));
            manager.modifyLiquidity(liquidityKey, liquidityParams, "");
            return "";
        }
        (PoolKey memory key, SwapParams memory params, uint256 deposit, address to) =
            abi.decode(payload, (PoolKey, SwapParams, uint256, address));
        Currency input = params.zeroForOne ? key.currency0 : key.currency1;
        Currency output = params.zeroForOne ? key.currency1 : key.currency0;
        manager.sync(input);
        if (Currency.unwrap(input) == address(0)) {
            manager.settle{value: deposit}();
        } else {
            require(IERC20Test(Currency.unwrap(input)).transfer(address(manager), deposit));
            require(manager.settle() == deposit);
        }
        BalanceDelta delta = manager.swap(key, params, "");
        int128 inputDelta = params.zeroForOne ? delta.amount0() : delta.amount1();
        int128 outputDelta = params.zeroForOne ? delta.amount1() : delta.amount0();
        require(inputDelta <= 0 && outputDelta >= 0);
        uint256 refund = deposit - uint256(-int256(inputDelta));
        if (refund != 0) manager.take(input, to, refund);
        if (outputDelta != 0) manager.take(output, to, uint128(outputDelta));
        return abi.encode(delta);
    }
}
