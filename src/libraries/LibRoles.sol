// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { LibDiamond } from "./LibDiamond.sol";

/// @title LibRoles
/// @notice Namespaced storage for the vault's operational role layer. Separates
///         the low-privilege **curator** seat (day-to-day allocation + harvest)
///         from the high-privilege **owner** seat (facet upgrades, risk bounds,
///         fee config). The curator key can operate the vault within bounds the
///         owner sets but can never drain it, upgrade it, or change fees — which
///         is what makes it safe to hand to an automated (e.g. AI) operator.
/// @dev Roles state lives in an EIP-7201 namespaced slot so it cannot collide
///      with the ERC-4626 surface storage on Vault.sol, LibDiamond's selector
///      table, or any other facet's namespace.
///      keccak256(abi.encode(uint256(keccak256("vaultrouter.storage.roles")) - 1)) & ~bytes32(uint256(0xff))
library LibRoles {
    /// @dev Precomputed erc7201("vaultrouter.storage.roles"):
    ///      keccak256(abi.encode(uint256(keccak256(id)) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant ROLES_STORAGE_SLOT = 0x72812988d549c1f62ecdf8218c688f5047bef5695066f17d8d1060ecc0962300;

    error NotCurator(address caller);

    /// @custom:storage-location erc7201:vaultrouter.storage.roles
    struct RolesStorage {
        mapping(address => bool) isCurator;
    }

    function rolesStorage() internal pure returns (RolesStorage storage s) {
        bytes32 slot = ROLES_STORAGE_SLOT;
        assembly {
            s.slot := slot
        }
    }

    /// @notice True if `account` may perform curator-gated operations.
    /// @dev The owner is implicitly a curator (owner ≥ curator), so governance
    ///      can always operate the vault even before any curator is appointed.
    function isCurator(address account) internal view returns (bool) {
        return account == LibDiamond.contractOwner() || rolesStorage().isCurator[account];
    }

    /// @notice Reverts unless `msg.sender` is the owner or an appointed curator.
    function enforceIsCurator() internal view {
        if (!isCurator(msg.sender)) revert NotCurator(msg.sender);
    }
}
