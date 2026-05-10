// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IDiamond} from "../interfaces/IDiamond.sol";
import {IDiamondCut} from "../interfaces/IDiamondCut.sol";

library LibDiamond {
    bytes32 internal constant DIAMOND_STORAGE_POSITION = keccak256("diamond.standard.diamond.storage");

    struct FacetAddressAndPosition {
        address facetAddress;
        uint96 functionSelectorPosition;
    }

    struct FacetFunctionSelectors {
        bytes4[] functionSelectors;
        uint256 facetAddressPosition;
    }

    struct DiamondStorage {
        mapping(bytes4 => FacetAddressAndPosition) selectorToFacetAndPosition;
        mapping(address => FacetFunctionSelectors) facetFunctionSelectors;
        address[] facetAddresses;
        mapping(bytes4 => bool) supportedInterfaces;
        address contractOwner;
    }

    error NotContractOwner(address caller, address expected);
    error NoSelectorsProvided(address facetAddress);
    error CannotAddSelectorsToZeroAddress(bytes4[] selectors);
    error NoBytecodeAtAddress(address facetAddress, string message);
    error IncorrectFacetCutAction(uint8 action);
    error CannotAddFunctionThatAlreadyExists(bytes4 selector);
    error CannotReplaceFunctionsFromFacetWithZeroAddress(bytes4[] selectors);
    error CannotReplaceImmutableFunction(bytes4 selector);
    error CannotReplaceFunctionWithSameFunctionFromSameFacet(bytes4 selector);
    error CannotReplaceFunctionThatDoesNotExist(bytes4 selector);
    error RemoveFacetAddressMustBeZeroAddress(address facetAddress);
    error CannotRemoveFunctionThatDoesNotExist(bytes4 selector);
    error CannotRemoveImmutableFunction(bytes4 selector);
    error InitializationFunctionReverted(address initAddress, bytes initCalldata);

    function diamondStorage() internal pure returns (DiamondStorage storage ds) {
        bytes32 position = DIAMOND_STORAGE_POSITION;
        assembly {
            ds.slot := position
        }
    }

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    function setContractOwner(address _newOwner) internal {
        DiamondStorage storage ds = diamondStorage();
        address previousOwner = ds.contractOwner;
        ds.contractOwner = _newOwner;
        emit OwnershipTransferred(previousOwner, _newOwner);
    }

    function contractOwner() internal view returns (address contractOwner_) {
        contractOwner_ = diamondStorage().contractOwner;
    }

    function enforceIsContractOwner() internal view {
        if (msg.sender != diamondStorage().contractOwner) {
            revert NotContractOwner(msg.sender, diamondStorage().contractOwner);
        }
    }

    event DiamondCut(IDiamond.FacetCut[] _diamondCut, address _init, bytes _calldata);

    function diamondCut(IDiamond.FacetCut[] memory _diamondCut, address _init, bytes memory _calldata) internal {
        for (uint256 i; i < _diamondCut.length; i++) {
            IDiamond.FacetCutAction action = _diamondCut[i].action;
            bytes4[] memory selectors = _diamondCut[i].functionSelectors;
            address facet = _diamondCut[i].facetAddress;
            if (selectors.length == 0) revert NoSelectorsProvided(facet);
            if (action == IDiamond.FacetCutAction.Add) {
                addFunctions(facet, selectors);
            } else if (action == IDiamond.FacetCutAction.Replace) {
                replaceFunctions(facet, selectors);
            } else if (action == IDiamond.FacetCutAction.Remove) {
                removeFunctions(facet, selectors);
            } else {
                revert IncorrectFacetCutAction(uint8(action));
            }
        }
        emit DiamondCut(_diamondCut, _init, _calldata);
        initializeDiamondCut(_init, _calldata);
    }

    function addFunctions(address _facetAddress, bytes4[] memory _functionSelectors) internal {
        if (_facetAddress == address(0)) revert CannotAddSelectorsToZeroAddress(_functionSelectors);
        DiamondStorage storage ds = diamondStorage();
        uint96 selectorPosition = uint96(ds.facetFunctionSelectors[_facetAddress].functionSelectors.length);
        if (selectorPosition == 0) {
            addFacet(ds, _facetAddress);
        }
        for (uint256 i; i < _functionSelectors.length; i++) {
            bytes4 selector = _functionSelectors[i];
            address oldFacet = ds.selectorToFacetAndPosition[selector].facetAddress;
            if (oldFacet != address(0)) revert CannotAddFunctionThatAlreadyExists(selector);
            addFunction(ds, selector, selectorPosition, _facetAddress);
            selectorPosition++;
        }
    }

    function replaceFunctions(address _facetAddress, bytes4[] memory _functionSelectors) internal {
        if (_facetAddress == address(0)) revert CannotReplaceFunctionsFromFacetWithZeroAddress(_functionSelectors);
        DiamondStorage storage ds = diamondStorage();
        uint96 selectorPosition = uint96(ds.facetFunctionSelectors[_facetAddress].functionSelectors.length);
        if (selectorPosition == 0) {
            addFacet(ds, _facetAddress);
        }
        for (uint256 i; i < _functionSelectors.length; i++) {
            bytes4 selector = _functionSelectors[i];
            address oldFacet = ds.selectorToFacetAndPosition[selector].facetAddress;
            if (oldFacet == address(this)) revert CannotReplaceImmutableFunction(selector);
            if (oldFacet == _facetAddress) revert CannotReplaceFunctionWithSameFunctionFromSameFacet(selector);
            if (oldFacet == address(0)) revert CannotReplaceFunctionThatDoesNotExist(selector);
            removeFunction(ds, oldFacet, selector);
            addFunction(ds, selector, selectorPosition, _facetAddress);
            selectorPosition++;
        }
    }

    function removeFunctions(address _facetAddress, bytes4[] memory _functionSelectors) internal {
        if (_facetAddress != address(0)) revert RemoveFacetAddressMustBeZeroAddress(_facetAddress);
        DiamondStorage storage ds = diamondStorage();
        for (uint256 i; i < _functionSelectors.length; i++) {
            bytes4 selector = _functionSelectors[i];
            address oldFacet = ds.selectorToFacetAndPosition[selector].facetAddress;
            removeFunction(ds, oldFacet, selector);
        }
    }

    function addFacet(DiamondStorage storage ds, address _facetAddress) internal {
        enforceHasContractCode(_facetAddress, "LibDiamond: facet has no code");
        ds.facetFunctionSelectors[_facetAddress].facetAddressPosition = ds.facetAddresses.length;
        ds.facetAddresses.push(_facetAddress);
    }

    function addFunction(DiamondStorage storage ds, bytes4 _selector, uint96 _selectorPosition, address _facetAddress)
        internal
    {
        ds.selectorToFacetAndPosition[_selector].functionSelectorPosition = _selectorPosition;
        ds.facetFunctionSelectors[_facetAddress].functionSelectors.push(_selector);
        ds.selectorToFacetAndPosition[_selector].facetAddress = _facetAddress;
    }

    function removeFunction(DiamondStorage storage ds, address _facetAddress, bytes4 _selector) internal {
        if (_facetAddress == address(0)) revert CannotRemoveFunctionThatDoesNotExist(_selector);
        if (_facetAddress == address(this)) revert CannotRemoveImmutableFunction(_selector);
        // Replace selector with last selector, then delete last selector
        uint256 selectorPosition = ds.selectorToFacetAndPosition[_selector].functionSelectorPosition;
        uint256 lastSelectorPosition = ds.facetFunctionSelectors[_facetAddress].functionSelectors.length - 1;
        if (selectorPosition != lastSelectorPosition) {
            bytes4 lastSelector = ds.facetFunctionSelectors[_facetAddress].functionSelectors[lastSelectorPosition];
            ds.facetFunctionSelectors[_facetAddress].functionSelectors[selectorPosition] = lastSelector;
            ds.selectorToFacetAndPosition[lastSelector].functionSelectorPosition = uint96(selectorPosition);
        }
        ds.facetFunctionSelectors[_facetAddress].functionSelectors.pop();
        delete ds.selectorToFacetAndPosition[_selector];

        // If this was the last selector, remove the facet address as well
        if (lastSelectorPosition == 0) {
            uint256 lastFacetAddressPosition = ds.facetAddresses.length - 1;
            uint256 facetAddressPosition = ds.facetFunctionSelectors[_facetAddress].facetAddressPosition;
            if (facetAddressPosition != lastFacetAddressPosition) {
                address lastFacetAddress = ds.facetAddresses[lastFacetAddressPosition];
                ds.facetAddresses[facetAddressPosition] = lastFacetAddress;
                ds.facetFunctionSelectors[lastFacetAddress].facetAddressPosition = facetAddressPosition;
            }
            ds.facetAddresses.pop();
            delete ds.facetFunctionSelectors[_facetAddress].facetAddressPosition;
        }
    }

    function initializeDiamondCut(address _init, bytes memory _calldata) internal {
        if (_init == address(0)) return;
        enforceHasContractCode(_init, "LibDiamond: _init has no code");
        (bool success, bytes memory error) = _init.delegatecall(_calldata);
        if (!success) {
            if (error.length > 0) {
                // bubble up the revert reason
                assembly {
                    let returndata_size := mload(error)
                    revert(add(32, error), returndata_size)
                }
            } else {
                revert InitializationFunctionReverted(_init, _calldata);
            }
        }
    }

    function enforceHasContractCode(address _contract, string memory _errorMessage) internal view {
        uint256 contractSize;
        assembly {
            contractSize := extcodesize(_contract)
        }
        if (contractSize == 0) revert NoBytecodeAtAddress(_contract, _errorMessage);
    }
}
