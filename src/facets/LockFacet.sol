// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { LibDiamond } from "../libraries/LibDiamond.sol";
import { LibLock } from "../libraries/LibLock.sol";

/// @title LockFacet
/// @notice Owner-gated configuration and public readers for the share-lock
///         period. The enforcement itself lives in `Vault._update`/`_deposit`
///         (the native ERC-4626 surface needs the ERC20 mutation hooks); this
///         facet owns the configuration surface.
contract LockFacet {
    error ShareLockPeriodTooLong(uint64 attempted, uint64 maxPeriod);

    event ShareLockPeriodSet(uint64 period);

    /// @notice Set the share-lock window (seconds). Freshly minted shares from a
    ///         deposit cannot be moved until this window elapses.
    /// @dev Owner-gated risk bound. Capped at `MAX_SHARE_LOCK_PERIOD` so it
    ///      stays an anti-MEV measure rather than a withdrawal freeze. `0`
    ///      disables the lock for future deposits.
    /// @param period Lock duration in seconds (0 = disabled).
    function setShareLockPeriod(uint64 period) external {
        LibDiamond.enforceIsContractOwner();
        if (period > LibLock.MAX_SHARE_LOCK_PERIOD) {
            revert ShareLockPeriodTooLong(period, LibLock.MAX_SHARE_LOCK_PERIOD);
        }
        LibLock.lockStorage().shareLockPeriod = period;
        emit ShareLockPeriodSet(period);
    }

    /// @notice The configured share-lock window in seconds (0 = disabled).
    function shareLockPeriod() external view returns (uint64) {
        return LibLock.lockStorage().shareLockPeriod;
    }

    /// @notice Timestamp until which `account`'s shares are locked. A move is
    ///         blocked while `block.timestamp` is below this value.
    function lockedUntil(address account) external view returns (uint256) {
        return LibLock.lockStorage().lockedUntil[account];
    }
}
