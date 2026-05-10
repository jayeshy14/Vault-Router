// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {LibDiamond} from "../libraries/LibDiamond.sol";
import {LibAllocator} from "../libraries/LibAllocator.sol";

/// @title AllocatorFacet
/// @notice Curator-controlled allocation policy. Registers strategy facets,
///         tracks per-strategy target allocations in basis points, and exposes
///         readers used by the rebalancer and reporting.
/// @dev "Idle" is implicit: any vault balance not allocated to a registered
///      strategy is the idle reserve. The allocator only tracks explicit
///      strategies and the idle-reserve floor.
contract AllocatorFacet {
    error StrategyAlreadyRegistered(bytes32 strategyId);
    error StrategyNotRegistered(bytes32 strategyId);
    error AllocationLengthMismatch(uint256 idsLength, uint256 bpsLength);
    error AllocationExceedsBudget(uint16 totalBps, uint16 maxBps);
    error InvalidBps(uint16 bps);
    error EmptySelector();
    error StrategyTotalAssetsCallFailed(bytes32 strategyId);

    event StrategyRegistered(bytes32 indexed strategyId, LibAllocator.StrategyConfig config);
    event StrategyRemoved(bytes32 indexed strategyId);
    event AllocationSet(bytes32[] strategyIds, uint16[] bps);
    event IdleReserveSet(uint16 bps);

    // -----------------------------------------------------------------------
    // Curator-gated setters
    // -----------------------------------------------------------------------

    function registerStrategy(bytes32 strategyId, LibAllocator.StrategyConfig calldata config) external {
        LibDiamond.enforceIsContractOwner();
        if (
            config.totalAssetsSelector == bytes4(0) || config.depositSelector == bytes4(0)
                || config.withdrawSelector == bytes4(0)
        ) {
            revert EmptySelector();
        }
        LibAllocator.AllocatorStorage storage s = LibAllocator.allocatorStorage();
        if (s.configs[strategyId].active) revert StrategyAlreadyRegistered(strategyId);

        LibAllocator.StrategyConfig memory cfg = config;
        cfg.active = true;
        s.configs[strategyId] = cfg;
        s.strategyIds.push(strategyId);

        emit StrategyRegistered(strategyId, cfg);
    }

    function removeStrategy(bytes32 strategyId) external {
        LibDiamond.enforceIsContractOwner();
        LibAllocator.AllocatorStorage storage s = LibAllocator.allocatorStorage();
        if (!s.configs[strategyId].active) revert StrategyNotRegistered(strategyId);

        // Linear scan; small list (≤ ~10 strategies in practice). Swap-and-pop.
        uint256 len = s.strategyIds.length;
        for (uint256 i; i < len; i++) {
            if (s.strategyIds[i] == strategyId) {
                if (i != len - 1) s.strategyIds[i] = s.strategyIds[len - 1];
                s.strategyIds.pop();
                break;
            }
        }
        delete s.configs[strategyId];
        delete s.targetBps[strategyId];

        emit StrategyRemoved(strategyId);
    }

    function setAllocation(bytes32[] calldata strategyIds, uint16[] calldata bps) external {
        LibDiamond.enforceIsContractOwner();
        if (strategyIds.length != bps.length) revert AllocationLengthMismatch(strategyIds.length, bps.length);

        LibAllocator.AllocatorStorage storage s = LibAllocator.allocatorStorage();
        uint16 maxAllocatable = LibAllocator.BPS_DENOMINATOR - s.idleReserveBps;

        // Reset every existing target before applying the new policy.
        uint256 existing = s.strategyIds.length;
        for (uint256 i; i < existing; i++) {
            s.targetBps[s.strategyIds[i]] = 0;
        }

        uint16 total;
        for (uint256 i; i < strategyIds.length; i++) {
            bytes32 id = strategyIds[i];
            uint16 b = bps[i];
            if (!s.configs[id].active) revert StrategyNotRegistered(id);
            if (b > LibAllocator.BPS_DENOMINATOR) revert InvalidBps(b);
            s.targetBps[id] = b;
            total += b;
        }
        if (total > maxAllocatable) revert AllocationExceedsBudget(total, maxAllocatable);

        emit AllocationSet(strategyIds, bps);
    }

    function setIdleReserve(uint16 bps) external {
        LibDiamond.enforceIsContractOwner();
        if (bps > LibAllocator.BPS_DENOMINATOR) revert InvalidBps(bps);
        LibAllocator.allocatorStorage().idleReserveBps = bps;
        emit IdleReserveSet(bps);
    }

    // -----------------------------------------------------------------------
    // Readers
    // -----------------------------------------------------------------------

    function strategies() external view returns (bytes32[] memory) {
        return LibAllocator.allocatorStorage().strategyIds;
    }

    function strategyConfig(bytes32 strategyId) external view returns (LibAllocator.StrategyConfig memory) {
        return LibAllocator.allocatorStorage().configs[strategyId];
    }

    function targetAllocation(bytes32 strategyId) external view returns (uint16) {
        return LibAllocator.allocatorStorage().targetBps[strategyId];
    }

    function idleReserveBps() external view returns (uint16) {
        return LibAllocator.allocatorStorage().idleReserveBps;
    }

    /// @notice Asset balance currently held by `strategyId`. Self-staticcalls
    ///         the strategy facet's totalAssets selector via the Diamond fallback.
    function strategyTotalAssets(bytes32 strategyId) external view returns (uint256) {
        LibAllocator.StrategyConfig memory cfg = LibAllocator.allocatorStorage().configs[strategyId];
        if (!cfg.active) revert StrategyNotRegistered(strategyId);
        (bool ok, bytes memory data) =
            address(this).staticcall(abi.encodeWithSelector(cfg.totalAssetsSelector));
        if (!ok) revert StrategyTotalAssetsCallFailed(strategyId);
        return abi.decode(data, (uint256));
    }

    /// @notice Asset balance currently sitting idle in the vault.
    function idleAssets() external view returns (uint256) {
        address asset = IERC4626(address(this)).asset();
        return IERC20(asset).balanceOf(address(this));
    }
}
