// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";

import { LibAllocator } from "../../src/libraries/LibAllocator.sol";
import { LibFees } from "../../src/libraries/LibFees.sol";
import { LibGuard } from "../../src/libraries/LibGuard.sol";
import { LibLock } from "../../src/libraries/LibLock.sol";
import { LibRoles } from "../../src/libraries/LibRoles.sol";
import { LibWithdrawQueue } from "../../src/libraries/LibWithdrawQueue.sol";
import { AaveStrategyFacet } from "../../src/facets/strategies/AaveStrategyFacet.sol";
import { MorphoStrategyFacet } from "../../src/facets/strategies/MorphoStrategyFacet.sol";
import { PendlePtStrategyFacet } from "../../src/facets/strategies/PendlePtStrategyFacet.sol";
import { CompoundV3StrategyFacet } from "../../src/facets/strategies/CompoundV3StrategyFacet.sol";

// The strategy facets keep their slot constant `internal` at contract scope, which is not
// reachable via qualified access, so a thin heir exposes it for the invariant check.
contract AaveExposer is AaveStrategyFacet {
    function exposedSlot() external pure returns (bytes32) {
        return AAVE_STORAGE_SLOT;
    }
}

contract MorphoExposer is MorphoStrategyFacet {
    function exposedSlot() external pure returns (bytes32) {
        return MORPHO_STORAGE_SLOT;
    }
}

contract PendleExposer is PendlePtStrategyFacet {
    function exposedSlot() external pure returns (bytes32) {
        return PENDLE_STORAGE_SLOT;
    }
}

contract CompoundExposer is CompoundV3StrategyFacet {
    function exposedSlot() external pure returns (bytes32) {
        return COMPOUND_STORAGE_SLOT;
    }
}

/// @title Storage namespace invariant
/// @notice Every precomputed storage-slot literal in the protocol must equal the ERC-7201
///         hash of its declared namespace string. This pins each named literal to its
///         namespace so the two can never silently drift: change a namespace string
///         without recomputing the slot, or paste a wrong literal, and this test fails.
/// @dev The detector proves slots do not collide with each other; this proves each slot
///      is the one its namespace actually resolves to.
contract StorageNamespacesTest is Test {
    /// @dev erc7201(id) = keccak256(abi.encode(uint256(keccak256(id)) - 1)) & ~bytes32(uint256(0xff))
    function _erc7201(string memory id) internal pure returns (bytes32) {
        return keccak256(abi.encode(uint256(keccak256(bytes(id))) - 1)) & ~bytes32(uint256(0xff));
    }

    function test_storageSlotsMatchTheirNamespaces() public {
        assertEq(LibAllocator.ALLOCATOR_STORAGE_SLOT, _erc7201("vaultrouter.storage.allocator"), "allocator");
        assertEq(LibFees.FEE_STORAGE_SLOT, _erc7201("vaultrouter.storage.fees"), "fees");
        assertEq(LibGuard.GUARD_STORAGE_SLOT, _erc7201("vaultrouter.storage.guard"), "guard");
        assertEq(LibLock.LOCK_STORAGE_SLOT, _erc7201("vaultrouter.storage.lock"), "lock");
        assertEq(LibRoles.ROLES_STORAGE_SLOT, _erc7201("vaultrouter.storage.roles"), "roles");
        assertEq(
            LibWithdrawQueue.WITHDRAW_QUEUE_STORAGE_SLOT, _erc7201("vaultrouter.storage.withdrawqueue"), "withdrawqueue"
        );
        assertEq(new AaveExposer().exposedSlot(), _erc7201("vaultrouter.strategy.aave"), "aave");
        assertEq(new MorphoExposer().exposedSlot(), _erc7201("vaultrouter.strategy.morpho"), "morpho");
        assertEq(new PendleExposer().exposedSlot(), _erc7201("vaultrouter.strategy.pendle"), "pendle");
        assertEq(new CompoundExposer().exposedSlot(), _erc7201("vaultrouter.strategy.compound"), "compound");
    }
}
