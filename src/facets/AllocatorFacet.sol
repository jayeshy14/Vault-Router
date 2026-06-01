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
    error StrategyAlreadyQuarantined(bytes32 strategyId);
    error StrategyNotQuarantined(bytes32 strategyId);
    error AllocationToQuarantined(bytes32 strategyId);
    error RebalanceDeltaTooLarge(uint256 movementBps, uint16 maxBps);
    error IdleReserveBreached(uint256 idleAfter, uint256 requiredIdle);
    error StrategyHealthy(bytes32 strategyId);

    event StrategyRegistered(bytes32 indexed strategyId, LibAllocator.StrategyConfig config);
    event StrategyRemoved(bytes32 indexed strategyId);
    event AllocationSet(bytes32[] strategyIds, uint16[] bps);
    event IdleReserveSet(uint16 bps);
    event StrategyCapSet(bytes32 indexed strategyId, uint16 capBps);
    event GlobalStrategyCapSet(uint16 capBps);
    event Rebalanced(uint256 totalAssets, uint256 idleAfter);
    event StrategyQuarantined(bytes32 indexed strategyId);
    event StrategyReleased(bytes32 indexed strategyId);
    event MaxRebalanceDeltaSet(uint16 bps);
    event StrategyRebalanceSkipped(bytes32 indexed strategyId, bytes4 selector);

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
            if (s.quarantined[id] && b > 0) revert AllocationToQuarantined(id);
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

    /// @notice Cap the total churn a single `rebalance` may move — the sum of
    ///         |delta| across all strategies — as bps of NAV. This bounds *how
    ///         much* a rebalance can relocate, complementing the role gate
    ///         (*who*) and the one-per-block throttle (*how often*).
    /// @dev Owner-gated risk bound. `0` disables the check. Because a full
    ///      reshuffle moves each relocated dollar twice (out of one strategy and
    ///      into another), movement can reach 2x NAV (20_000 bps); the setter
    ///      therefore admits values up to 2 * BPS_DENOMINATOR.
    /// @param bps Max movement in basis points of NAV (0 = disabled).
    function setMaxRebalanceDelta(uint16 bps) external {
        LibDiamond.enforceIsContractOwner();
        if (bps > 2 * LibAllocator.BPS_DENOMINATOR) revert InvalidBps(bps);
        LibAllocator.allocatorStorage().maxRebalanceDeltaBps = bps;
        emit MaxRebalanceDeltaSet(bps);
    }

    /// @notice Isolate a strategy whose accounting can no longer be trusted (a
    ///         failing, exploited, or stuck protocol). A quarantined strategy is
    ///         excluded from `totalAssets` and skipped by the rebalancer and
    ///         harvester, so its failure can never brick deposits, withdrawals,
    ///         or fee accrual for the rest of the vault.
    /// @dev Owner-only — it changes how vault NAV is computed. The strategy's
    ///      target is zeroed so the rebalancer stops funding it. Funds already in
    ///      the strategy stay there (untouched and unvalued) until it is released;
    ///      valuing them at zero is the conservative choice over trusting a stale
    ///      or manipulable reading.
    function quarantineStrategy(bytes32 strategyId) external {
        LibDiamond.enforceIsContractOwner();
        LibAllocator.AllocatorStorage storage s = LibAllocator.allocatorStorage();
        if (!s.configs[strategyId].active) revert StrategyNotRegistered(strategyId);
        if (s.quarantined[strategyId]) revert StrategyAlreadyQuarantined(strategyId);
        s.quarantined[strategyId] = true;
        s.targetBps[strategyId] = 0;
        emit StrategyQuarantined(strategyId);
    }

    /// @notice Lift quarantine once a strategy is healthy again; its position is
    ///         counted in NAV and it becomes rebalanceable once more.
    /// @dev Owner-only. Re-funding it requires a fresh `setAllocation`, since the
    ///      target was zeroed on quarantine.
    function releaseStrategy(bytes32 strategyId) external {
        LibDiamond.enforceIsContractOwner();
        LibAllocator.AllocatorStorage storage s = LibAllocator.allocatorStorage();
        if (!s.quarantined[strategyId]) revert StrategyNotQuarantined(strategyId);
        s.quarantined[strategyId] = false;
        emit StrategyReleased(strategyId);
    }

    /// @notice Permissionlessly quarantine a strategy whose NAV read is currently
    ///         reverting, so a single broken strategy can no longer brick
    ///         `totalAssets` and every ERC-4626 entrypoint while waiting on the
    ///         owner to react.
    /// @dev Guarded by an on-chain liveness probe: it staticcalls the strategy's
    ///      own `totalAssetsSelector` and only quarantines if that call REVERTS.
    ///      A healthy strategy therefore cannot be griefed offline by anyone. The
    ///      effect mirrors `quarantineStrategy` (excluded from NAV, target zeroed);
    ///      lifting it stays owner-gated via `releaseStrategy`, since re-including
    ///      a position is a trust decision.
    function quarantineFailedStrategy(bytes32 strategyId) external {
        LibAllocator.AllocatorStorage storage s = LibAllocator.allocatorStorage();
        if (!s.configs[strategyId].active) revert StrategyNotRegistered(strategyId);
        if (s.quarantined[strategyId]) revert StrategyAlreadyQuarantined(strategyId);

        (bool ok,) = address(this).staticcall(abi.encodeWithSelector(s.configs[strategyId].totalAssetsSelector));
        if (ok) revert StrategyHealthy(strategyId);

        s.quarantined[strategyId] = true;
        s.targetBps[strategyId] = 0;
        emit StrategyQuarantined(strategyId);
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
            bytes32 id = s.strategyIds[i];
            // Isolated: never read (the read may revert) or fund a quarantined
            // strategy. currentAssets[i] stays 0, so both passes skip it too.
            if (s.quarantined[id]) continue;
            uint256 cur = _strategyTotalAssetsInternal(s.configs[id], id);
            currentAssets[i] = cur;
            totalCached += cur;
        }

        // Per-call churn bound: sum |delta| across strategies and reject the
        // rebalance if it exceeds maxRebalanceDeltaBps of NAV. Evaluated before
        // any funds move, so an over-large reshuffle never partially executes.
        // 0 disables the bound.
        uint16 maxDelta = s.maxRebalanceDeltaBps;
        if (maxDelta != 0) {
            uint256 totalMovement;
            for (uint256 i; i < n; i++) {
                bytes32 id = s.strategyIds[i];
                if (s.quarantined[id]) continue;
                uint256 target = (totalCached * uint256(s.targetBps[id])) / LibAllocator.BPS_DENOMINATOR;
                uint256 cur = currentAssets[i];
                totalMovement += cur > target ? cur - target : target - cur;
            }
            // Cross-multiply to avoid division and the totalCached == 0 case.
            if (totalMovement * LibAllocator.BPS_DENOMINATOR > totalCached * uint256(maxDelta)) {
                uint256 movementBps =
                    totalCached == 0 ? 0 : (totalMovement * LibAllocator.BPS_DENOMINATOR) / totalCached;
                revert RebalanceDeltaTooLarge(movementBps, maxDelta);
            }
        }

        // Pass 1: withdraw from over-target strategies.
        for (uint256 i; i < n; i++) {
            bytes32 id = s.strategyIds[i];
            if (s.quarantined[id]) continue;
            uint256 target = (totalCached * uint256(s.targetBps[id])) / LibAllocator.BPS_DENOMINATOR;
            if (currentAssets[i] > target) {
                uint256 delta = currentAssets[i] - target;
                // Skip (don't brick the batch) if this one strategy's withdraw
                // reverts; the idle-reserve floor below still backstops safety.
                if (!_dispatchStrategyCall(s.configs[id].withdrawSelector, delta)) {
                    emit StrategyRebalanceSkipped(id, s.configs[id].withdrawSelector);
                }
            }
        }

        // Pass 2: deposit into under-target strategies.
        for (uint256 i; i < n; i++) {
            bytes32 id = s.strategyIds[i];
            if (s.quarantined[id]) continue;
            uint256 target = (totalCached * uint256(s.targetBps[id])) / LibAllocator.BPS_DENOMINATOR;
            if (currentAssets[i] < target) {
                uint256 delta = target - currentAssets[i];
                if (!_dispatchStrategyCall(s.configs[id].depositSelector, delta)) {
                    emit StrategyRebalanceSkipped(id, s.configs[id].depositSelector);
                }
            }
        }

        // Defense-in-depth: the idle reserve floor follows from
        // `total + idleReserveBps <= 10_000` in setAllocation, but assert it on
        // realized balances too so any accounting/slippage drift that would dip
        // idle below the floor reverts the whole rebalance rather than silently
        // under-reserving.
        uint256 idleAfter = _idleAssetsInternal();
        uint256 requiredIdle = (totalCached * uint256(s.idleReserveBps)) / LibAllocator.BPS_DENOMINATOR;
        if (idleAfter < requiredIdle) revert IdleReserveBreached(idleAfter, requiredIdle);

        emit Rebalanced(totalCached, idleAfter);
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

    function maxRebalanceDelta() external view returns (uint16) {
        return LibAllocator.allocatorStorage().maxRebalanceDeltaBps;
    }

    function isQuarantined(bytes32 strategyId) external view returns (bool) {
        return LibAllocator.allocatorStorage().quarantined[strategyId];
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

    /// @dev Self-dispatches a strategy mutator (deposit/withdraw) through the
    ///      diamond fallback and reports success instead of reverting. Returning
    ///      false on an unset selector or a failed call lets `rebalance` skip a
    ///      single misbehaving strategy rather than letting it brick the whole
    ///      batch; the end-of-rebalance idle-reserve invariant still backstops
    ///      safety. `amount` is always > 0 here (callers only dispatch a non-zero
    ///      delta), so the selector is always encoded with the amount argument.
    function _dispatchStrategyCall(bytes4 selector, uint256 amount) internal returns (bool ok) {
        if (selector == bytes4(0)) return false;
        (ok,) = address(this).call(abi.encodeWithSelector(selector, amount));
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
