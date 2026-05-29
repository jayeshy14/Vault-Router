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
import { RolesFacet } from "../../src/facets/RolesFacet.sol";
import { IdleStrategyFacet } from "../../src/facets/strategies/IdleStrategyFacet.sol";
import { AllocatorFacet } from "../../src/facets/AllocatorFacet.sol";
import { HarvestFacet } from "../../src/facets/HarvestFacet.sol";
import { LibAllocator } from "../../src/libraries/LibAllocator.sol";
import { LibRoles } from "../../src/libraries/LibRoles.sol";
import { LibDiamond } from "../../src/libraries/LibDiamond.sol";

import { MockProtocol } from "../mocks/MockProtocol.sol";
import { MockStrategyFacet } from "../mocks/MockStrategyFacet.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

/// @notice Exercises the owner/curator role split: owners govern risk bounds and
///         appoint curators; curators run allocation/rebalance/harvest within
///         those bounds but cannot govern or upgrade.
contract RolesTest is Test {
    MockUSDC internal usdc;
    Vault internal vault;
    MockProtocol internal mockProtocol;

    address internal owner = makeAddr("owner");
    address internal curator = makeAddr("curator");
    address internal stranger = makeAddr("stranger");
    address internal alice = makeAddr("alice");

    bytes32 internal constant MOCK_ID = bytes32("mock");

    event CuratorSet(address indexed account, bool enabled);

    function setUp() public {
        usdc = new MockUSDC();
        mockProtocol = new MockProtocol(IERC20(address(usdc)));
        vault = _deployVault();

        vm.prank(owner);
        MockStrategyFacet(address(vault)).mockSetProtocol(mockProtocol);
        vm.prank(owner);
        AllocatorFacet(address(vault)).registerStrategy(MOCK_ID, _mockStrategyConfig(0));
    }

    // -----------------------------------------------------------------------
    // setCurator
    // -----------------------------------------------------------------------

    function test_Owner_AppointsCurator() public {
        assertFalse(RolesFacet(address(vault)).isCurator(curator));

        vm.expectEmit(true, false, false, true, address(vault));
        emit CuratorSet(curator, true);
        vm.prank(owner);
        RolesFacet(address(vault)).setCurator(curator, true);

        assertTrue(RolesFacet(address(vault)).isCurator(curator));
    }

    function test_Owner_RevokesCurator() public {
        vm.prank(owner);
        RolesFacet(address(vault)).setCurator(curator, true);
        assertTrue(RolesFacet(address(vault)).isCurator(curator));

        vm.prank(owner);
        RolesFacet(address(vault)).setCurator(curator, false);
        assertFalse(RolesFacet(address(vault)).isCurator(curator));
    }

    function test_SetCurator_RevertsForNonOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(LibDiamond.NotContractOwner.selector, stranger, owner));
        RolesFacet(address(vault)).setCurator(curator, true);
    }

    function test_SetCurator_RevertsOnZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(RolesFacet.ZeroAddress.selector);
        RolesFacet(address(vault)).setCurator(address(0), true);
    }

    function test_OwnerIsImplicitlyCurator() public view {
        assertTrue(RolesFacet(address(vault)).isCurator(owner));
    }

    // -----------------------------------------------------------------------
    // Curator can operate within bounds
    // -----------------------------------------------------------------------

    function test_Curator_CanSetAllocationAndRebalance() public {
        _depositToVault(alice, 1000 * 1e6);
        vm.prank(owner);
        RolesFacet(address(vault)).setCurator(curator, true);

        bytes32[] memory ids = new bytes32[](1);
        uint16[] memory bps = new uint16[](1);
        ids[0] = MOCK_ID;
        bps[0] = 8000;

        vm.prank(curator);
        AllocatorFacet(address(vault)).setAllocation(ids, bps);

        vm.roll(block.number + 1);
        vm.prank(curator);
        AllocatorFacet(address(vault)).rebalance();

        assertEq(mockProtocol.balanceOf(address(vault)), 800 * 1e6, "curator deployed 80%");
    }

    function test_Curator_CanHarvest() public {
        vm.prank(owner);
        RolesFacet(address(vault)).setCurator(curator, true);

        vm.prank(curator);
        HarvestFacet(address(vault)).harvest(MOCK_ID); // no-op-ish but must not revert on auth
    }

    // -----------------------------------------------------------------------
    // Non-curators are rejected on operations
    // -----------------------------------------------------------------------

    function test_Stranger_CannotSetAllocation() public {
        bytes32[] memory ids = new bytes32[](1);
        uint16[] memory bps = new uint16[](1);
        ids[0] = MOCK_ID;
        bps[0] = 5000;

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(LibRoles.NotCurator.selector, stranger));
        AllocatorFacet(address(vault)).setAllocation(ids, bps);
    }

    function test_Stranger_CannotRebalance() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(LibRoles.NotCurator.selector, stranger));
        AllocatorFacet(address(vault)).rebalance();
    }

    function test_Stranger_CannotHarvest() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(LibRoles.NotCurator.selector, stranger));
        HarvestFacet(address(vault)).harvest(MOCK_ID);
    }

    function test_RevokedCurator_CannotRebalance() public {
        vm.startPrank(owner);
        RolesFacet(address(vault)).setCurator(curator, true);
        RolesFacet(address(vault)).setCurator(curator, false);
        vm.stopPrank();

        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(LibRoles.NotCurator.selector, curator));
        AllocatorFacet(address(vault)).rebalance();
    }

    // -----------------------------------------------------------------------
    // Curator cannot cross into owner-only governance
    // -----------------------------------------------------------------------

    function test_Curator_CannotRegisterStrategy() public {
        vm.prank(owner);
        RolesFacet(address(vault)).setCurator(curator, true);

        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(LibDiamond.NotContractOwner.selector, curator, owner));
        AllocatorFacet(address(vault)).registerStrategy(bytes32("x"), _mockStrategyConfig(0));
    }

    function test_Curator_CannotSetStrategyCap() public {
        vm.prank(owner);
        RolesFacet(address(vault)).setCurator(curator, true);

        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(LibDiamond.NotContractOwner.selector, curator, owner));
        AllocatorFacet(address(vault)).setStrategyCap(MOCK_ID, 5000);
    }

    function test_Curator_CannotSetIdleReserve() public {
        vm.prank(owner);
        RolesFacet(address(vault)).setCurator(curator, true);

        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(LibDiamond.NotContractOwner.selector, curator, owner));
        AllocatorFacet(address(vault)).setIdleReserve(1000);
    }

    function test_Curator_CannotAppointCurator() public {
        vm.prank(owner);
        RolesFacet(address(vault)).setCurator(curator, true);

        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(LibDiamond.NotContractOwner.selector, curator, owner));
        RolesFacet(address(vault)).setCurator(stranger, true);
    }

    // -----------------------------------------------------------------------
    // helpers
    // -----------------------------------------------------------------------

    function _deployVault() internal returns (Vault) {
        DiamondCutFacet cut = new DiamondCutFacet();
        DiamondLoupeFacet loupe = new DiamondLoupeFacet();
        OwnershipFacet ownership = new OwnershipFacet();
        RolesFacet roles = new RolesFacet();
        IdleStrategyFacet idle = new IdleStrategyFacet();
        AllocatorFacet allocator = new AllocatorFacet();
        HarvestFacet harvest = new HarvestFacet();
        MockStrategyFacet mock = new MockStrategyFacet();

        IDiamond.FacetCut[] memory cuts = new IDiamond.FacetCut[](8);
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
            facetAddress: address(roles), action: IDiamond.FacetCutAction.Add, functionSelectors: _rolesSelectors()
        });
        cuts[4] = IDiamond.FacetCut({
            facetAddress: address(idle), action: IDiamond.FacetCutAction.Add, functionSelectors: _idleSelectors()
        });
        cuts[5] = IDiamond.FacetCut({
            facetAddress: address(allocator),
            action: IDiamond.FacetCutAction.Add,
            functionSelectors: _allocatorSelectors()
        });
        cuts[6] = IDiamond.FacetCut({
            facetAddress: address(harvest), action: IDiamond.FacetCutAction.Add, functionSelectors: _harvestSelectors()
        });
        cuts[7] = IDiamond.FacetCut({
            facetAddress: address(mock), action: IDiamond.FacetCutAction.Add, functionSelectors: _mockSelectors()
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

    function _mockStrategyConfig(uint16 capBps) internal pure returns (LibAllocator.StrategyConfig memory) {
        return LibAllocator.StrategyConfig({
            totalAssetsSelector: MockStrategyFacet.mockTotalAssets.selector,
            depositSelector: MockStrategyFacet.mockDeposit.selector,
            withdrawSelector: MockStrategyFacet.mockWithdraw.selector,
            harvestSelector: MockStrategyFacet.mockHarvest.selector,
            capBps: capBps,
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

    function _rolesSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](2);
        s[0] = RolesFacet.setCurator.selector;
        s[1] = RolesFacet.isCurator.selector;
    }

    function _idleSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](1);
        s[0] = IdleStrategyFacet.idleTotalAssets.selector;
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

    function _harvestSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](2);
        s[0] = HarvestFacet.harvest.selector;
        s[1] = HarvestFacet.harvestAll.selector;
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
