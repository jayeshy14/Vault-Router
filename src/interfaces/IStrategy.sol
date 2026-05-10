// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IStrategy
/// @notice Documentation interface describing the canonical shape of a strategy
///         facet in this Diamond. Concrete strategy facets MUST redeclare each
///         method with a strategy-specific prefix (e.g. `idle*`, `morpho*`,
///         `aave*`, `pendle*`) so that multiple strategies can be cut into the
///         same Diamond without selector collisions.
/// @dev This interface is not implemented directly. It exists to keep the
///      strategy ABI uniform across implementations — the Allocator dispatches
///      on a strategy id and routes to the matching prefixed selectors.
interface IStrategy {
    /// @notice Asset balance this strategy currently controls, denominated in
    ///         the vault's underlying asset.
    function strategyTotalAssets() external view returns (uint256);

    /// @notice Pulls `amount` from the vault's idle balance into this strategy's
    ///         positions (e.g. supplying to Morpho, depositing to Aave).
    function strategyDeposit(uint256 amount) external;

    /// @notice Returns up to `amount` from this strategy back to the vault as
    ///         idle balance. Returns the amount actually withdrawn — may be
    ///         less than requested if the underlying market is illiquid.
    function strategyWithdraw(uint256 amount) external returns (uint256 actuallyWithdrawn);

    /// @notice Claims any reward tokens accrued and either compounds them into
    ///         the underlying position or returns them to the vault.
    function strategyHarvest() external;
}
