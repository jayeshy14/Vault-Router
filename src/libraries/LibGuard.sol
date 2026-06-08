// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title LibGuard
/// @notice Namespaced storage and logic for the vault's NAV circuit breaker.
///         Bounds how far the ERC-4626 share price may move between checkpoints;
///         a move beyond the bound either reverts the offending operation
///         (hot-path tripwire) or latches the vault into a paused state
///         (permissionless poke), depending on entry point.
/// @dev Why two behaviours: a Solidity revert rolls back *all* state in the
///      call, so an operation that detects an anomaly and reverts cannot also
///      persist `paused = true`. The hot path therefore reverts (never transact
///      at an anomalous NAV, self-healing), while a dedicated poke that does
///      nothing *but* record the breaker state can commit the latch.
///      Storage location:
///      keccak256(abi.encode(uint256(keccak256("vaultrouter.storage.guard")) - 1)) & ~bytes32(uint256(0xff))
library LibGuard {
    uint16 internal constant BPS_DENOMINATOR = 10_000;

    /// @dev Virtual-share offset for ERC-4626 inflation-attack mitigation. Kept
    ///      here as the single source of truth so Vault._decimalsOffset and the
    ///      share-price math below never drift apart.
    uint8 internal constant DECIMALS_OFFSET = 6;

    /// @dev Precomputed erc7201("vaultrouter.storage.guard"):
    ///      keccak256(abi.encode(uint256(keccak256(id)) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant GUARD_STORAGE_SLOT = 0x2e670cc2b429ff4c75b2b5ce7b57521bb8c3d00aaafa77116d454e88d382a900;

    /// @notice Reverted on any deposit/withdraw while the breaker is latched.
    error EnforcedPause();
    /// @notice Reverted on the hot path when the share price moved beyond bound.
    error SharePriceDeviation(uint256 lastSharePrice, uint256 currentSharePrice, uint16 maxDeltaBps);

    /// @custom:storage-location erc7201:vaultrouter.storage.guard
    struct GuardStorage {
        bool paused;
        /// @dev Max allowed |Δ share price| between checkpoints, in bps of the
        ///      previous checkpoint. 0 disables the deviation check entirely.
        uint16 maxSharePriceDeltaBps;
        /// @dev Last accepted share price (asset units per share, scaled 1e18).
        uint256 lastSharePrice;
    }

    function guardStorage() internal pure returns (GuardStorage storage s) {
        bytes32 slot = GUARD_STORAGE_SLOT;
        assembly {
            s.slot := slot
        }
    }

    /// @notice Share price = (totalAssets + 1) * 1e18 / (supply + virtual shares).
    /// @dev Mirrors OZ ERC-4626's conversion with the same virtual-share offset
    ///      Vault uses, so the breaker measures the exact price users transact at.
    function sharePrice(uint256 totalAssets_, uint256 supply) internal pure returns (uint256) {
        uint256 effectiveSupply = supply + 10 ** DECIMALS_OFFSET;
        return ((totalAssets_ + 1) * 1e18) / effectiveSupply;
    }

    /// @notice True if |current - last| exceeds `maxDeltaBps` of `last`.
    /// @dev A zero bound or an unset checkpoint (`last == 0`) never trips.
    function deviationExceeded(uint256 last, uint256 current, uint16 maxDeltaBps) internal pure returns (bool) {
        if (maxDeltaBps == 0 || last == 0) return false;
        uint256 diff = current > last ? current - last : last - current;
        return diff * BPS_DENOMINATOR > uint256(maxDeltaBps) * last;
    }

    /// @notice Hot-path tripwire: revert if `current` deviates beyond bound,
    ///         otherwise advance the checkpoint. Pause is enforced by the caller.
    function checkpoint(GuardStorage storage g, uint256 current) internal {
        uint256 last = g.lastSharePrice;
        if (last == 0) {
            g.lastSharePrice = current; // first checkpoint arms the breaker
            return;
        }
        if (deviationExceeded(last, current, g.maxSharePriceDeltaBps)) {
            revert SharePriceDeviation(last, current, g.maxSharePriceDeltaBps);
        }
        g.lastSharePrice = current;
    }
}
