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
import {AllocatorFacet} from "../../src/facets/AllocatorFacet.sol";
import {HarvestFacet} from "../../src/facets/HarvestFacet.sol";
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

contract HarvestTest is Test {
    MockUSDC internal usdc;
    Vault internal vault;
    MockProtocol internal mockProtocol;

    address internal owner = makeAddr("owner");

    bytes32 internal constant MOCK_ID = bytes32("mock");

    function setUp() public {
        usdc = new MockUSDC();
        mockProtocol = new MockProtocol(IERC20(address(usdc)));
        vault = _deployVault();

        vm.startPrank(owner);
        MockStrategyFacet(address(vault)).mockSetProtocol(mockProtocol);
        AllocatorFacet(address(vault)).registerStrategy(MOCK_ID, _mockStrategyConfig());
        vm.stopPrank();
    }

    function test_Harvest_InvokesStrategyHarvestSelector() public {
        assertEq(MockStrategyFacet(address(vault)).mockHarvestCount(), 0);

        vm.prank(owner);
        HarvestFacet(address(vault)).harvest(MOCK_ID);

        assertEq(MockStrategyFacet(address(vault)).mockHarvestCount(), 1);
    }

    function test_Harvest_RevertsOnUnknownStrategy() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(HarvestFacet.StrategyNotRegistered.selector, bytes32("unknown")));
        HarvestFacet(address(vault)).harvest(bytes32("unknown"));
    }

    function test_HarvestAll_LoopsEveryRegisteredStrategy() public {
        // Register a second strategy id pointing at the same facet (harvest will increment count twice).
        vm.prank(owner);
        AllocatorFacet(address(vault)).registerStrategy(bytes32("mock2"), _mockStrategyConfig());

        vm.prank(owner);
        HarvestFacet(address(vault)).harvestAll();

        assertEq(MockStrategyFacet(address(vault)).mockHarvestCount(), 2);
    }

    function test_Harvest_OnlyCurator() public {
        vm.prank(makeAddr("randomEOA"));
        vm.expectRevert();
        HarvestFacet(address(vault)).harvest(MOCK_ID);
    }

    // -----------------------------------------------------------------------
    // setup helpers
    // -----------------------------------------------------------------------

    function _deployVault() internal returns (Vault) {
        DiamondCutFacet cut = new DiamondCutFacet();
        DiamondLoupeFacet loupe = new DiamondLoupeFacet();
        OwnershipFacet ownership = new OwnershipFacet();
        AllocatorFacet allocator = new AllocatorFacet();
        HarvestFacet harvestFacet = new HarvestFacet();
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
            facetAddress: address(allocator),
            action: IDiamond.FacetCutAction.Add,
            functionSelectors: _allocatorSelectors()
        });
        cuts[4] = IDiamond.FacetCut({
            facetAddress: address(harvestFacet),
            action: IDiamond.FacetCutAction.Add,
            functionSelectors: _harvestSelectors()
        });
        cuts[5] = IDiamond.FacetCut({
            facetAddress: address(mock),
            action: IDiamond.FacetCutAction.Add,
            functionSelectors: _mockSelectors()
        });

        return new Vault(IERC20(address(usdc)), "Vault Router", "vUSDC", owner, cuts, address(0), "");
    }

    function _mockStrategyConfig() internal pure returns (LibAllocator.StrategyConfig memory) {
        return LibAllocator.StrategyConfig({
            totalAssetsSelector: MockStrategyFacet.mockTotalAssets.selector,
            depositSelector: MockStrategyFacet.mockDeposit.selector,
            withdrawSelector: MockStrategyFacet.mockWithdraw.selector,
            harvestSelector: MockStrategyFacet.mockHarvest.selector,
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

    function _harvestSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](2);
        s[0] = HarvestFacet.harvest.selector;
        s[1] = HarvestFacet.harvestAll.selector;
    }

    function _mockSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](7);
        s[0] = MockStrategyFacet.mockSetProtocol.selector;
        s[1] = MockStrategyFacet.mockProtocol.selector;
        s[2] = MockStrategyFacet.mockTotalAssets.selector;
        s[3] = MockStrategyFacet.mockDeposit.selector;
        s[4] = MockStrategyFacet.mockWithdraw.selector;
        s[5] = MockStrategyFacet.mockHarvest.selector;
        s[6] = MockStrategyFacet.mockHarvestCount.selector;
    }
}
