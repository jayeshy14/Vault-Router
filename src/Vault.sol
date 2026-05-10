// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IDiamond} from "./interfaces/IDiamond.sol";
import {LibDiamond} from "./libraries/LibDiamond.sol";

/// @title Vault Router — modular ERC-4626 vault on the EIP-2535 Diamond pattern.
/// @notice Vault.sol owns the ERC-4626 surface (deposit/withdraw/totalAssets) and
///         acts as the Diamond proxy. Strategy logic, allocation policy, and
///         harvesting live in facets attached via diamondCut.
/// @dev Inflation attack mitigation comes from OZ ERC-4626's `_decimalsOffset`
///      virtual shares, not the literal 1 wei dead deposit pattern.
contract Vault is ERC4626 {
    error UnknownSelector(bytes4 selector);

    constructor(
        IERC20 asset_,
        string memory name_,
        string memory symbol_,
        address initialOwner,
        IDiamond.FacetCut[] memory diamondCut_,
        address init_,
        bytes memory initCalldata_
    ) ERC20(name_, symbol_) ERC4626(asset_) {
        LibDiamond.setContractOwner(initialOwner);
        LibDiamond.diamondCut(diamondCut_, init_, initCalldata_);
    }

    /// @dev 6 decimals of virtual shares — OZ's recommended inflation-attack
    ///      mitigation for ERC-4626 vaults.
    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
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

    receive() external payable {}
}
