// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title LibWithdrawQueue
/// @notice Namespaced storage for the asynchronous withdrawal queue. Lets users
///         exit when the vault lacks idle liquidity to satisfy a synchronous
///         ERC-4626 `withdraw`/`redeem` — most importantly when capital sits in
///         an illiquid strategy (e.g. Pendle PT before maturity). The user's
///         shares are escrowed on request and a curator/keeper fulfills them
///         once a rebalance has freed enough idle balance.
/// @dev Escrow model: shares are transferred to the diamond (not burned) on
///      request, so they remain in `totalSupply` and the request stays
///      NAV-neutral for the remaining holders. The claim is converted to assets
///      at the *live* share price on fulfillment — the requester keeps full
///      exposure (yield and loss) until they are actually paid out, so the queue
///      cannot be used to lock in a stale price at the expense of stayers.
///
///      The share-moving entry points (request/cancel/fulfill) live on Vault.sol
///      because only the native ERC-4626 surface can `_transfer`/`_burn` shares;
///      this library holds the queue state and `WithdrawQueueFacet` the readers.
///      Storage location:
///      keccak256(abi.encode(uint256(keccak256("vaultrouter.storage.withdrawqueue")) - 1)) & ~bytes32(uint256(0xff))
library LibWithdrawQueue {
    /// @dev erc7201:vaultrouter.storage.withdrawqueue
    bytes32 internal constant WITHDRAW_QUEUE_STORAGE_SLOT =
        0x3d5a7857d3d4e9dbe18f39f41bd8fd54a510e284a7d9a4464e9cc2159e9f9100;

    /// @notice A single pending exit. `shares == 0` marks the slot as
    ///         empty/settled (fulfilled or cancelled), so ids are never reused.
    struct WithdrawRequest {
        address owner; // who requested — receives the shares back on cancel
        address receiver; // who receives the underlying on fulfillment
        uint256 shares; // escrowed shares awaiting fulfillment
    }

    /// @custom:storage-location erc7201:vaultrouter.storage.withdrawqueue
    struct QueueStorage {
        uint256 nextRequestId;
        mapping(uint256 => WithdrawRequest) requests;
        /// @dev Sum of all escrowed shares currently awaiting fulfillment.
        uint256 totalPendingShares;
    }

    function queueStorage() internal pure returns (QueueStorage storage s) {
        bytes32 slot = WITHDRAW_QUEUE_STORAGE_SLOT;
        assembly {
            s.slot := slot
        }
    }
}
