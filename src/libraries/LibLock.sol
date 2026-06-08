// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title LibLock
/// @notice Namespaced storage for the share-lock period — a short window after
///         a deposit during which the freshly minted shares cannot be moved
///         (transferred, withdrawn, or redeemed). This defeats atomic
///         deposit -> manipulate -> withdraw flashloan/MEV attacks: an attacker
///         cannot mint and unwind shares within the same block while the lock
///         holds.
/// @dev Enforcement lives in `Vault._update` (the single ERC20 mutation hook),
///      which catches both transfers and burns so the lock cannot be bypassed
///      by transferring shares out and withdrawing from another account. The
///      lock is set on the deposit receiver in `Vault._deposit`. A
///      `shareLockPeriod` of 0 disables it.
///      Storage location:
///      keccak256(abi.encode(uint256(keccak256("vaultrouter.storage.lock")) - 1)) & ~bytes32(uint256(0xff))
library LibLock {
    /// @dev Upper bound on the lock window: keeps it a short anti-MEV measure,
    ///      not a withdrawal freeze that could trap user funds.
    uint64 internal constant MAX_SHARE_LOCK_PERIOD = 1 days;

    /// @notice Reverted when shares are moved before their lock window elapses.
    error SharesLocked(address account, uint256 lockedUntil);

    /// @dev Precomputed erc7201("vaultrouter.storage.lock"):
    ///      keccak256(abi.encode(uint256(keccak256(id)) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant LOCK_STORAGE_SLOT = 0x98796fb009fa2d66e5ccc76be36c65ba72c5853e7fe1b4f23987457f018b5800;

    /// @custom:storage-location erc7201:vaultrouter.storage.lock
    struct LockStorage {
        /// @dev Seconds that freshly minted shares stay locked after a deposit.
        ///      0 disables the lock entirely.
        uint64 shareLockPeriod;
        /// @dev Timestamp until which an account's shares are locked. A move is
        ///      blocked while `block.timestamp < lockedUntil[account]`.
        mapping(address => uint256) lockedUntil;
    }

    function lockStorage() internal pure returns (LockStorage storage s) {
        bytes32 slot = LOCK_STORAGE_SLOT;
        assembly {
            s.slot := slot
        }
    }
}
