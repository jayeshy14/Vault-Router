// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import { LibDiamond } from "../libraries/LibDiamond.sol";
import { LibRoles } from "../libraries/LibRoles.sol";
import { LibAllocator } from "../libraries/LibAllocator.sol";

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
    error AllocationExceedsCap(bytes32 strategyId, uint16 capBps, uint16 attemptedBps);
    error InvalidBps(uint16 bps);
    error EmptySelector();
    error StrategyTotalAssetsCallFailed(bytes32 strategyId);
    error StrategyCallFailed(bytes32 strategyId, bytes4 selector);
    error RebalanceTooSoon(uint256 lastBlock, uint256 currentBlock);

    event StrategyRegistered(bytes32 indexed strategyId, LibAllocator.StrategyConfig config);
    event StrategyRemoved(bytes32 indexed strategyId);
    event AllocationSet(bytes32[] strategyIds, uint16[] bps);
    event IdleReserveSet(uint16 bps);
    event StrategyCapSet(bytes32 indexed strategyId, uint16 capBps);
    event GlobalStrategyCapSet(uint16 capBps);
    event Rebalanced(uint256 totalAssets, uint256 idleAfter);

    // -----------------------------------------------------------------------
    // Owner-gated governance / risk bounds
    // -----------------------------------------------------------------------
    // Registering strategies and setting caps / idle floor define the bounds the
    // curator must operate within, so they stay owner-only. `setAllocation` (a
    // policy choice within those bounds) and `rebalance` are curator-gated below.

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

    // -----------------------------------------------------------------------
    // Curator-gated operations (allocation policy within owner-set bounds)
    // -----------------------------------------------------------------------

    function setAllocation(bytes32[] calldata strategyIds, uint16[] calldata bps) external {
        LibRoles.enforceIsCurator();
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
            uint16 cap = _effectiveCap(s, id);
            if (b > cap) revert AllocationExceedsCap(id, cap, b);
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

    function setStrategyCap(bytes32 strategyId, uint16 capBps) external {
        LibDiamond.enforceIsContractOwner();
        if (capBps > LibAllocator.BPS_DENOMINATOR) revert InvalidBps(capBps);
        LibAllocator.AllocatorStorage storage s = LibAllocator.allocatorStorage();
        if (!s.configs[strategyId].active) revert StrategyNotRegistered(strategyId);
        s.configs[strategyId].capBps = capBps;
        emit StrategyCapSet(strategyId, capBps);
    }

    function setGlobalStrategyCap(uint16 capBps) external {
        LibDiamond.enforceIsContractOwner();
        if (capBps > LibAllocator.BPS_DENOMINATOR) revert InvalidBps(capBps);
        LibAllocator.allocatorStorage().globalMaxStrategyCapBps = capBps;
        emit GlobalStrategyCapSet(capBps);
    }

    // -----------------------------------------------------------------------
    // Rebalance
    // -----------------------------------------------------------------------

    /// @notice Brings each strategy's holdings to its target allocation.
    /// @dev Two passes: withdraw from over-allocated strategies first to free
    ///      idle balance, then deposit into under-allocated ones. The per-strategy
    ///      cap is enforced upstream in `setAllocation`; the idle-reserve floor
    ///      follows automatically from `total + idleReserveBps ≤ 10_000`.
    function rebalance() external {
        LibRoles.enforceIsCurator();
        LibAllocator.AllocatorStorage storage s = LibAllocator.allocatorStorage();
        if (block.number <= uint256(s.lastRebalanceBlock)) {
            revert RebalanceTooSoon(uint256(s.lastRebalanceBlock), block.number);
        }
        s.lastRebalanceBlock = uint64(block.number);

        uint256 n = s.strategyIds.length;
        uint256[] memory currentAssets = new uint256[](n);
        uint256 totalCached = _idleAssetsInternal();
        for (uint256 i; i < n; i++) {
            uint256 cur = _strategyTotalAssetsInternal(s.configs[s.strategyIds[i]], s.strategyIds[i]);
            currentAssets[i] = cur;
            totalCached += cur;
        }

        // Pass 1: withdraw from over-target strategies.
        for (uint256 i; i < n; i++) {
            bytes32 id = s.strategyIds[i];
            uint256 target = (totalCached * uint256(s.targetBps[id])) / LibAllocator.BPS_DENOMINATOR;
            if (currentAssets[i] > target) {
                uint256 delta = currentAssets[i] - target;
                _dispatchStrategyCall(id, s.configs[id].withdrawSelector, delta);
            }
        }

        // Pass 2: deposit into under-target strategies.
        for (uint256 i; i < n; i++) {
            bytes32 id = s.strategyIds[i];
            uint256 target = (totalCached * uint256(s.targetBps[id])) / LibAllocator.BPS_DENOMINATOR;
            if (currentAssets[i] < target) {
                uint256 delta = target - currentAssets[i];
                _dispatchStrategyCall(id, s.configs[id].depositSelector, delta);
            }
        }

        emit Rebalanced(totalCached, _idleAssetsInternal());
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
        (bool ok, bytes memory data) = address(this).staticcall(abi.encodeWithSelector(cfg.totalAssetsSelector));
        if (!ok) revert StrategyTotalAssetsCallFailed(strategyId);
        return abi.decode(data, (uint256));
    }

    /// @notice Asset balance currently sitting idle in the vault.
    function idleAssets() external view returns (uint256) {
        return _idleAssetsInternal();
    }

    function strategyCap(bytes32 strategyId) external view returns (uint16) {
        return _effectiveCap(LibAllocator.allocatorStorage(), strategyId);
    }

    function globalStrategyCap() external view returns (uint16) {
        return LibAllocator.allocatorStorage().globalMaxStrategyCapBps;
    }

    function lastRebalanceBlock() external view returns (uint64) {
        return LibAllocator.allocatorStorage().lastRebalanceBlock;
    }

    // -----------------------------------------------------------------------
    // Internals
    // -----------------------------------------------------------------------

    function _idleAssetsInternal() internal view returns (uint256) {
        address asset = IERC4626(address(this)).asset();
        return IERC20(asset).balanceOf(address(this));
    }

    function _strategyTotalAssetsInternal(
        LibAllocator.StrategyConfig memory cfg,
        bytes32 strategyId
    )
        internal
        view
        returns (uint256)
    {
        (bool ok, bytes memory data) = address(this).staticcall(abi.encodeWithSelector(cfg.totalAssetsSelector));
        if (!ok) revert StrategyTotalAssetsCallFailed(strategyId);
        return abi.decode(data, (uint256));
    }

    function _dispatchStrategyCall(bytes32 strategyId, bytes4 selector, uint256 amount) internal {
        if (selector == bytes4(0)) revert EmptySelector();
        bytes memory data;
        if (amount == 0) {
            data = abi.encodeWithSelector(selector);
        } else {
            data = abi.encodeWithSelector(selector, amount);
        }
        (bool ok, bytes memory ret) = address(this).call(data);
        if (!ok) {
            if (ret.length > 0) {
                assembly {
                    revert(add(32, ret), mload(ret))
                }
            }
            revert StrategyCallFailed(strategyId, selector);
        }
    }

    function _effectiveCap(LibAllocator.AllocatorStorage storage s, bytes32 strategyId) internal view returns (uint16) {
        uint16 perStrategy = s.configs[strategyId].capBps;
        uint16 glob = s.globalMaxStrategyCapBps;
        if (perStrategy == 0 && glob == 0) return LibAllocator.BPS_DENOMINATOR;
        if (perStrategy == 0) return glob;
        if (glob == 0) return perStrategy;
        return perStrategy < glob ? perStrategy : glob;
    }
}
