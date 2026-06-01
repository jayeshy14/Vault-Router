// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC173 } from "../interfaces/IERC173.sol";
import { LibDiamond } from "../libraries/LibDiamond.sol";

contract OwnershipFacet is IERC173 {
    /// @notice Thrown when a non-pending-owner calls `acceptOwnership`.
    error NotPendingOwner(address caller, address expected);

    /// @inheritdoc IERC173
    function owner() external view override returns (address owner_) {
        owner_ = LibDiamond.contractOwner();
    }

    /// @notice The address nominated to take ownership, pending its acceptance.
    function pendingOwner() external view returns (address) {
        return LibDiamond.pendingOwner();
    }

    /// @inheritdoc IERC173
    /// @dev Two-step transfer: this only NOMINATES `_newOwner`; ownership does not
    ///      move until they call `acceptOwnership`. This makes a fat-fingered or
    ///      malicious handoff recoverable and removes the need for an explicit
    ///      zero-address check — because address(0) can never call
    ///      `acceptOwnership`, ownership can never be lost to it; passing
    ///      address(0) here simply cancels any pending transfer.
    function transferOwnership(address _newOwner) external override {
        LibDiamond.enforceIsContractOwner();
        LibDiamond.setPendingOwner(_newOwner);
    }

    /// @notice Complete a pending ownership transfer. Callable only by the
    ///         currently nominated pending owner.
    function acceptOwnership() external {
        address pending = LibDiamond.pendingOwner();
        if (msg.sender != pending) revert NotPendingOwner(msg.sender, pending);
        LibDiamond.acceptPendingOwner();
    }
}
