// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IQuoteToken {
    function balanceOf(address account) external view returns (uint256);
    function decimals() external view returns (uint8);
}

library QuoteTransfer {
    error TransferFailed();
    error NonStandardQuote();

    function balance(address quote, address account) internal view returns (uint256) {
        return quote == address(0) ? account.balance : IQuoteToken(quote).balanceOf(account);
    }

    function pay(address quote, address to, uint256 amount) internal {
        if (quote == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert TransferFailed();
        } else {
            (bool ok, bytes memory result) =
                quote.call(abi.encodeWithSignature("transfer(address,uint256)", to, amount));
            if (!ok || (result.length != 0 && !abi.decode(result, (bool)))) revert TransferFailed();
        }
    }
}
