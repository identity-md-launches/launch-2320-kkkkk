// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

contract MockQuote {
    string public constant name = "Quote";
    string public constant symbol = "QUO";
    uint8 public immutable decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    bool public taxed;
    address public taxFrom;
    bool public failTransfers;
    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    constructor(uint8 decimals_) {
        decimals = decimals_;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function setTaxed(bool value) external {
        taxed = value;
    }

    function setTaxFrom(address from) external {
        taxFrom = from;
    }

    function setFailTransfers(bool value) external {
        failTransfers = value;
    }

    function rebaseDown(address account, uint256 amount) external {
        balanceOf[account] -= amount;
        totalSupply -= amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
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
        if (failTransfers) return false;
        balanceOf[from] -= amount;
        uint256 fee = taxed && (taxFrom == address(0) || from == taxFrom) ? amount / 100 : 0;
        balanceOf[to] += amount - fee;
        totalSupply -= fee;
        emit Transfer(from, to, amount - fee);
        return true;
    }
}
