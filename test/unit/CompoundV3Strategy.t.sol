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
import { CompoundV3StrategyFacet } from "../../src/facets/strategies/CompoundV3StrategyFacet.sol";
import { IComet } from "../../src/interfaces/external/IComet.sol";
import { LibAllocator } from "../../src/libraries/LibAllocator.sol";
import { LibDiamond } from "../../src/libraries/LibDiamond.sol";

import { MockComet } from "../mocks/MockComet.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

/// @title CompoundV3StrategyTest
/// @notice Unit coverage for `CompoundV3StrategyFacet` against a mock Comet
///         market — no RPC required. Mirrors the Morpho/Aave strategy tests and
///         adds the revert paths a fork test can't easily trigger (asset
///         mismatch, supply/withdraw shortfall, unconfigured market). The
///         onlySelf fund-movers are exercised both directly (pranking the diamond
///         as itself) and end-to-end through the allocator's self-dispatch.
contract CompoundV3StrategyTest is Test {
    MockUSDC internal usdc;
    MockComet internal comet;
    Vault internal vault;

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");

    bytes32 internal constant COMPOUND_ID = bytes32("compound");

    function setUp() public {
        usdc = new MockUSDC();
        comet = new MockComet(IERC20(address(usdc)));
        vault = _deployVault();
        // The market is intentionally NOT configured here — several tests exercise
        // the unconfigured paths. Tests that need a live strategy call
        // `_configure()` / `_register()` explicitly.
    }

    // -----------------------------------------------------------------------
    // compoundSetConfig — gating & validation
    // -----------------------------------------------------------------------

    function test_SetConfig_SetsCometAndEmits() public {
        vm.expectEmit(true, true, false, false, address(vault));
        emit CompoundV3StrategyFacet.CompoundConfigSet(IComet(address(comet)), address(usdc));

        vm.prank(owner);
        CompoundV3StrategyFacet(address(vault)).compoundSetConfig(IComet(address(comet)));

        assertEq(
            address(CompoundV3StrategyFacet(address(vault)).compoundComet()),
            address(comet),
            "configured market is readable"
        );
    }

    function test_SetConfig_RevertsOnZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(CompoundV3StrategyFacet.CompoundCometNotConfigured.selector);
        CompoundV3StrategyFacet(address(vault)).compoundSetConfig(IComet(address(0)));
    }

    function test_SetConfig_RevertsForNonOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LibDiamond.NotContractOwner.selector, alice, owner));
        CompoundV3StrategyFacet(address(vault)).compoundSetConfig(IComet(address(comet)));
    }

    function test_SetConfig_RevertsOnAssetMismatch() public {
        // A Comet market whose base token differs from the diamond's asset.
        MockUSDC otherAsset = new MockUSDC();
        MockComet mismatched = new MockComet(IERC20(address(otherAsset)));

        vm.prank(owner);
        vm.expectRevert(CompoundV3StrategyFacet.CompoundAssetMismatch.selector);
        CompoundV3StrategyFacet(address(vault)).compoundSetConfig(IComet(address(mismatched)));
    }

    // -----------------------------------------------------------------------
    // Unconfigured behaviour
    // -----------------------------------------------------------------------
    // Mirrors the Aave facet: `compoundTotalAssets` reads as empty (0) when
    // unconfigured rather than reverting, so the allocator's NAV sweep is robust;
    // the fund-movers revert hard.

    function test_TotalAssets_ReturnsZeroWhenUnconfigured() public view {
        assertEq(CompoundV3StrategyFacet(address(vault)).compoundTotalAssets(), 0, "empty when unconfigured");
    }

    function test_Comet_ReturnsZeroWhenUnconfigured() public view {
        assertEq(address(CompoundV3StrategyFacet(address(vault)).compoundComet()), address(0), "no market set");
    }

    function test_Deposit_RevertsWhenUnconfigured() public {
        vm.prank(address(vault)); // satisfy onlySelf
        vm.expectRevert(CompoundV3StrategyFacet.CompoundCometNotConfigured.selector);
        CompoundV3StrategyFacet(address(vault)).compoundDeposit(1e6);
    }

    function test_Withdraw_RevertsWhenUnconfigured() public {
        vm.prank(address(vault));
        vm.expectRevert(CompoundV3StrategyFacet.CompoundCometNotConfigured.selector);
        CompoundV3StrategyFacet(address(vault)).compoundWithdraw(1e6);
    }

    // -----------------------------------------------------------------------
    // Access control — fund-movers are reachable only via diamond self-dispatch
    // -----------------------------------------------------------------------

    function test_Deposit_RevertsForExternalCaller() public {
        _configure();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LibDiamond.NotSelf.selector, alice));
        CompoundV3StrategyFacet(address(vault)).compoundDeposit(1e6);
    }

    function test_Withdraw_RevertsForExternalCaller() public {
        _configure();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LibDiamond.NotSelf.selector, alice));
        CompoundV3StrategyFacet(address(vault)).compoundWithdraw(1e6);
    }

    // -----------------------------------------------------------------------
    // Strategy primitives — driven directly by pranking the diamond as itself
    // (msg.sender == address(this) satisfies enforceIsSelf), so each guard gets
    // precise coverage independent of the allocator.
    // -----------------------------------------------------------------------

    function test_Deposit_CreditsAndReportsAssets() public {
        _configure();
        uint256 amount = 1000 * 1e6;
        usdc.mint(address(vault), amount);

        vm.prank(address(vault));
        CompoundV3StrategyFacet(address(vault)).compoundDeposit(amount);

        assertEq(usdc.balanceOf(address(vault)), 0, "idle fully supplied");
        assertEq(comet.balanceOf(address(vault)), amount, "market credited the supply");
        assertEq(CompoundV3StrategyFacet(address(vault)).compoundTotalAssets(), amount, "position reported 1:1");
    }

    function test_Deposit_RevertsOnSupplyShortfall() public {
        _configure();
        uint256 amount = 1000 * 1e6;
        usdc.mint(address(vault), amount);
        comet.setSupplyShortfallBps(100); // credit 1% fewer base units than supplied

        vm.prank(address(vault));
        vm.expectRevert(
            abi.encodeWithSelector(
                CompoundV3StrategyFacet.CompoundDepositFailed.selector, amount, (amount * 9900) / 10_000
            )
        );
        CompoundV3StrategyFacet(address(vault)).compoundDeposit(amount);
    }

    function test_Withdraw_ReturnsUnderlyingToDiamond() public {
        _configure();
        uint256 amount = 1000 * 1e6;
        usdc.mint(address(vault), amount);
        vm.startPrank(address(vault));
        CompoundV3StrategyFacet(address(vault)).compoundDeposit(amount);
        CompoundV3StrategyFacet(address(vault)).compoundWithdraw(400 * 1e6);
        vm.stopPrank();

        assertEq(usdc.balanceOf(address(vault)), 400 * 1e6, "withdrawn underlying back to idle");
        assertEq(CompoundV3StrategyFacet(address(vault)).compoundTotalAssets(), 600 * 1e6, "remaining position");
    }

    function test_Withdraw_RevertsOnShortfall() public {
        _configure();
        uint256 amount = 1000 * 1e6;
        usdc.mint(address(vault), amount);
        vm.startPrank(address(vault));
        CompoundV3StrategyFacet(address(vault)).compoundDeposit(amount);

        comet.setWithdrawShortfallBps(100); // market returns 1% less than requested
        vm.expectRevert(
            abi.encodeWithSelector(
                CompoundV3StrategyFacet.CompoundWithdrawFailed.selector, 400 * 1e6, (400 * 1e6 * 9900) / 10_000
            )
        );
        CompoundV3StrategyFacet(address(vault)).compoundWithdraw(400 * 1e6);
        vm.stopPrank();
    }

    /// @dev Over-requesting must clamp to the position, never overdraw into a
    ///      borrow. Asking for 2x the balance withdraws exactly the balance.
    function test_Withdraw_ClampsOverRequestToBalance() public {
        _configure();
        uint256 amount = 1000 * 1e6;
        usdc.mint(address(vault), amount);
        vm.startPrank(address(vault));
        CompoundV3StrategyFacet(address(vault)).compoundDeposit(amount);
        CompoundV3StrategyFacet(address(vault)).compoundWithdraw(amount * 2); // way over the position
        vm.stopPrank();

        assertEq(usdc.balanceOf(address(vault)), amount, "clamped: only the balance came back");
        assertEq(CompoundV3StrategyFacet(address(vault)).compoundTotalAssets(), 0, "position fully drained, no borrow");
    }

    function test_TotalAssets_TracksYieldAccrual() public {
        _configure();
        uint256 amount = 1000 * 1e6;
        usdc.mint(address(vault), amount);
        vm.prank(address(vault));
        CompoundV3StrategyFacet(address(vault)).compoundDeposit(amount);

        uint256 beforeYield = CompoundV3StrategyFacet(address(vault)).compoundTotalAssets();
        comet._testAccrueYield(address(vault), 100 * 1e6); // 10% supply interest
        uint256 afterYield = CompoundV3StrategyFacet(address(vault)).compoundTotalAssets();

        assertGt(afterYield, beforeYield, "rebasing balance grew with supply interest");
        assertEq(afterYield, 1100 * 1e6, "position == principal + accrued interest");
    }

    function test_Harvest_IsNoOp() public {
        _configure();
        uint256 amount = 1000 * 1e6;
        usdc.mint(address(vault), amount);
        vm.prank(address(vault));
        CompoundV3StrategyFacet(address(vault)).compoundDeposit(amount);

        uint256 before = CompoundV3StrategyFacet(address(vault)).compoundTotalAssets();
        CompoundV3StrategyFacet(address(vault)).compoundHarvest(); // not onlySelf, moves nothing
        assertEq(CompoundV3StrategyFacet(address(vault)).compoundTotalAssets(), before, "harvest is a no-op");
    }

    // -----------------------------------------------------------------------
    // End-to-end through the allocator
    // -----------------------------------------------------------------------

    function test_Rebalance_RoutesAssetsIntoCompound() public {
        _configure();
        _register();
        _depositToVault(alice, 1000 * 1e6);
        _setSingleAllocation(COMPOUND_ID, 8000); // 80%

        vm.roll(block.number + 1);
        vm.prank(owner);
        AllocatorFacet(address(vault)).rebalance();

        assertEq(comet.balanceOf(address(vault)), 800 * 1e6, "80% supplied to Comet");
        assertEq(usdc.balanceOf(address(vault)), 200 * 1e6, "20% stays idle");
        assertApproxEqAbs(vault.totalAssets(), 1000 * 1e6, 1, "totalAssets unchanged across rebalance");
    }

    function test_Rebalance_PullsBackWhenAllocationDrops() public {
        _configure();
        _register();
        _depositToVault(alice, 1000 * 1e6);
        _setSingleAllocation(COMPOUND_ID, 8000);
        vm.roll(block.number + 1);
        vm.prank(owner);
        AllocatorFacet(address(vault)).rebalance();

        _setSingleAllocation(COMPOUND_ID, 0); // drop to 0 -> next rebalance drains
        vm.roll(block.number + 1);
        vm.prank(owner);
        AllocatorFacet(address(vault)).rebalance();

        assertEq(comet.balanceOf(address(vault)), 0, "Comet position drained");
        assertApproxEqAbs(usdc.balanceOf(address(vault)), 1000 * 1e6, 1, "all assets back idle");
    }

    /// @dev A fee-on-supply makes `compoundDeposit` revert; the allocator turns it
    ///      into a per-strategy SKIP rather than a whole-rebalance revert, so the
    ///      funds stay idle and the skip is recorded.
    function test_Rebalance_SkipsDepositOnSupplyShortfall() public {
        _configure();
        _register();
        uint256 amount = 1000 * 1e6;
        usdc.mint(address(vault), amount);
        comet.setSupplyShortfallBps(100);
        _setSingleAllocation(COMPOUND_ID, 10_000);
        vm.roll(block.number + 1);

        vm.expectEmit(true, false, false, true, address(vault));
        emit AllocatorFacet.StrategyRebalanceSkipped(COMPOUND_ID, CompoundV3StrategyFacet.compoundDeposit.selector);
        vm.prank(owner);
        AllocatorFacet(address(vault)).rebalance();

        assertEq(usdc.balanceOf(address(vault)), amount, "funds stayed idle; over-slippage deposit skipped");
    }

    /// @dev An illiquid/paused market makes `compoundWithdraw` revert; the
    ///      rebalancer skips that one strategy instead of bricking the batch.
    function test_Rebalance_SkipsWithdrawWhenMarketReverts() public {
        _configure();
        _register();
        _depositToVault(alice, 1000 * 1e6);
        _setSingleAllocation(COMPOUND_ID, 8000);
        vm.roll(block.number + 1);
        vm.prank(owner);
        AllocatorFacet(address(vault)).rebalance(); // 800 in Comet

        comet.setWithdrawReverts(true); // market can't return funds
        _setSingleAllocation(COMPOUND_ID, 0); // ask to pull everything back
        vm.roll(block.number + 1);

        vm.expectEmit(true, false, false, true, address(vault));
        emit AllocatorFacet.StrategyRebalanceSkipped(COMPOUND_ID, CompoundV3StrategyFacet.compoundWithdraw.selector);
        vm.prank(owner);
        AllocatorFacet(address(vault)).rebalance();

        assertEq(comet.balanceOf(address(vault)), 800 * 1e6, "position untouched after skipped withdraw");
    }

    // -----------------------------------------------------------------------
    // Redeem — documents current Vault behaviour (no strategy pull-back hook yet,
    // identical to the Morpho strategy test).
    // -----------------------------------------------------------------------

    function test_Redeem_SucceedsWhenCoveredByIdle() public {
        _configure();
        _register();
        _depositToVault(alice, 1000 * 1e6);
        _setSingleAllocation(COMPOUND_ID, 8000);
        vm.roll(block.number + 1);
        vm.prank(owner);
        AllocatorFacet(address(vault)).rebalance(); // 200 idle, 800 in Comet

        uint256 redeemShares = vault.balanceOf(alice) / 10; // ~10% -> ~100 USDC <= idle
        vm.prank(alice);
        uint256 assetsOut = vault.redeem(redeemShares, alice, alice);

        assertGt(assetsOut, 0, "alice received underlying");
        assertEq(usdc.balanceOf(alice), assetsOut, "alice's wallet credited");
        assertEq(comet.balanceOf(address(vault)), 800 * 1e6, "Comet position untouched");
    }

    function test_Redeem_RevertsWhenExceedsIdleLiquidity() public {
        _configure();
        _register();
        _depositToVault(alice, 1000 * 1e6);
        _setSingleAllocation(COMPOUND_ID, 8000);
        vm.roll(block.number + 1);
        vm.prank(owner);
        AllocatorFacet(address(vault)).rebalance(); // only 200 USDC idle

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
        CompoundV3StrategyFacet(address(vault)).compoundSetConfig(IComet(address(comet)));
    }

    function _register() internal {
        vm.prank(owner);
        AllocatorFacet(address(vault)).registerStrategy(COMPOUND_ID, _compoundStrategyConfig());
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

    function _compoundStrategyConfig() internal pure returns (LibAllocator.StrategyConfig memory) {
        return LibAllocator.StrategyConfig({
            totalAssetsSelector: CompoundV3StrategyFacet.compoundTotalAssets.selector,
            depositSelector: CompoundV3StrategyFacet.compoundDeposit.selector,
            withdrawSelector: CompoundV3StrategyFacet.compoundWithdraw.selector,
            harvestSelector: CompoundV3StrategyFacet.compoundHarvest.selector,
            capBps: 0,
            active: false // overwritten in registerStrategy
        });
    }

    function _deployVault() internal returns (Vault) {
        DiamondCutFacet cut = new DiamondCutFacet();
        DiamondLoupeFacet loupe = new DiamondLoupeFacet();
        OwnershipFacet ownership = new OwnershipFacet();
        AllocatorFacet allocator = new AllocatorFacet();
        CompoundV3StrategyFacet compound = new CompoundV3StrategyFacet();

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
            facetAddress: address(compound),
            action: IDiamond.FacetCutAction.Add,
            functionSelectors: _compoundSelectors()
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

    function _compoundSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](6);
        s[0] = CompoundV3StrategyFacet.compoundSetConfig.selector;
        s[1] = CompoundV3StrategyFacet.compoundTotalAssets.selector;
        s[2] = CompoundV3StrategyFacet.compoundDeposit.selector;
        s[3] = CompoundV3StrategyFacet.compoundWithdraw.selector;
        s[4] = CompoundV3StrategyFacet.compoundHarvest.selector;
        s[5] = CompoundV3StrategyFacet.compoundComet.selector;
    }
}
