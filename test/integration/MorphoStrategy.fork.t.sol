// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
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

/// @title MorphoStrategyForkTest
/// @notice Exercises the MorphoStrategyFacet end-to-end against the real
///         Moonwell Flagship USDC Metamorpho vault on Base mainnet. Skipped
///         automatically when no Base RPC is available — set BASE_RPC_URL to
///         opt in. Mirrors AaveStrategy.fork.t.sol.
contract MorphoStrategyForkTest is Test {
    // -----------------------------------------------------------------------
    // Base mainnet — Moonwell Flagship USDC Metamorpho vault (curated by
    // Block Analitica & B.Protocol). Deployed long before block 25_000_000.
    // -----------------------------------------------------------------------
    address internal constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant BASE_MORPHO_VAULT = 0xc1256Ae5FF1cf2719D4937adb3bbCCab2E00A2Ca;

    bytes32 internal constant MORPHO_ID = bytes32("morpho");

    Vault internal vault;
    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");

    function setUp() public {
        // Fork tests require a dedicated Base RPC. Set BASE_RPC_URL in your
        // shell or .env to opt in; otherwise the whole suite is skipped.
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        // Pin a block for determinism. Defaults to 25_000_000 (matches the
        // Aave fork test); override with BASE_FORK_BLOCK when your RPC has
        // pruned state that far back (most non-archive nodes have).
        vm.createSelectFork(rpc, vm.envOr("BASE_FORK_BLOCK", uint256(25_000_000)));

        vault = _deployVault();

        vm.startPrank(owner);
        MorphoStrategyFacet(address(vault)).MorphoSetVaultConfig(IMorpho(BASE_MORPHO_VAULT));
        AllocatorFacet(address(vault)).registerStrategy(MORPHO_ID, _morphoStrategyConfig());
        _setSingleAllocation(MORPHO_ID, 8000); // 80% to Morpho
        vm.stopPrank();
    }

    // -----------------------------------------------------------------------
    // Tests
    // -----------------------------------------------------------------------

    function test_DepositRebalanceDeploysToMorpho() public {
        _seedAndDeposit(alice, 1000 * 1e6);

        assertEq(IERC20(BASE_USDC).balanceOf(address(vault)), 1000 * 1e6, "USDC sits idle pre-rebalance");

        vm.roll(block.number + 1);
        vm.prank(owner);
        AllocatorFacet(address(vault)).rebalance();

        // 80% routed to Morpho, 20% stays idle. Metamorpho shares are not 1:1
        // with assets, so the position is read in underlying units via the
        // facet's `morphoTotalAssets` (share-price NAV).
        assertEq(IERC20(BASE_USDC).balanceOf(address(vault)), 200 * 1e6, "20% idle");
        assertApproxEqRel(
            MorphoStrategyFacet(address(vault)).morphoTotalAssets(),
            800 * 1e6,
            1e15, // 0.1% — absorbs ERC4626 share-rounding
            "80% deployed into Metamorpho"
        );
        assertApproxEqRel(vault.totalAssets(), 1000 * 1e6, 1e15, "totalAssets unchanged across rebalance");
    }

    function test_YieldAccruesIntoMorphoPosition() public {
        _seedAndDeposit(alice, 1000 * 1e6);
        vm.roll(block.number + 1);
        vm.prank(owner);
        AllocatorFacet(address(vault)).rebalance();

        uint256 navBefore = MorphoStrategyFacet(address(vault)).morphoTotalAssets();

        // Roll forward ~30 days. Block time on Base is ~2s; 30 days ≈ 1_296_000
        // blocks. Metamorpho's `totalAssets()` accrues market interest by
        // timestamp, so the share-price NAV grows without any interaction.
        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + 1_296_000);

        uint256 navAfter = MorphoStrategyFacet(address(vault)).morphoTotalAssets();
        assertGt(navAfter, navBefore, "Morpho position grew from supply interest");
        assertGt(vault.totalAssets(), 1000 * 1e6, "vault TVL grew");
    }

    function test_RebalancePullsBackFromMorpho() public {
        _seedAndDeposit(alice, 1000 * 1e6);
        vm.roll(block.number + 1);
        vm.prank(owner);
        AllocatorFacet(address(vault)).rebalance();

        // Drop the Morpho allocation to 0 and rebalance — pass 1 of rebalance
        // withdraws the whole position back to idle via `morphoWithdraw`.
        vm.prank(owner);
        _setSingleAllocation(MORPHO_ID, 0);
        vm.roll(block.number + 1);
        vm.prank(owner);
        AllocatorFacet(address(vault)).rebalance();

        assertApproxEqAbs(
            MorphoStrategyFacet(address(vault)).morphoTotalAssets(), 0, 1, "Morpho position drained back to idle"
        );
        assertApproxEqRel(
            IERC20(BASE_USDC).balanceOf(address(vault)), 1000 * 1e6, 1e15, "all assets back idle in the vault"
        );
    }

    /// @dev `Vault._withdraw` is a thin `super._withdraw` with no hook to pull
    ///      capital back out of strategies, so a redeem can only be serviced
    ///      from the idle balance. This test redeems within that idle headroom;
    ///      a redeem exceeding it would revert in the underlying transfer.
    function test_RedeemWithinIdleLiquidityReturnsAssets() public {
        _seedAndDeposit(alice, 1000 * 1e6);
        vm.roll(block.number + 1);
        vm.prank(owner);
        AllocatorFacet(address(vault)).rebalance(); // 200 USDC idle, 800 in Morpho

        uint256 navBefore = MorphoStrategyFacet(address(vault)).morphoTotalAssets();

        // Redeem ~10% of alice's shares (~100 USDC) — well inside the 200 idle.
        uint256 redeemShares = vault.balanceOf(alice) / 10;
        vm.prank(alice);
        uint256 assetsReturned = vault.redeem(redeemShares, alice, alice);

        assertGt(assetsReturned, 0, "alice received underlying");
        assertEq(IERC20(BASE_USDC).balanceOf(alice), assetsReturned, "alice's wallet credited");
        assertApproxEqAbs(
            MorphoStrategyFacet(address(vault)).morphoTotalAssets(),
            navBefore,
            1,
            "Morpho position untouched - redeem served from idle"
        );
    }

    // -----------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------

    function _seedAndDeposit(address from, uint256 amount) internal {
        deal(BASE_USDC, from, amount);
        vm.startPrank(from);
        IERC20(BASE_USDC).approve(address(vault), amount);
        vault.deposit(amount, from);
        vm.stopPrank();
    }

    function _setSingleAllocation(bytes32 id, uint16 bps) internal {
        bytes32[] memory ids = new bytes32[](1);
        uint16[] memory b = new uint16[](1);
        ids[0] = id;
        b[0] = bps;
        AllocatorFacet(address(vault)).setAllocation(ids, b);
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

        return new Vault(IERC20(BASE_USDC), "Vault Router", "vUSDC", owner, cuts, address(0), "");
    }

    function _morphoStrategyConfig() internal pure returns (LibAllocator.StrategyConfig memory) {
        return LibAllocator.StrategyConfig({
            totalAssetsSelector: MorphoStrategyFacet.morphoTotalAssets.selector,
            depositSelector: MorphoStrategyFacet.morphoDeposit.selector,
            withdrawSelector: MorphoStrategyFacet.morphoWithdraw.selector,
            harvestSelector: MorphoStrategyFacet.morphoHarvest.selector,
            capBps: 0,
            active: false
        });
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
