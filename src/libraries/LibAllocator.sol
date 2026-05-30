// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title LibAllocator
/// @notice Allocator state lives in an EIP-7201 namespaced slot so it cannot
///         collide with the ERC-4626 surface storage on Vault.sol or with
///         LibDiamond's selector table.
/// @dev keccak256(abi.encode(uint256(keccak256("vaultrouter.storage.allocator")) - 1)) & ~bytes32(uint256(0xff))
library LibAllocator {
    bytes32 internal constant ALLOCATOR_STORAGE_SLOT =
        0x2f4e489fd9fdb4c68f60ae0ec4a19ea4d9796e41932a74c08f691957213bd500;

    uint16 internal constant BPS_DENOMINATOR = 10_000;

    /// @notice Per-strategy configuration. Selectors are dispatched via the
    ///         Diamond fallback: the AllocatorFacet calls
    ///         `address(this).call(abi.encodeWithSelector(cfg.depositSelector, amount))`
    ///         which routes back to the strategy facet's prefixed implementation.
    /// @dev `capBps == 0` means "no per-strategy cap; use globalMaxStrategyCapBps".
    struct StrategyConfig {
        bytes4 totalAssetsSelector;
        bytes4 depositSelector;
        bytes4 withdrawSelector;
        bytes4 harvestSelector;
        uint16 capBps;
        bool active;
    }

    /// @custom:storage-location erc7201:vaultrouter.storage.allocator
    struct AllocatorStorage {
        bytes32[] strategyIds;
        mapping(bytes32 => StrategyConfig) configs;
        mapping(bytes32 => uint16) targetBps;
        uint16 idleReserveBps;
        uint16 globalMaxStrategyCapBps;
        uint64 lastRebalanceBlock;
        /// @dev Strategies flagged here are isolated: excluded from NAV and
        ///      skipped by the rebalancer/harvester, so a single failing protocol
        ///      cannot brick the whole vault. Owner-controlled risk state, kept
        ///      out of StrategyConfig so it is dynamic rather than static config.
        mapping(bytes32 => bool) quarantined;
    }

    function allocatorStorage() internal pure returns (AllocatorStorage storage s) {
        bytes32 slot = ALLOCATOR_STORAGE_SLOT;
        assembly {
            s.slot := slot
        }
    }
}
