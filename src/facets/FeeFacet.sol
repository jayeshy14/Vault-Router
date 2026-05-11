// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {LibDiamond} from "../libraries/LibDiamond.sol";
import {LibFees} from "../libraries/LibFees.sol";

/// @title FeeFacet
/// @notice Curator-gated setters and public readers for the vault's fee parameters.
///         The actual accrual logic lives in `Vault.sol` (it needs `_mint` access),
///         while this facet owns the configuration surface.
contract FeeFacet {
    error InvalidFeeRecipient();
    error PerformanceFeeTooHigh(uint16 attemptedBps, uint16 maxBps);
    error ManagementFeeTooHigh(uint16 attemptedBps, uint16 maxBps);

    event FeeRecipientSet(address indexed recipient);
    event PerformanceFeeSet(uint16 bps);
    event ManagementFeeSet(uint16 bps);

    // -----------------------------------------------------------------------
    // Curator-gated setters
    // -----------------------------------------------------------------------

    function setFeeRecipient(address recipient) external {
        LibDiamond.enforceIsContractOwner();
        if (recipient == address(0)) revert InvalidFeeRecipient();
        LibFees.feeStorage().feeRecipient = recipient;
        emit FeeRecipientSet(recipient);
    }

    function setPerformanceFee(uint16 bps) external {
        LibDiamond.enforceIsContractOwner();
        if (bps > LibFees.MAX_PERFORMANCE_FEE_BPS) {
            revert PerformanceFeeTooHigh(bps, LibFees.MAX_PERFORMANCE_FEE_BPS);
        }
        LibFees.feeStorage().performanceFeeBps = bps;
        emit PerformanceFeeSet(bps);
    }

    function setManagementFee(uint16 bps) external {
        LibDiamond.enforceIsContractOwner();
        if (bps > LibFees.MAX_MANAGEMENT_FEE_BPS) {
            revert ManagementFeeTooHigh(bps, LibFees.MAX_MANAGEMENT_FEE_BPS);
        }
        LibFees.feeStorage().managementFeeBps = bps;
        emit ManagementFeeSet(bps);
    }

    // -----------------------------------------------------------------------
    // Readers
    // -----------------------------------------------------------------------

    function feeRecipient() external view returns (address) {
        return LibFees.feeStorage().feeRecipient;
    }

    function performanceFeeBps() external view returns (uint16) {
        return LibFees.feeStorage().performanceFeeBps;
    }

    function managementFeeBps() external view returns (uint16) {
        return LibFees.feeStorage().managementFeeBps;
    }

    function highWaterMark() external view returns (uint256) {
        return LibFees.feeStorage().highWaterMark;
    }

    function lastFeeAccrual() external view returns (uint64) {
        return LibFees.feeStorage().lastFeeAccrual;
    }
}
