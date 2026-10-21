// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IERC20Test} from "./Router.sol";

/// @dev Minimal WETH9.
contract MockWETH {
    string public constant name = "Wrapped Ether";
    string public constant symbol = "WETH";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    receive() external payable {
        balanceOf[msg.sender] += msg.value;
    }

    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
    }

    function withdraw(uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "withdraw");
    }

    function totalSupply() external view returns (uint256) {
        return address(this).balance;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (from != msg.sender) allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

interface IV3Callback {
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external;
}

/// @dev Constant-product stand-in for a Uniswap v3 pool with v3's swap/callback/balance-check protocol:
///      output is sent first, then the callback, then the input balance is verified.
contract MockV3Pool {
    address public immutable token0;
    address public immutable token1;
    uint24 public immutable fee;
    uint256 public reserve0;
    uint256 public reserve1;
    /// @dev Nonzero caps the input consumed, emulating a v3 swap stopped by its price limit.
    uint256 public maxInput;
    bool public skipCallback;

    constructor(address a, address b, uint24 fee_) {
        (token0, token1) = a < b ? (a, b) : (b, a);
        fee = fee_;
    }

    function sync() external {
        reserve0 = IERC20Test(token0).balanceOf(address(this));
        reserve1 = IERC20Test(token1).balanceOf(address(this));
    }

    function setMaxInput(uint256 value) external {
        maxInput = value;
    }

    function setSkipCallback(bool value) external {
        skipCallback = value;
    }

    function getAmountOut(bool zeroForOne, uint256 amountIn) public view returns (uint256) {
        (uint256 rIn, uint256 rOut) = zeroForOne ? (reserve0, reserve1) : (reserve1, reserve0);
        uint256 inAfterFee = amountIn * (1e6 - fee) / 1e6;
        return rOut * inAfterFee / (rIn + inAfterFee);
    }

    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160, bytes calldata data)
        external
        returns (int256 amount0, int256 amount1)
    {
        require(amountSpecified > 0, "exact input only");
        uint256 amountIn = uint256(amountSpecified);
        if (maxInput != 0 && amountIn > maxInput) amountIn = maxInput;
        uint256 amountOut = getAmountOut(zeroForOne, amountIn);
        (address tokenIn, address tokenOut) = zeroForOne ? (token0, token1) : (token1, token0);
        if (amountOut != 0) require(IERC20Test(tokenOut).transfer(recipient, amountOut), "out");
        (amount0, amount1) =
            zeroForOne ? (int256(amountIn), -int256(amountOut)) : (-int256(amountOut), int256(amountIn));
        uint256 balanceBefore = IERC20Test(tokenIn).balanceOf(address(this));
        if (!skipCallback) IV3Callback(msg.sender).uniswapV3SwapCallback(amount0, amount1, data);
        require(IERC20Test(tokenIn).balanceOf(address(this)) >= balanceBefore + amountIn, "IIA");
        reserve0 = IERC20Test(token0).balanceOf(address(this));
        reserve1 = IERC20Test(token1).balanceOf(address(this));
    }
}

/// @dev A v3 pool impostor that calls the router back with a forged delta it chose itself.
contract EvilV3Pool {
    address public immutable token0;
    address public immutable token1;

    constructor(address a, address b) {
        (token0, token1) = a < b ? (a, b) : (b, a);
    }

    function swap(address, bool zeroForOne, int256 amountSpecified, uint160, bytes calldata data)
        external
        returns (int256 amount0, int256 amount1)
    {
        // Ask for twice the input, receive nothing.
        (amount0, amount1) = zeroForOne ? (amountSpecified * 2, int256(0)) : (int256(0), amountSpecified * 2);
        IV3Callback(msg.sender).uniswapV3SwapCallback(amount0, amount1, data);
    }
}

/// @dev Adds v4 liquidity and settles it in full (unlike the part 1 test router's `modify`).
contract LiquidityHelper {
    IPoolManager public immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    receive() external payable {}

    function add(PoolKey memory key, ModifyLiquidityParams memory params) external payable {
        manager.unlock(abi.encode(key, params));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (PoolKey memory key, ModifyLiquidityParams memory params) =
            abi.decode(data, (PoolKey, ModifyLiquidityParams));
        (BalanceDelta delta,) = manager.modifyLiquidity(key, params, "");
        _pay(key.currency0, delta.amount0());
        _pay(key.currency1, delta.amount1());
        return "";
    }

    function _pay(Currency currency, int128 amount) private {
        if (amount >= 0) return;
        uint256 owed = uint256(uint128(-amount));
        manager.sync(currency);
        if (Currency.unwrap(currency) == address(0)) {
            manager.settle{value: owed}();
        } else {
            require(IERC20Test(Currency.unwrap(currency)).transfer(address(manager), owed));
            manager.settle();
        }
    }
}

/// @dev Quote whose balances grow on every receipt (a positive rebase mid-trade).
contract RebasingQuote {
    string public constant name = "Rebase";
    string public constant symbol = "RBS";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    address public rebaseFor;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function setRebaseFor(address who) external {
        rebaseFor = who;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        return _transfer(msg.sender, to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        return _transfer(from, to, amount);
    }

    function _transfer(address from, address to, uint256 amount) private returns (bool) {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        if (to == rebaseFor && rebaseFor != address(0)) balanceOf[to] += 1;
        return true;
    }
}

/// @dev Seller contract that refuses ETH.
contract EthRejecter {
    function approve(address token, address spender, uint256 amount) external {
        require(IERC20Test(token).approve(spender, amount));
    }

    function sell(address router, bytes calldata data) external {
        (bool ok, bytes memory reason) = router.call(data);
        if (!ok) {
            assembly {
                revert(add(reason, 32), mload(reason))
            }
        }
    }
}
