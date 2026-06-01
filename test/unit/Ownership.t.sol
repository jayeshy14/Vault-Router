// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { Vault } from "../../src/Vault.sol";
import { IDiamond } from "../../src/interfaces/IDiamond.sol";
import { IDiamondCut } from "../../src/interfaces/IDiamondCut.sol";
import { IDiamondLoupe } from "../../src/interfaces/IDiamondLoupe.sol";
import { IERC173 } from "../../src/interfaces/IERC173.sol";
import { DiamondCutFacet } from "../../src/facets/DiamondCutFacet.sol";
import { DiamondLoupeFacet } from "../../src/facets/DiamondLoupeFacet.sol";
import { OwnershipFacet } from "../../src/facets/OwnershipFacet.sol";
import { LibDiamond } from "../../src/libraries/LibDiamond.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") { }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

/// @title OwnershipTest
/// @notice Coverage for the two-step ownership transfer (F02): `transferOwnership`
///         only NOMINATES a pending owner; the transfer completes only when that
///         address calls `acceptOwnership`. This makes a mistaken or malicious
///         handoff recoverable and makes it impossible to lose ownership to the
///         zero address, since address(0) can never accept.
contract OwnershipTest is Test {
    MockUSDC internal usdc;
    Vault internal vault;

    address internal owner = makeAddr("owner");
    address internal newOwner = makeAddr("newOwner");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        usdc = new MockUSDC();
        vault = _deployVault();
    }

    function _of() internal view returns (OwnershipFacet) {
        return OwnershipFacet(address(vault));
    }

    function test_TransferOwnership_NominatesButDoesNotTransfer() public {
        vm.prank(owner);
        _of().transferOwnership(newOwner);

        assertEq(_of().owner(), owner, "ownership unchanged until accepted");
        assertEq(_of().pendingOwner(), newOwner, "pending owner recorded");
    }

    function test_TransferOwnership_OwnerOnly() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(LibDiamond.NotContractOwner.selector, stranger, owner));
        _of().transferOwnership(newOwner);
    }

    function test_AcceptOwnership_CompletesTransfer() public {
        vm.prank(owner);
        _of().transferOwnership(newOwner);

        vm.prank(newOwner);
        _of().acceptOwnership();

        assertEq(_of().owner(), newOwner, "ownership moved to acceptor");
        assertEq(_of().pendingOwner(), address(0), "pending cleared after acceptance");
    }

    function test_AcceptOwnership_RevertsForNonPending() public {
        vm.prank(owner);
        _of().transferOwnership(newOwner);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(OwnershipFacet.NotPendingOwner.selector, stranger, newOwner));
        _of().acceptOwnership();
    }

    function test_TransferOwnership_CanBeCancelled() public {
        vm.prank(owner);
        _of().transferOwnership(newOwner);

        // Owner cancels by nominating the zero address.
        vm.prank(owner);
        _of().transferOwnership(address(0));
        assertEq(_of().pendingOwner(), address(0), "nomination cleared");

        // The former nominee can no longer take over.
        vm.prank(newOwner);
        vm.expectRevert(abi.encodeWithSelector(OwnershipFacet.NotPendingOwner.selector, newOwner, address(0)));
        _of().acceptOwnership();
        assertEq(_of().owner(), owner, "owner retained control");
    }

    /// @notice The headline F02 property: ownership can never be lost to the zero
    ///         address. Even a "transfer" to address(0) does not move ownership,
    ///         and nobody can accept it.
    function test_OwnershipCannotBeLostToZeroAddress() public {
        vm.prank(owner);
        _of().transferOwnership(address(0));

        assertEq(_of().owner(), owner, "owner unchanged by a zero-address transfer");

        // address(0) cannot call acceptOwnership, so ownership stays put — there is
        // no path by which a fat-fingered zero address bricks governance.
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(OwnershipFacet.NotPendingOwner.selector, stranger, address(0)));
        _of().acceptOwnership();
    }

    function _deployVault() internal returns (Vault) {
        DiamondCutFacet cut = new DiamondCutFacet();
        DiamondLoupeFacet loupe = new DiamondLoupeFacet();
        OwnershipFacet ownership = new OwnershipFacet();

        IDiamond.FacetCut[] memory cuts = new IDiamond.FacetCut[](3);
        cuts[0] = IDiamond.FacetCut({
            facetAddress: address(cut), action: IDiamond.FacetCutAction.Add, functionSelectors: _diamondCutSelectors()
        });
        cuts[1] = IDiamond.FacetCut({
            facetAddress: address(loupe),
            action: IDiamond.FacetCutAction.Add,
            functionSelectors: _diamondLoupeSelectors()
        });
        cuts[2] = IDiamond.FacetCut({
            facetAddress: address(ownership),
            action: IDiamond.FacetCutAction.Add,
            functionSelectors: _ownershipSelectors()
        });

        return new Vault(IERC20(address(usdc)), "Vault Router", "vUSDC", owner, cuts, address(0), "");
    }

    function _diamondCutSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](1);
        s[0] = IDiamondCut.diamondCut.selector;
    }

    function _diamondLoupeSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](4);
        s[0] = IDiamondLoupe.facets.selector;
        s[1] = IDiamondLoupe.facetFunctionSelectors.selector;
        s[2] = IDiamondLoupe.facetAddresses.selector;
        s[3] = IDiamondLoupe.facetAddress.selector;
    }

    function _ownershipSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](4);
        s[0] = IERC173.owner.selector;
        s[1] = IERC173.transferOwnership.selector;
        s[2] = OwnershipFacet.acceptOwnership.selector;
        s[3] = OwnershipFacet.pendingOwner.selector;
    }
}
