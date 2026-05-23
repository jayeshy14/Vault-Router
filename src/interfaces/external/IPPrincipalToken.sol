// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IPPrincipalToken
/// @notice Minimal interface for Pendle's PendlePrincipalToken (PT).
/// @dev Reference:
/// https://github.com/pendle-finance/pendle-core-v2-public/blob/main/contracts/core/YieldContracts/PendlePrincipalToken.sol
interface IPPrincipalToken {
    /// @notice Returns true if the PT has passed its expiry timestamp.
    function isExpired() external view returns (bool);

    /// @notice Unix timestamp at which this PT matures and redeems 1:1.
    function expiry() external view returns (uint256);

    /// @notice The SY token this PT is backed by.
    function SY() external view returns (address);

    /// @notice The paired YT contract address.
    function YT() external view returns (address);

    /// @notice ERC-20 balance.
    function balanceOf(address account) external view returns (uint256);

    /// @notice ERC-20 decimals (matches underlying asset).
    function decimals() external view returns (uint8);

    /// @notice ERC-20 approve.
    function approve(address spender, uint256 amount) external returns (bool);
}
