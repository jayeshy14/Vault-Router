// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IDiamond } from "./interfaces/IDiamond.sol";
import { LibDiamond } from "./libraries/LibDiamond.sol";

/// @title Diamond — EIP-2535 proxy mechanics.
/// @notice The pure plumbing of the diamond: it wires the initial facet set and
///         ownership at construction, then routes every unknown selector to its
///         facet via a delegatecall fallback. It carries no application logic.
/// @dev Vault inherits this for its diamond surface and layers the ERC-4626 vault
///      surface on top. ERC-4626's own functions are native (compiled into Vault),
///      so Solidity dispatches them directly; only selectors with no native match
///      reach this fallback and are delegated to facets. Keeping the proxy
///      mechanics here leaves Vault.sol focused on the vault economics.
abstract contract Diamond {
    error UnknownSelector(bytes4 selector);

    /// @param initialOwner   Diamond owner (facet upgrades, risk bounds, fees).
    /// @param diamondCut_    Initial facet cuts applied at deployment.
    /// @param init_          Optional initializer delegatecall target (0 to skip).
    /// @param initCalldata_  Calldata for the initializer.
    constructor(
        address initialOwner,
        IDiamond.FacetCut[] memory diamondCut_,
        address init_,
        bytes memory initCalldata_
    ) {
        LibDiamond.setContractOwner(initialOwner);
        LibDiamond.diamondCut(diamondCut_, init_, initCalldata_);
    }

    fallback() external payable {
        LibDiamond.DiamondStorage storage ds;
        bytes32 position = LibDiamond.DIAMOND_STORAGE_POSITION;
        assembly {
            ds.slot := position
        }
        address facet = ds.selectorToFacetAndPosition[msg.sig].facetAddress;
        if (facet == address(0)) revert UnknownSelector(msg.sig);
        assembly {
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), facet, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch result
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }

    receive() external payable { }
}
