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
import { AllocatorFacet } from "../../src/facets/AllocatorFacet.sol";
import { MorphoStrategyFacet } from "../../src/facets/strategies/MorphoStrategyFacet.sol";
import { IMorpho } from "../../src/interfaces/external/IMorpho.sol";
import { LibAllocator } from "../../src/libraries/LibAllocator.sol";
import { LibDiamond } from "../../src/libraries/LibDiamond.sol";

import { MockMetamorpho } from "../mocks/MockMetamorpho.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

/// @title MorphoStrategyTest
/// @notice Unit coverage for `MorphoStrategyFacet` against a mock Metamorpho
///         ERC4626 vault — no RPC required. Mirrors the structure of the Aave
///         strategy fork test but stays fully local so it runs in CI, and adds
///         the revert paths a fork test can't easily trigger (slippage,
///         asset-mismatch, unconfigured-vault).
contract MorphoStrategyTest is Test {
    MockUSDC internal usdc;
    MockMetamorpho internal morphoVault;
    Vault internal vault;

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");

    bytes32 internal constant MORPHO_ID = bytes32("morpho");

    function setUp() public {
        usdc = new MockUSDC();
        morphoVault = new MockMetamorpho(IERC20(address(usdc)));
        vault = _deployVault();
        // Note: the Morpho vault is intentionally NOT configured here — several
        // tests exercise the unconfigured-revert paths. Tests that need a live
        // strategy call `_configure()` / `_register()` explicitly.
    }

    // -----------------------------------------------------------------------
    // MorphoSetVaultConfig — gating & validation
    // -----------------------------------------------------------------------

    function test_SetVaultConfig_SetsVaultAndEmits() public {
        vm.expectEmit(true, false, false, false, address(vault));
        emit MorphoStrategyFacet.MorphoVaultSet(IMorpho(address(morphoVault)));

        vm.prank(owner);
        MorphoStrategyFacet(address(vault)).MorphoSetVaultConfig(IMorpho(address(morphoVault)));

        assertEq(
            address(MorphoStrategyFacet(address(vault)).morphoVault()),
            address(morphoVault),
            "configured vault is readable"
        );
    }

    function test_SetVaultConfig_RevertsOnZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(MorphoStrategyFacet.MorphoVaultNotConfigured.selector);
        MorphoStrategyFacet(address(vault)).MorphoSetVaultConfig(IMorpho(address(0)));
    }

    function test_SetVaultConfig_RevertsForNonOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LibDiamond.NotContractOwner.selector, alice, owner));
        MorphoStrategyFacet(address(vault)).MorphoSetVaultConfig(IMorpho(address(morphoVault)));
    }

    function test_SetVaultConfig_RevertsOnAssetMismatch() public {
        // A Metamorpho vault whose underlying differs from the diamond's asset.
        MockUSDC otherAsset = new MockUSDC();
        MockMetamorpho mismatched = new MockMetamorpho(IERC20(address(otherAsset)));

        vm.prank(owner);
        vm.expectRevert(MorphoStrategyFacet.MorphoAssetMismatch.selector);
        MorphoStrategyFacet(address(vault)).MorphoSetVaultConfig(IMorpho(address(mismatched)));
    }

    // -----------------------------------------------------------------------
    // Unconfigured-vault reverts
    // -----------------------------------------------------------------------
    // Divergence from AaveStrategyFacet: `aaveTotalAssets` returns 0 when
    // unconfigured, whereas every Morpho reader/primitive reverts hard.

    function test_TotalAssets_RevertsWhenUnconfigured() public {
        vm.expectRevert(MorphoStrategyFacet.MorphoVaultNotConfigured.selector);
        MorphoStrategyFacet(address(vault)).morphoTotalAssets();
    }

    function test_Deposit_RevertsWhenUnconfigured() public {
        vm.expectRevert(MorphoStrategyFacet.MorphoVaultNotConfigured.selector);
        MorphoStrategyFacet(address(vault)).morphoDeposit(1e6);
    }

    function test_Withdraw_RevertsWhenUnconfigured() public {
        vm.expectRevert(MorphoStrategyFacet.MorphoVaultNotConfigured.selector);
        MorphoStrategyFacet(address(vault)).morphoWithdraw(1e6);
    }

    function test_MorphoVault_RevertsWhenUnconfigured() public {
        vm.expectRevert(MorphoStrategyFacet.MorphoVaultNotConfigured.selector);
        MorphoStrategyFacet(address(vault)).morphoVault();
    }

    // -----------------------------------------------------------------------
    // Strategy primitives — called directly on the diamond
    // -----------------------------------------------------------------------

    function test_Deposit_MintsSharesAndReportsAssets() public {
        _configure();
        uint256 amount = 1000 * 1e6;
        usdc.mint(address(vault), amount); // seed the diamond's idle balance

        MorphoStrategyFacet(address(vault)).morphoDeposit(amount);

        assertEq(usdc.balanceOf(address(vault)), 0, "idle underlying fully deployed");
        assertGt(morphoVault.balanceOf(address(vault)), 0, "diamond holds Metamorpho shares");
        assertApproxEqAbs(
            MorphoStrategyFacet(address(vault)).morphoTotalAssets(), amount, 1, "position reported in underlying units"
        );
    }

    function test_Deposit_RevertsOnSlippage() public {
        _configure();
        uint256 amount = 1000 * 1e6;
        morphoVault.setShortchangeBps(100); // mint 1% fewer shares than quoted
        usdc.mint(address(vault), amount);

        // `previewDeposit` is read on the empty vault — same value the facet sees.
        uint256 expected = morphoVault.previewDeposit(amount);
        uint256 received = (expected * (10_000 - 100)) / 10_000;

        vm.expectRevert(abi.encodeWithSelector(MorphoStrategyFacet.MorphoSlippage.selector, expected, received));
        MorphoStrategyFacet(address(vault)).morphoDeposit(amount);
    }

    function test_Withdraw_ReturnsUnderlyingToDiamond() public {
        _configure();
        uint256 amount = 1000 * 1e6;
        usdc.mint(address(vault), amount);
        MorphoStrategyFacet(address(vault)).morphoDeposit(amount);

        MorphoStrategyFacet(address(vault)).morphoWithdraw(400 * 1e6);

        assertEq(usdc.balanceOf(address(vault)), 400 * 1e6, "withdrawn underlying back to idle");
        assertApproxEqAbs(
            MorphoStrategyFacet(address(vault)).morphoTotalAssets(), 600 * 1e6, 1, "remaining position reported"
        );
    }

    function test_TotalAssets_TracksYieldAccrual() public {
        _configure();
        uint256 amount = 1000 * 1e6;
        usdc.mint(address(vault), amount);
        MorphoStrategyFacet(address(vault)).morphoDeposit(amount);

        uint256 beforeYield = MorphoStrategyFacet(address(vault)).morphoTotalAssets();
        morphoVault._testAccrueYield(100 * 1e6); // 10% supply yield donated to the vault
        uint256 afterYield = MorphoStrategyFacet(address(vault)).morphoTotalAssets();

        assertGt(afterYield, beforeYield, "share-price NAV grew with yield");
        assertApproxEqRel(afterYield, 1100 * 1e6, 1e15, "position ~= principal + yield"); // 0.1% tolerance
    }

    function test_Harvest_IsNoOp() public {
        _configure();
        uint256 amount = 1000 * 1e6;
        usdc.mint(address(vault), amount);
        MorphoStrategyFacet(address(vault)).morphoDeposit(amount);

        uint256 before = MorphoStrategyFacet(address(vault)).morphoTotalAssets();
        MorphoStrategyFacet(address(vault)).morphoHarvest(); // must not revert
        assertEq(MorphoStrategyFacet(address(vault)).morphoTotalAssets(), before, "harvest is a no-op");
    }

    // -----------------------------------------------------------------------
    // End-to-end through the allocator
    // -----------------------------------------------------------------------

    function test_Rebalance_RoutesAssetsIntoMorpho() public {
        _configure();
        _register();
        _depositToVault(alice, 1000 * 1e6);
        _setSingleAllocation(MORPHO_ID, 8000); // 80% to Morpho

        vm.roll(block.number + 1);
        vm.prank(owner);
        AllocatorFacet(address(vault)).rebalance();

        assertApproxEqAbs(
            MorphoStrategyFacet(address(vault)).morphoTotalAssets(), 800 * 1e6, 1, "80% routed into Metamorpho"
        );
        assertEq(usdc.balanceOf(address(vault)), 200 * 1e6, "20% stays idle");
        assertApproxEqAbs(vault.totalAssets(), 1000 * 1e6, 1, "totalAssets unchanged across rebalance");
    }

    function test_Rebalance_PullsBackWhenAllocationDrops() public {
        _configure();
        _register();
        _depositToVault(alice, 1000 * 1e6);
        _setSingleAllocation(MORPHO_ID, 8000);
        vm.roll(block.number + 1);
        vm.prank(owner);
        AllocatorFacet(address(vault)).rebalance();

        // Drop the allocation to 0 and rebalance again — exercises morphoWithdraw.
        _setSingleAllocation(MORPHO_ID, 0);
        vm.roll(block.number + 1);
        vm.prank(owner);
        AllocatorFacet(address(vault)).rebalance();

        assertApproxEqAbs(MorphoStrategyFacet(address(vault)).morphoTotalAssets(), 0, 1, "Morpho position drained");
        assertApproxEqAbs(usdc.balanceOf(address(vault)), 1000 * 1e6, 1, "all assets back idle");
    }

    // -----------------------------------------------------------------------
    // Redeem — documents current Vault behaviour
    // -----------------------------------------------------------------------
    // `Vault._withdraw` is a thin `super._withdraw`: it has no hook to pull
    // capital back out of strategies. Redeems therefore succeed only up to the
    // idle balance and revert beyond it. (The Aave fork test's redeem case
    // depends on a pull-back hook that does not yet exist.)

    function test_Redeem_SucceedsWhenCoveredByIdle() public {
        _configure();
        _register();
        _depositToVault(alice, 1000 * 1e6);
        _setSingleAllocation(MORPHO_ID, 8000);
        vm.roll(block.number + 1);
        vm.prank(owner);
        AllocatorFacet(address(vault)).rebalance(); // 200 USDC idle, 800 in Morpho

        uint256 redeemShares = vault.balanceOf(alice) / 10; // ~10% -> ~100 USDC <= idle
        vm.prank(alice);
        uint256 assetsOut = vault.redeem(redeemShares, alice, alice);

        assertGt(assetsOut, 0, "alice received underlying");
        assertEq(usdc.balanceOf(alice), assetsOut, "alice's wallet credited");
        assertApproxEqAbs(
            MorphoStrategyFacet(address(vault)).morphoTotalAssets(), 800 * 1e6, 1, "Morpho position untouched"
        );
    }

    function test_Redeem_RevertsWhenExceedsIdleLiquidity() public {
        _configure();
        _register();
        _depositToVault(alice, 1000 * 1e6);
        _setSingleAllocation(MORPHO_ID, 8000);
        vm.roll(block.number + 1);
        vm.prank(owner);
        AllocatorFacet(address(vault)).rebalance(); // only 200 USDC left idle

        // Redeeming everything needs ~1000 USDC; the vault holds 200 idle and
        // has no strategy pull-back hook, so the underlying transfer reverts.
        uint256 allShares = vault.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert();
        vault.redeem(allShares, alice, alice);
    }

    // -----------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------

    function _configure() internal {
        vm.prank(owner);
        MorphoStrategyFacet(address(vault)).MorphoSetVaultConfig(IMorpho(address(morphoVault)));
    }

    function _register() internal {
        vm.prank(owner);
        AllocatorFacet(address(vault)).registerStrategy(MORPHO_ID, _morphoStrategyConfig());
    }

    function _depositToVault(address from, uint256 amount) internal {
        usdc.mint(from, amount);
        vm.startPrank(from);
        usdc.approve(address(vault), amount);
        vault.deposit(amount, from);
        vm.stopPrank();
    }

    function _setSingleAllocation(bytes32 id, uint16 bps) internal {
        bytes32[] memory ids = new bytes32[](1);
        uint16[] memory b = new uint16[](1);
        ids[0] = id;
        b[0] = bps;
        vm.prank(owner);
        AllocatorFacet(address(vault)).setAllocation(ids, b);
    }

    function _morphoStrategyConfig() internal pure returns (LibAllocator.StrategyConfig memory) {
        return LibAllocator.StrategyConfig({
            totalAssetsSelector: MorphoStrategyFacet.morphoTotalAssets.selector,
            depositSelector: MorphoStrategyFacet.morphoDeposit.selector,
            withdrawSelector: MorphoStrategyFacet.morphoWithdraw.selector,
            harvestSelector: MorphoStrategyFacet.morphoHarvest.selector,
            capBps: 0,
            active: false // overwritten in registerStrategy
        });
    }

    function _deployVault() internal returns (Vault) {
        DiamondCutFacet cut = new DiamondCutFacet();
        DiamondLoupeFacet loupe = new DiamondLoupeFacet();
        OwnershipFacet ownership = new OwnershipFacet();
        AllocatorFacet allocator = new AllocatorFacet();
        MorphoStrategyFacet morpho = new MorphoStrategyFacet();

        IDiamond.FacetCut[] memory cuts = new IDiamond.FacetCut[](5);
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
            facetAddress: address(allocator),
            action: IDiamond.FacetCutAction.Add,
            functionSelectors: _allocatorSelectors()
        });
        cuts[4] = IDiamond.FacetCut({
            facetAddress: address(morpho), action: IDiamond.FacetCutAction.Add, functionSelectors: _morphoSelectors()
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
        s = new bytes4[](2);
        s[0] = IERC173.owner.selector;
        s[1] = IERC173.transferOwnership.selector;
    }

    function _allocatorSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](13);
        s[0] = AllocatorFacet.registerStrategy.selector;
        s[1] = AllocatorFacet.removeStrategy.selector;
        s[2] = AllocatorFacet.setAllocation.selector;
        s[3] = AllocatorFacet.setIdleReserve.selector;
        s[4] = AllocatorFacet.setStrategyCap.selector;
        s[5] = AllocatorFacet.setGlobalStrategyCap.selector;
        s[6] = AllocatorFacet.rebalance.selector;
        s[7] = AllocatorFacet.strategies.selector;
        s[8] = AllocatorFacet.strategyConfig.selector;
        s[9] = AllocatorFacet.targetAllocation.selector;
        s[10] = AllocatorFacet.idleReserveBps.selector;
        s[11] = AllocatorFacet.strategyTotalAssets.selector;
        s[12] = AllocatorFacet.idleAssets.selector;
    }

    function _morphoSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](6);
        s[0] = MorphoStrategyFacet.MorphoSetVaultConfig.selector;
        s[1] = MorphoStrategyFacet.morphoTotalAssets.selector;
        s[2] = MorphoStrategyFacet.morphoDeposit.selector;
        s[3] = MorphoStrategyFacet.morphoWithdraw.selector;
        s[4] = MorphoStrategyFacet.morphoHarvest.selector;
        s[5] = MorphoStrategyFacet.morphoVault.selector;
    }
}
