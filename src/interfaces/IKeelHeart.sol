// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IKeelHeart {
    /// @notice Raw quote units a buy must spend (gross, before fees) to count. Zero means never.
    function minBuy(address quote) external view returns (uint256);
    /// @notice Hook-only notification of a counted buy.
    function onBuy(address token, address quote, address buyer, uint256 grossQuoteIn, uint256 tokensOut)
        external;
}
