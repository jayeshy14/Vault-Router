// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IComet
/// @notice Minimal interface for a Compound III (Comet) market — only the methods
///         the strategy facet calls, plus the two view rate-readers a curator uses
///         to price the market on-chain. The full Comet ABI is much larger;
///         trimmed here to keep the dependency surface small and the audit diff
///         narrow (same philosophy as `IAavePool`).
/// @dev Reference: https://docs.compound.finance/
///      `cUSDCv3` is a non-standard rebasing token: `balanceOf` returns the
///      present value of the supplied base asset and grows as supply interest
///      accrues, exactly like an Aave aToken. There is no separate receipt token.
interface IComet {
    /// @notice Supplies `amount` of `asset` to the market. Supplying the base
    ///         token increases the caller's supply balance (and earns interest);
    ///         the credited present value is reflected in `balanceOf`.
    /// @param asset The asset to supply. For a base-asset supply this MUST equal `baseToken()`.
    /// @param amount The amount of `asset` to supply.
    function supply(address asset, uint256 amount) external;

    /// @notice Withdraws `amount` of `asset` to the caller (`msg.sender`). For a
    ///         pure base-asset supplier this reduces the supply balance; it never
    ///         tips into a borrow as long as `amount <= balanceOf(caller)`.
    /// @param asset The asset to withdraw. For a base-asset withdrawal this MUST equal `baseToken()`.
    /// @param amount The amount of `asset` to withdraw.
    function withdraw(address asset, uint256 amount) external;

    /// @notice Present value of the caller's base-asset supply, denominated in the
    ///         base token. Accrues upward with supply interest between blocks.
    function balanceOf(address account) external view returns (uint256);

    /// @notice The base asset of this market (e.g. native USDC on Arbitrum).
    function baseToken() external view returns (address);

    /// @notice Current market utilization, scaled by 1e18. Input to `getSupplyRate`.
    /// @dev Exposed for curator/reporting reads, not used by the facet itself.
    function getUtilization() external view returns (uint256);

    /// @notice Per-second supply rate at a given `utilization`, scaled by 1e18.
    ///         Annualize with `rate * 365 days` to get an APR. Unlike Aave's
    ///         pre-annualized `currentLiquidityRate`, Comet returns a spot
    ///         per-second rate parameterized by utilization.
    /// @dev Exposed for curator/reporting reads, not used by the facet itself.
    function getSupplyRate(uint256 utilization) external view returns (uint64);
}
