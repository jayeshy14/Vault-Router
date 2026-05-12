// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IAavePool
/// @notice Minimal interface for the Aave V3 `Pool` contract — only the methods
///         the strategy facet calls. Full pool ABI is much larger; trimmed here
///         to keep the dependency surface small and the audit diff narrow.
/// @dev Reference: https://aave.com/docs/developers/smart-contracts/pool
interface IAavePool {
    /// @notice Supplies `amount` of `asset` to the pool, receiving aTokens (rebasing) in return.
    /// @param asset The underlying asset address (e.g. USDC).
    /// @param amount The amount of `asset` to supply.
    /// @param onBehalfOf The address that will receive the aTokens.
    /// @param referralCode Reserved for backwards compatibility; pass 0.
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;

    /// @notice Withdraws `amount` of `asset` from the pool to `to`, burning the corresponding aTokens.
    /// @param asset The underlying asset address.
    /// @param amount The amount to withdraw. Use `type(uint256).max` to withdraw all.
    /// @param to The address receiving the underlying.
    /// @return The amount of `asset` actually withdrawn.
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
}
