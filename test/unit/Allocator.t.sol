// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Vault} from "../../src/Vault.sol";
import {IDiamond} from "../../src/interfaces/IDiamond.sol";
import {IDiamondCut} from "../../src/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "../../src/interfaces/IDiamondLoupe.sol";
import {IERC173} from "../../src/interfaces/IERC173.sol";
import {DiamondCutFacet} from "../../src/facets/DiamondCutFacet.sol";
import {DiamondLoupeFacet} from "../../src/facets/DiamondLoupeFacet.sol";
import {OwnershipFacet} from "../../src/facets/OwnershipFacet.sol";
import {IdleStrategyFacet} from "../../src/facets/strategies/IdleStrategyFacet.sol";
import {AllocatorFacet} from "../../src/facets/AllocatorFacet.sol";
import {LibAllocator} from "../../src/libraries/LibAllocator.sol";

import {MockProtocol} from "../mocks/MockProtocol.sol";
import {MockStrategyFacet} from "../mocks/MockStrategyFacet.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

contract AllocatorTest is Test {
    MockUSDC internal usdc;
    Vault internal vault;
    MockProtocol internal mockProtocol;

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");

    bytes32 internal constant MOCK_ID = bytes32("mock");

    function setUp() public {
        usdc = new MockUSDC();
        mockProtocol = new MockProtocol(IERC20(address(usdc)));
        vault = _deployVault();

        // Point the mock strategy facet at the protocol.
        vm.prank(owner);
        MockStrategyFacet(address(vault)).mockSetProtocol(mockProtocol);

        // Register the strategy.
        vm.prank(owner);
        AllocatorFacet(address(vault)).registerStrategy(MOCK_ID, _mockStrategyConfig(0));
    }

    // -----------------------------------------------------------------------
    // register / remove
    // -----------------------------------------------------------------------

    function test_RegisterStrategy_AddsToList() public view {
        bytes32[] memory ids = AllocatorFacet(address(vault)).strategies();
        assertEq(ids.length, 1);
        assertEq(ids[0], MOCK_ID);
    }

    function test_RegisterStrategy_RevertsOnDuplicate() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(AllocatorFacet.StrategyAlreadyRegistered.selector, MOCK_ID));
        AllocatorFacet(address(vault)).registerStrategy(MOCK_ID, _mockStrategyConfig(0));
    }

    function test_RemoveStrategy_RemovesFromList() public {
        vm.prank(owner);
        AllocatorFacet(address(vault)).removeStrategy(MOCK_ID);
        assertEq(AllocatorFacet(address(vault)).strategies().length, 0);
    }

    // -----------------------------------------------------------------------
    // setAllocation validation
    // -----------------------------------------------------------------------

    function test_SetAllocation_RejectsBudgetExceeded() public {
        vm.prank(owner);
        AllocatorFacet(address(vault)).setIdleReserve(2_000); // 20%

        bytes32[] memory ids = new bytes32[](1);
        uint16[] memory bps = new uint16[](1);
        ids[0] = MOCK_ID;
        bps[0] = 9_000; // 90%, but only 80% is allocatable

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(AllocatorFacet.AllocationExceedsBudget.selector, 9_000, 8_000));
        AllocatorFacet(address(vault)).setAllocation(ids, bps);
    }

    function test_SetAllocation_RejectsCapExceeded() public {
        vm.startPrank(owner);
        AllocatorFacet(address(vault)).setStrategyCap(MOCK_ID, 5_000); // 50% cap on mock

        bytes32[] memory ids = new bytes32[](1);
        uint16[] memory bps = new uint16[](1);
        ids[0] = MOCK_ID;
        bps[0] = 6_000;

        vm.expectRevert(
            abi.encodeWithSelector(AllocatorFacet.AllocationExceedsCap.selector, MOCK_ID, 5_000, 6_000)
        );
        AllocatorFacet(address(vault)).setAllocation(ids, bps);
        vm.stopPrank();
    }

    function test_SetAllocation_StoresTargetBps() public {
        bytes32[] memory ids = new bytes32[](1);
        uint16[] memory bps = new uint16[](1);
        ids[0] = MOCK_ID;
        bps[0] = 8_000;

        vm.prank(owner);
        AllocatorFacet(address(vault)).setAllocation(ids, bps);

        assertEq(AllocatorFacet(address(vault)).targetAllocation(MOCK_ID), 8_000);
    }

    // -----------------------------------------------------------------------
    // rebalance
    // -----------------------------------------------------------------------

    function test_Rebalance_DistributesAssetsToStrategy() public {
        _depositToVault(alice, 1_000 * 1e6);
        _setSingleAllocation(MOCK_ID, 8_000);

        vm.roll(block.number + 1);
        vm.prank(owner);
        AllocatorFacet(address(vault)).rebalance();

        assertEq(mockProtocol.balanceOf(address(vault)), 800 * 1e6, "80% landed in mock protocol");
        assertEq(usdc.balanceOf(address(vault)), 200 * 1e6, "20% stays idle in vault");
    }

    function test_Rebalance_PullsBackWhenAllocationDrops() public {
        _depositToVault(alice, 1_000 * 1e6);
        _setSingleAllocation(MOCK_ID, 8_000);
        vm.roll(block.number + 1);
        vm.prank(owner);
        AllocatorFacet(address(vault)).rebalance();

        // Now drop allocation to 0% and rebalance.
        bytes32[] memory ids = new bytes32[](1);
        uint16[] memory bps = new uint16[](1);
        ids[0] = MOCK_ID;
        bps[0] = 0;
        vm.prank(owner);
        AllocatorFacet(address(vault)).setAllocation(ids, bps);

        vm.roll(block.number + 1);
        vm.prank(owner);
        AllocatorFacet(address(vault)).rebalance();

        assertEq(mockProtocol.balanceOf(address(vault)), 0, "mock protocol drained");
        assertEq(usdc.balanceOf(address(vault)), 1_000 * 1e6, "all assets back idle");
    }

    function test_Rebalance_RevertsSameBlock() public {
        _depositToVault(alice, 1_000 * 1e6);
        _setSingleAllocation(MOCK_ID, 5_000);

        vm.roll(block.number + 1);
        vm.startPrank(owner);
        AllocatorFacet(address(vault)).rebalance();

        vm.expectRevert(
            abi.encodeWithSelector(AllocatorFacet.RebalanceTooSoon.selector, block.number, block.number)
        );
        AllocatorFacet(address(vault)).rebalance();
        vm.stopPrank();
    }

    function test_StrategyTotalAssets_ReadsViaFallback() public {
        _depositToVault(alice, 1_000 * 1e6);
        _setSingleAllocation(MOCK_ID, 5_000);
        vm.roll(block.number + 1);
        vm.prank(owner);
        AllocatorFacet(address(vault)).rebalance();

        uint256 reported = AllocatorFacet(address(vault)).strategyTotalAssets(MOCK_ID);
        assertEq(reported, 500 * 1e6, "allocator self-staticcalls into mock facet");
    }

    function test_IdleReserve_FloorEnforcedAfterRebalance() public {
        _depositToVault(alice, 1_000 * 1e6);
        vm.prank(owner);
        AllocatorFacet(address(vault)).setIdleReserve(2_500); // 25% floor

        // Allocation that exactly hits the budget: 75% to strategy, 25% idle.
        bytes32[] memory ids = new bytes32[](1);
        uint16[] memory bps = new uint16[](1);
        ids[0] = MOCK_ID;
        bps[0] = 7_500;
        vm.prank(owner);
        AllocatorFacet(address(vault)).setAllocation(ids, bps);

        vm.roll(block.number + 1);
        vm.prank(owner);
        AllocatorFacet(address(vault)).rebalance();

        assertEq(usdc.balanceOf(address(vault)), 250 * 1e6, "exactly 25% remains idle");
        assertEq(mockProtocol.balanceOf(address(vault)), 750 * 1e6, "75% deployed");
    }

    // -----------------------------------------------------------------------
    // helpers
    // -----------------------------------------------------------------------

    function _deployVault() internal returns (Vault) {
        DiamondCutFacet cut = new DiamondCutFacet();
        DiamondLoupeFacet loupe = new DiamondLoupeFacet();
        OwnershipFacet ownership = new OwnershipFacet();
        IdleStrategyFacet idle = new IdleStrategyFacet();
        AllocatorFacet allocator = new AllocatorFacet();
        MockStrategyFacet mock = new MockStrategyFacet();

        IDiamond.FacetCut[] memory cuts = new IDiamond.FacetCut[](6);
        cuts[0] = IDiamond.FacetCut({
            facetAddress: address(cut),
            action: IDiamond.FacetCutAction.Add,
            functionSelectors: _diamondCutSelectors()
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
            facetAddress: address(idle),
            action: IDiamond.FacetCutAction.Add,
            functionSelectors: _idleSelectors()
        });
        cuts[4] = IDiamond.FacetCut({
            facetAddress: address(allocator),
            action: IDiamond.FacetCutAction.Add,
            functionSelectors: _allocatorSelectors()
        });
        cuts[5] = IDiamond.FacetCut({
            facetAddress: address(mock),
            action: IDiamond.FacetCutAction.Add,
            functionSelectors: _mockSelectors()
        });

        return new Vault(IERC20(address(usdc)), "Vault Router", "vUSDC", owner, cuts, address(0), "");
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

    function _mockStrategyConfig(uint16 capBps) internal pure returns (LibAllocator.StrategyConfig memory) {
        return LibAllocator.StrategyConfig({
            totalAssetsSelector: MockStrategyFacet.mockTotalAssets.selector,
            depositSelector: MockStrategyFacet.mockDeposit.selector,
            withdrawSelector: MockStrategyFacet.mockWithdraw.selector,
            harvestSelector: MockStrategyFacet.mockHarvest.selector,
            capBps: capBps,
            active: false // overwritten in registerStrategy
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

    function _idleSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](1);
        s[0] = IdleStrategyFacet.idleTotalAssets.selector;
    }

    function _allocatorSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](14);
        s[0] = AllocatorFacet.registerStrategy.selector;
        s[1] = AllocatorFacet.removeStrategy.selector;
        s[2] = AllocatorFacet.setAllocation.selector;
        s[3] = AllocatorFacet.setIdleReserve.selector;
        s[4] = AllocatorFacet.setStrategyCap.selector;
        s[5] = AllocatorFacet.setGlobalStrategyCap.selector;
        s[6] = AllocatorFacet.rebalance.selector;
        s[7] = AllocatorFacet.harvest.selector;
        s[8] = AllocatorFacet.strategies.selector;
        s[9] = AllocatorFacet.strategyConfig.selector;
        s[10] = AllocatorFacet.targetAllocation.selector;
        s[11] = AllocatorFacet.idleReserveBps.selector;
        s[12] = AllocatorFacet.strategyTotalAssets.selector;
        s[13] = AllocatorFacet.idleAssets.selector;
    }

    function _mockSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](6);
        s[0] = MockStrategyFacet.mockSetProtocol.selector;
        s[1] = MockStrategyFacet.mockProtocol.selector;
        s[2] = MockStrategyFacet.mockTotalAssets.selector;
        s[3] = MockStrategyFacet.mockDeposit.selector;
        s[4] = MockStrategyFacet.mockWithdraw.selector;
        s[5] = MockStrategyFacet.mockHarvest.selector;
    }
}
