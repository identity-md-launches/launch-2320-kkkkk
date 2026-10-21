// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IRulesModule {
    function hook() external view returns (address);
    function initialize(bytes32 poolId, uint16 baseFeeBps) external;
    function feeBps(bytes32 poolId, bool isBuy, bytes calldata context) external view returns (uint16);
}

interface ICreatorActivity {
    /// @notice Called only by the pool's immutable module; checks the actor against the live creator.
    function creatorAction(bytes32 poolId, address actor) external;
}

interface IPulseSource {
    /// @notice Decayed buy counter of a pool, 1e18 per buy, half-life one hour.
    function pulseOf(bytes32 poolId) external view returns (uint256);
}

interface IKeelGovernance {
    function teamRecipient() external view returns (address);
    function takeoverContract() external view returns (address);
    function router() external view returns (address);
    function heart() external view returns (address);
}
