// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { LibRoles } from "../libraries/LibRoles.sol";
import { LibAllocator } from "../libraries/LibAllocator.sol";

/// @title HarvestFacet
/// @notice Curator-triggered harvest. Invokes the per-strategy harvest selector
///         registered in `LibAllocator`, which typically claims reward tokens
///         and either swaps/reinvests them into the underlying asset or returns
///         them to the vault as idle balance.
/// @dev Harvesting is intentionally separate from rebalancing. A curator may
///      want to harvest without rebalancing, or harvest before a rebalance to
///      ensure rewards are accounted for in the new allocation target.
contract HarvestFacet {
    error StrategyNotRegistered(bytes32 strategyId);
    error StrategyCallFailed(bytes32 strategyId, bytes4 selector);

    event StrategyHarvested(bytes32 indexed strategyId);

    /// @notice Harvest a single strategy by id.
    /// @dev No-op (but still emits) when the strategy registered a zero
    ///      `harvestSelector` — useful for protocols where rewards auto-accrue
    ///      (Aave aTokens, Morpho lender shares) and no explicit claim is needed.
    function harvest(bytes32 strategyId) external {
        LibRoles.enforceIsCurator();
        LibAllocator.StrategyConfig memory cfg = LibAllocator.allocatorStorage().configs[strategyId];
        if (!cfg.active) revert StrategyNotRegistered(strategyId);
        if (cfg.harvestSelector != bytes4(0)) {
            (bool ok, bytes memory ret) = address(this).call(abi.encodeWithSelector(cfg.harvestSelector));
            if (!ok) {
                if (ret.length > 0) {
                    assembly {
                        revert(add(32, ret), mload(ret))
                    }
                }
                revert StrategyCallFailed(strategyId, cfg.harvestSelector);
            }
        }
        emit StrategyHarvested(strategyId);
    }

    /// @notice Harvest every registered strategy in registration order.
    function harvestAll() external {
        LibRoles.enforceIsCurator();
        LibAllocator.AllocatorStorage storage s = LibAllocator.allocatorStorage();
        uint256 n = s.strategyIds.length;
        for (uint256 i; i < n; i++) {
            bytes32 id = s.strategyIds[i];
            LibAllocator.StrategyConfig memory cfg = s.configs[id];
            if (!cfg.active) continue;
            if (s.quarantined[id]) continue; // isolated: don't let a failing strategy break harvestAll
            if (cfg.harvestSelector != bytes4(0)) {
                (bool ok, bytes memory ret) = address(this).call(abi.encodeWithSelector(cfg.harvestSelector));
                if (!ok) {
                    if (ret.length > 0) {
                        assembly {
                            revert(add(32, ret), mload(ret))
                        }
                    }
                    revert StrategyCallFailed(id, cfg.harvestSelector);
                }
            }
            emit StrategyHarvested(id);
        }
    }
}
