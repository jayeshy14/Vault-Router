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
import { CompoundV3StrategyFacet } from "../../src/facets/strategies/CompoundV3StrategyFacet.sol";
import { IComet } from "../../src/interfaces/external/IComet.sol";
import { LibAllocator } from "../../src/libraries/LibAllocator.sol";

/// @title CompoundV3StrategyForkTest
/// @notice Exercises the CompoundV3StrategyFacet end-to-end against the real
///         Compound III (Comet) cUSDCv3 market on Arbitrum One. Skipped
///         automatically when no Arbitrum RPC is available — set ARBITRUM_RPC_URL
///         to opt in.
contract CompoundV3StrategyForkTest is Test {
    // -----------------------------------------------------------------------
    // Arbitrum One Compound III — native USDC (cUSDCv3) market.
    // Comet proxy + base token verified against arbiscan.
    // -----------------------------------------------------------------------
    address internal constant ARB_COMET = 0x9c4ec768c28520B50860ea7a15bd7213a9fF58bf;
    address internal constant ARB_USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

    bytes32 internal constant COMPOUND_ID = bytes32("compound");

    Vault internal vault;
    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");

    function setUp() public {
        string memory rpc = vm.envOr("ARBITRUM_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, vm.envOr("ARBITRUM_FORK_BLOCK", uint256(300_000_000)));

        vault = _deployVault();

        vm.startPrank(owner);
        CompoundV3StrategyFacet(address(vault)).compoundSetConfig(IComet(ARB_COMET));
        AllocatorFacet(address(vault)).registerStrategy(COMPOUND_ID, _compoundStrategyConfig());
        _setSingleAllocation(COMPOUND_ID, 8000); // 80% to Compound
        vm.stopPrank();
    }

    // -----------------------------------------------------------------------
    // Tests
    // -----------------------------------------------------------------------

    function test_DepositRebalanceDeploysToComet() public {
        _seedAndDeposit(alice, 1000 * 1e6);

        assertEq(IERC20(ARB_USDC).balanceOf(address(vault)), 1000 * 1e6, "USDC sits idle pre-rebalance");
        assertEq(IComet(ARB_COMET).balanceOf(address(vault)), 0, "no Comet position yet");

        vm.roll(block.number + 1);
        vm.prank(owner);
        AllocatorFacet(address(vault)).rebalance();

        // 80% supplied to Comet, 20% idle. Comet credits present value ~1:1.
        assertEq(IERC20(ARB_USDC).balanceOf(address(vault)), 200 * 1e6, "20% idle");
        assertApproxEqAbs(
            IComet(ARB_COMET).balanceOf(address(vault)),
            800 * 1e6,
            2, // present-value rounding slack
            "80% supplied to Comet as cUSDCv3"
        );
        assertApproxEqAbs(vault.totalAssets(), 1000 * 1e6, 2, "totalAssets unchanged");
    }

    function test_InterestAccruesIntoCometBalance() public {
        _seedAndDeposit(alice, 1000 * 1e6);
        vm.roll(block.number + 1);
        vm.prank(owner);
        AllocatorFacet(address(vault)).rebalance();

        uint256 cBefore = IComet(ARB_COMET).balanceOf(address(vault));

        // Comet's balanceOf recomputes the supply index to the current timestamp,
        // so warping forward is enough to surface accrued interest — no explicit
        // accrue call needed.
        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + 1_000_000);

        uint256 cAfter = IComet(ARB_COMET).balanceOf(address(vault));
        assertGt(cAfter, cBefore, "cUSDCv3 balance grew from supply interest");
        assertGt(vault.totalAssets(), 1000 * 1e6, "vault TVL grew");
    }

    /// @dev Real withdraw path: dropping the allocation to 0 and rebalancing
    ///      pulls the whole position back out of the live Comet market into idle.
    function test_RebalanceToZeroDrainsComet() public {
        _seedAndDeposit(alice, 1000 * 1e6);
        vm.roll(block.number + 1);
        vm.prank(owner);
        AllocatorFacet(address(vault)).rebalance();

        vm.warp(block.timestamp + 7 days); // accrue a little interest first
        vm.roll(block.number + 100_000);

        _setSingleAllocationAsOwner(COMPOUND_ID, 0);
        vm.roll(block.number + 1);
        vm.prank(owner);
        AllocatorFacet(address(vault)).rebalance();

        assertApproxEqAbs(IComet(ARB_COMET).balanceOf(address(vault)), 0, 2, "Comet position drained back to idle");
        // Principal + accrued interest is now idle; at least the original 1000.
        assertGe(IERC20(ARB_USDC).balanceOf(address(vault)), 1000 * 1e6, "idle holds principal plus interest");
    }

    /// @dev Redeems covered by the idle reserve succeed. (The Vault has no
    ///      strategy pull-back hook yet, so redeems beyond idle revert — see the
    ///      Morpho unit test for that documented boundary; here we stay within idle.)
    function test_RedeemSucceedsWithinIdle() public {
        _seedAndDeposit(alice, 1000 * 1e6);
        vm.roll(block.number + 1);
        vm.prank(owner);
        AllocatorFacet(address(vault)).rebalance(); // 200 idle, 800 in Comet

        uint256 redeemShares = vault.balanceOf(alice) / 10; // ~10% -> ~100 USDC <= idle
        vm.prank(alice);
        uint256 assetsOut = vault.redeem(redeemShares, alice, alice);

        assertGt(assetsOut, 0, "alice received underlying");
        assertEq(IERC20(ARB_USDC).balanceOf(alice), assetsOut, "alice's wallet credited");
        assertApproxEqAbs(IComet(ARB_COMET).balanceOf(address(vault)), 800 * 1e6, 2, "Comet position untouched");
    }

    // -----------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------

    function _seedAndDeposit(address from, uint256 amount) internal {
        deal(ARB_USDC, from, amount);
        vm.startPrank(from);
        IERC20(ARB_USDC).approve(address(vault), amount);
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

    function _setSingleAllocationAsOwner(bytes32 id, uint16 bps) internal {
        vm.prank(owner);
        _setSingleAllocation(id, bps);
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

        return new Vault(IERC20(ARB_USDC), "Vault Router", "vUSDC", owner, cuts, address(0), "");
    }

    function _compoundStrategyConfig() internal pure returns (LibAllocator.StrategyConfig memory) {
        return LibAllocator.StrategyConfig({
            totalAssetsSelector: CompoundV3StrategyFacet.compoundTotalAssets.selector,
            depositSelector: CompoundV3StrategyFacet.compoundDeposit.selector,
            withdrawSelector: CompoundV3StrategyFacet.compoundWithdraw.selector,
            harvestSelector: CompoundV3StrategyFacet.compoundHarvest.selector,
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
