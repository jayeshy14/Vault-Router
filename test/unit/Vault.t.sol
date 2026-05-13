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
import { IdleStrategyFacet } from "../../src/facets/strategies/IdleStrategyFacet.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

contract VaultTest is Test {
    MockUSDC internal usdc;
    Vault internal vault;
    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");

    function setUp() public {
        usdc = new MockUSDC();
        vault = _deployVault(IERC20(address(usdc)));
    }

    function test_DepositMintsSharesAndIncreasesTotalAssets() public {
        uint256 amount = 1000 * 1e6;
        usdc.mint(alice, amount);

        vm.startPrank(alice);
        usdc.approve(address(vault), amount);
        uint256 shares = vault.deposit(amount, alice);
        vm.stopPrank();

        assertEq(usdc.balanceOf(address(vault)), amount, "vault holds the asset");
        assertEq(vault.totalAssets(), amount, "totalAssets matches");
        assertEq(vault.balanceOf(alice), shares, "alice holds the shares");
        assertGt(shares, 0, "shares minted");
    }

    function test_RedeemReturnsAssetsToOwner() public {
        uint256 amount = 1000 * 1e6;
        usdc.mint(alice, amount);

        vm.startPrank(alice);
        usdc.approve(address(vault), amount);
        vault.deposit(amount, alice);
        uint256 shares = vault.balanceOf(alice);
        uint256 redeemed = vault.redeem(shares, alice, alice);
        vm.stopPrank();

        assertEq(redeemed, amount, "got back what was deposited");
        assertEq(usdc.balanceOf(alice), amount, "alice has her usdc");
        assertEq(vault.balanceOf(alice), 0, "no shares left");
        assertEq(vault.totalAssets(), 0, "vault is empty");
    }

    function test_FallbackRoutesToIdleStrategyFacet() public {
        uint256 amount = 500 * 1e6;
        usdc.mint(alice, amount);

        vm.startPrank(alice);
        usdc.approve(address(vault), amount);
        vault.deposit(amount, alice);
        vm.stopPrank();

        uint256 idleBalance = IdleStrategyFacet(address(vault)).idleTotalAssets();
        assertEq(idleBalance, amount, "idle facet reads the vault's asset balance via fallback");
    }

    function test_FallbackRoutesToOwnershipFacet() public {
        assertEq(IERC173(address(vault)).owner(), owner, "owner() resolved via diamond fallback");
    }

    function test_FallbackRoutesToLoupeFacet() public {
        address[] memory addrs = IDiamondLoupe(address(vault)).facetAddresses();
        assertEq(addrs.length, 4, "four facets registered");

        bytes4 sel = IdleStrategyFacet.idleTotalAssets.selector;
        address resolved = IDiamondLoupe(address(vault)).facetAddress(sel);
        assertTrue(resolved != address(0), "idleTotalAssets selector is registered");
    }

    function test_FallbackRevertsOnUnknownSelector() public {
        bytes4 unknown = bytes4(keccak256("nope()"));
        (bool ok, bytes memory ret) = address(vault).call(abi.encodePacked(unknown));
        assertFalse(ok, "unknown selector reverts");
        // The revert encodes `Vault.UnknownSelector(bytes4)` — first 4 bytes of selector.
        bytes4 expected = bytes4(keccak256("UnknownSelector(bytes4)"));
        assertEq(bytes4(ret), expected, "got UnknownSelector(bytes4)");
    }

    // -----------------------------------------------------------------------
    // helpers
    // -----------------------------------------------------------------------

    function _deployVault(IERC20 asset_) internal returns (Vault) {
        DiamondCutFacet cut = new DiamondCutFacet();
        DiamondLoupeFacet loupe = new DiamondLoupeFacet();
        OwnershipFacet ownership = new OwnershipFacet();
        IdleStrategyFacet idle = new IdleStrategyFacet();

        IDiamond.FacetCut[] memory cuts = new IDiamond.FacetCut[](4);
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
        cuts[3] = IDiamond.FacetCut({
            facetAddress: address(idle), action: IDiamond.FacetCutAction.Add, functionSelectors: _idleSelectors()
        });

        return new Vault(asset_, "Vault Router", "vUSDC", owner, cuts, address(0), "");
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
        s = new bytes4[](2);
        s[0] = IERC173.owner.selector;
        s[1] = IERC173.transferOwnership.selector;
    }

    function _idleSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](1);
        s[0] = IdleStrategyFacet.idleTotalAssets.selector;
    }
}
