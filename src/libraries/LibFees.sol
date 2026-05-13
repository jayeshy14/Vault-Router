// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title LibFees
/// @notice Namespaced storage and constants for the vault's fee accrual logic.
///         Tracks the fee recipient, performance + management fee rates, the
///         share-price high-water mark used by the performance fee, and the
///         timestamp of the last accrual used by the management fee.
/// @dev Storage location:
///      keccak256(abi.encode(uint256(keccak256("vaultrouter.storage.fees")) - 1)) & ~bytes32(uint256(0xff))
library LibFees {
    uint16 internal constant BPS_DENOMINATOR = 10_000;
    uint16 internal constant MAX_PERFORMANCE_FEE_BPS = 5000; // 50% sanity ceiling
    uint16 internal constant MAX_MANAGEMENT_FEE_BPS = 1000; // 10% / year sanity ceiling
    uint256 internal constant SECONDS_PER_YEAR = 365 days;

    /// @dev erc7201:vaultrouter.storage.fees
    bytes32 internal constant FEE_STORAGE_SLOT = 0xd8263cd2923de1a73423e53eeb7d7ffc12f7b4ef6a8eadaee1bbca5e38dbe600;

    struct FeeStorage {
        address feeRecipient;
        uint16 performanceFeeBps;
        uint16 managementFeeBps;
        /// @dev Share price (asset units per share, scaled by 1e18) at the most
        ///      recent accrual. Performance fee is taken on any increase above this.
        uint256 highWaterMark;
        uint64 lastFeeAccrual;
    }

    function feeStorage() internal pure returns (FeeStorage storage s) {
        bytes32 slot = FEE_STORAGE_SLOT;
        assembly {
            s.slot := slot
        }
    }
}
