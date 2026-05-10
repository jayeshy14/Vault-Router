// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @title IdleStrategyFacet
/// @notice Trivial strategy that holds the vault's underlying asset idle in the
///         Diamond's own balance. Useful as the always-present sink for the
///         allocator's idle reserve and as a sanity test of the strategy plumbing.
/// @dev Selectors are prefixed with `idle` to avoid collisions with other
///      strategy facets sharing the Diamond.
contract IdleStrategyFacet {
    /// @notice Asset balance this strategy currently controls.
    /// @dev When delegatecalled by the Vault, `address(this)` is the Vault, so
    ///      `IERC4626(address(this)).asset()` self-calls to read the immutable.
    function idleTotalAssets() external view returns (uint256) {
        address assetAddr = IERC4626(address(this)).asset();
        return IERC20(assetAddr).balanceOf(address(this));
    }
}
