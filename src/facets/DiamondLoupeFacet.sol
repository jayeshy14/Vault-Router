// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IDiamondLoupe} from "../interfaces/IDiamondLoupe.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";

contract DiamondLoupeFacet is IDiamondLoupe {
    /// @inheritdoc IDiamondLoupe
    function facets() external view override returns (Facet[] memory facets_) {
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        uint256 numFacets = ds.facetAddresses.length;
        facets_ = new Facet[](numFacets);
        for (uint256 i; i < numFacets; i++) {
            address facetAddress_ = ds.facetAddresses[i];
            facets_[i] = Facet({
                facetAddress: facetAddress_,
                functionSelectors: ds.facetFunctionSelectors[facetAddress_].functionSelectors
            });
        }
    }

    /// @inheritdoc IDiamondLoupe
    function facetFunctionSelectors(address _facet)
        external
        view
        override
        returns (bytes4[] memory facetFunctionSelectors_)
    {
        facetFunctionSelectors_ = LibDiamond.diamondStorage().facetFunctionSelectors[_facet].functionSelectors;
    }

    /// @inheritdoc IDiamondLoupe
    function facetAddresses() external view override returns (address[] memory facetAddresses_) {
        facetAddresses_ = LibDiamond.diamondStorage().facetAddresses;
    }

    /// @inheritdoc IDiamondLoupe
    function facetAddress(bytes4 _functionSelector) external view override returns (address facetAddress_) {
        facetAddress_ = LibDiamond.diamondStorage().selectorToFacetAndPosition[_functionSelector].facetAddress;
    }
}
