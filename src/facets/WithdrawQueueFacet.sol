// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { LibWithdrawQueue } from "../libraries/LibWithdrawQueue.sol";

/// @title WithdrawQueueFacet
/// @notice Public readers for the asynchronous withdrawal queue. The
///         share-moving entry points (`requestWithdraw`, `cancelWithdraw`,
///         `fulfillWithdraw`) live on the native `Vault` surface because only it
///         can `_transfer`/`_burn` shares; this facet exposes the queue state.
contract WithdrawQueueFacet {
    /// @notice The request that will be assigned to the next `requestWithdraw`.
    function nextWithdrawRequestId() external view returns (uint256) {
        return LibWithdrawQueue.queueStorage().nextRequestId;
    }

    /// @notice Total escrowed shares across all unfulfilled requests.
    function pendingWithdrawShares() external view returns (uint256) {
        return LibWithdrawQueue.queueStorage().totalPendingShares;
    }

    /// @notice The stored request for `id`. A `shares == 0` result means the slot
    ///         is empty — never created, already fulfilled, or cancelled.
    function withdrawRequest(uint256 id) external view returns (LibWithdrawQueue.WithdrawRequest memory) {
        return LibWithdrawQueue.queueStorage().requests[id];
    }
}
