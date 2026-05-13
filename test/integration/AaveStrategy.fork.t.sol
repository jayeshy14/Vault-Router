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
import { AaveStrategyFacet } from "../../src/facets/strategies/AaveStrategyFacet.sol";
import { IAavePool } from "../../src/interfaces/external/IAavePool.sol";
import { LibAllocator } from "../../src/libraries/LibAllocator.sol";

/// @title AaveStrategyForkTest
/// @notice Exercises the AaveStrategyFacet end-to-end against the real Aave V3
///         deployment on Base mainnet. Skipped automatically when no Base RPC
///         is available; defaults to the public `mainnet.base.org` endpoint.
contract AaveStrategyForkTest is Test {
    // -----------------------------------------------------------------------
    // Base mainnet Aave V3 — addresses sourced from Aave's address book.
    // -----------------------------------------------------------------------
    address internal constant BASE_AAVE_POOL = 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5;
    address internal constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant BASE_AUSDC = 0x4e65fE4DbA92790696d040ac24Aa414708F5c0AB;

    bytes32 internal constant AAVE_ID = bytes32("aave");

    Vault internal vault;
    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");

    function setUp() public {
        // Fork tests require a dedicated Base RPC (the public endpoint times out
        // on the storage-introspection calls forge-std's `deal` cheat makes).
        // Set BASE_RPC_URL in your shell or .env to opt in.
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, 25_000_000);

        vault = _deployVault();

        vm.startPrank(owner);
        AaveStrategyFacet(address(vault)).aaveSetConfig(IAavePool(BASE_AAVE_POOL), IERC20(BASE_AUSDC));
        AllocatorFacet(address(vault)).registerStrategy(AAVE_ID, _aaveStrategyConfig());
        _setSingleAllocation(AAVE_ID, 8000); // 80% to Aave
        vm.stopPrank();
    }

    // -----------------------------------------------------------------------
    // Tests
    // -----------------------------------------------------------------------

    function test_DepositRebalanceDeploysToAUsdc() public {
        _seedAndDeposit(alice, 1000 * 1e6);

        assertEq(IERC20(BASE_USDC).balanceOf(address(vault)), 1000 * 1e6, "USDC sits idle pre-rebalance");
        assertEq(IERC20(BASE_AUSDC).balanceOf(address(vault)), 0, "no aUSDC yet");

        vm.roll(block.number + 1);
        vm.prank(owner);
        AllocatorFacet(address(vault)).rebalance();

        // 80% routed to Aave, 20% stays idle. aUSDC starts at 1:1 with USDC.
        assertEq(IERC20(BASE_USDC).balanceOf(address(vault)), 200 * 1e6, "20% idle");
        assertApproxEqAbs(
            IERC20(BASE_AUSDC).balanceOf(address(vault)),
            800 * 1e6,
            1, // 1 wei tolerance for aave's internal rounding
            "80% deployed to aave as aUSDC"
        );
        assertApproxEqAbs(vault.totalAssets(), 1000 * 1e6, 1, "totalAssets unchanged");
    }

    function test_InterestAccruesIntoATokenBalance() public {
        _seedAndDeposit(alice, 1000 * 1e6);
        vm.roll(block.number + 1);
        vm.prank(owner);
        AllocatorFacet(address(vault)).rebalance();

        uint256 aBefore = IERC20(BASE_AUSDC).balanceOf(address(vault));

        // Roll forward ~30 days. Block time on Base is ~2s; 30 days ≈ 1_296_000 blocks.
        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + 1_296_000);

        uint256 aAfter = IERC20(BASE_AUSDC).balanceOf(address(vault));
        assertGt(aAfter, aBefore, "aUSDC balance grew from supply interest");

        // totalAssets reflects the gain.
        assertGt(vault.totalAssets(), 1000 * 1e6, "vault TVL grew");
    }

    function test_RedeemWithdrawsFromAaveAndReturnsAssets() public {
        _seedAndDeposit(alice, 1000 * 1e6);
        vm.roll(block.number + 1);
        vm.prank(owner);
        AllocatorFacet(address(vault)).rebalance();

        // Accrue some interest.
        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + 1_296_000);

        uint256 aliceShares = vault.balanceOf(alice);
        vm.prank(alice);
        uint256 assetsReturned = vault.redeem(aliceShares, alice, alice);

        assertGe(assetsReturned, 1000 * 1e6, "alice gets back at least her principal");
        assertEq(IERC20(BASE_USDC).balanceOf(alice), assetsReturned, "alice's wallet credited");
        assertApproxEqAbs(IERC20(BASE_AUSDC).balanceOf(address(vault)), 0, 1, "aUSDC drained back to idle on redeem");
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
        AaveStrategyFacet aave = new AaveStrategyFacet();

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
            facetAddress: address(aave), action: IDiamond.FacetCutAction.Add, functionSelectors: _aaveSelectors()
        });

        return new Vault(IERC20(BASE_USDC), "Vault Router", "vUSDC", owner, cuts, address(0), "");
    }

    function _aaveStrategyConfig() internal pure returns (LibAllocator.StrategyConfig memory) {
        return LibAllocator.StrategyConfig({
            totalAssetsSelector: AaveStrategyFacet.aaveTotalAssets.selector,
            depositSelector: AaveStrategyFacet.aaveDeposit.selector,
            withdrawSelector: AaveStrategyFacet.aaveWithdraw.selector,
            harvestSelector: AaveStrategyFacet.aaveHarvest.selector,
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

    function _aaveSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](6);
        s[0] = AaveStrategyFacet.aaveSetConfig.selector;
        s[1] = AaveStrategyFacet.aaveTotalAssets.selector;
        s[2] = AaveStrategyFacet.aaveDeposit.selector;
        s[3] = AaveStrategyFacet.aaveWithdraw.selector;
        s[4] = AaveStrategyFacet.aaveHarvest.selector;
        s[5] = AaveStrategyFacet.aavePool.selector;
    }
}
