// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { LibDiamond } from "../libraries/LibDiamond.sol";
import { LibRoles } from "../libraries/LibRoles.sol";

/// @title RolesFacet
/// @notice Owner-gated management of the curator role. The owner appoints or
///         revokes curators; curators get day-to-day operational authority
///         (allocation + rebalance + harvest) bounded by the risk parameters the
///         owner controls. Curators can never upgrade facets, change fees, or
///         move funds outside the allow-listed strategies.
contract RolesFacet {
    error ZeroAddress();

    event CuratorSet(address indexed account, bool enabled);

    /// @notice Grant or revoke the curator role for `account`.
    /// @dev Owner-only. The owner is always implicitly a curator (see
    ///      LibRoles.isCurator), so this controls *additional* operational keys —
    ///      for example an off-chain agent that autonomously rebalances.
    function setCurator(address account, bool enabled) external {
        LibDiamond.enforceIsContractOwner();
        if (account == address(0)) revert ZeroAddress();
        LibRoles.rolesStorage().isCurator[account] = enabled;
        emit CuratorSet(account, enabled);
    }

    /// @notice True if `account` may perform curator-gated operations.
    /// @dev Returns true for the owner as well, since owner ≥ curator.
    function isCurator(address account) external view returns (bool) {
        return LibRoles.isCurator(account);
    }
}
