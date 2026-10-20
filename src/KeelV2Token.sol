// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Identical full-code ERC20 instances, without proxy delegatecalls or privileged roles.
contract KeelV2Token {
    error ZeroAddress();
    error InsufficientBalance();
    error InsufficientAllowance();
    error UnfinalizedBlock();

    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public constant totalSupply = 1_000_000_000 ether;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    struct Checkpoint {
        uint256 blockNumber;
        uint256 balance;
    }
    mapping(address => Checkpoint[]) private _checkpoints;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(string memory name_, string memory symbol_) {
        name = name_;
        symbol = symbol_;
        balanceOf[msg.sender] = totalSupply;
        _checkpoint(msg.sender);
        emit Transfer(address(0), msg.sender, totalSupply);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        if (spender == address(0)) revert ZeroAddress();
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 approved = allowance[from][msg.sender];
        if (approved != type(uint256).max) {
            if (approved < amount) revert InsufficientAllowance();
            allowance[from][msg.sender] = approved - amount;
            emit Approval(from, msg.sender, approved - amount);
        }
        _transfer(from, to, amount);
        return true;
    }

    /// @dev Current/future blocks have no finalized end balance and are rejected.
    function balanceAt(address account, uint256 blockNumber) external view returns (uint256) {
        if (blockNumber >= block.number) revert UnfinalizedBlock();
        Checkpoint[] storage history = _checkpoints[account];
        uint256 low;
        uint256 high = history.length;
        while (low < high) {
            uint256 mid = low + (high - low) / 2;
            if (history[mid].blockNumber <= blockNumber) low = mid + 1;
            else high = mid;
        }
        return low == 0 ? 0 : history[low - 1].balance;
    }

    function checkpointCount(address account) external view returns (uint256) {
        return _checkpoints[account].length;
    }

    function _transfer(address from, address to, uint256 amount) private {
        if (to == address(0)) revert ZeroAddress();
        if (balanceOf[from] < amount) revert InsufficientBalance();
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        _checkpoint(from);
        if (to != from) _checkpoint(to);
        emit Transfer(from, to, amount);
    }

    function _checkpoint(address account) private {
        uint256 length = _checkpoints[account].length;
        if (length != 0 && _checkpoints[account][length - 1].blockNumber == block.number) {
            _checkpoints[account][length - 1].balance = balanceOf[account];
        } else {
            _checkpoints[account].push(Checkpoint(block.number, balanceOf[account]));
        }
    }
}
