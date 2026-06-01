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
import { AllocatorFacet } from "../../src/facets/AllocatorFacet.sol";
import { HarvestFacet } from "../../src/facets/HarvestFacet.sol";
import { LibAllocator } from "../../src/libraries/LibAllocator.sol";
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

/// @notice Proves that a single failing strategy can no longer brick the vault:
///         once quarantined it is excluded from NAV and skipped by the rebalancer
///         and harvester, so deposits/withdrawals/fees keep working.
contract QuarantineTest is Test {
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

        vm.prank(owner);
        MockStrategyFacet(address(vault)).mockSetProtocol(mockProtocol);
        vm.prank(owner);
        AllocatorFacet(address(vault)).registerStrategy(MOCK_ID, _mockStrategyConfig(0));

        // 1000 in: 50% to the mock, 50% idle. A mock failure then maps to half NAV.
        _depositToVault(alice, 1000 * 1e6);
        _setSingleAllocation(MOCK_ID, 5000);
        vm.roll(block.number + 1);
        vm.prank(owner);
        AllocatorFacet(address(vault)).rebalance();
    }

    // -----------------------------------------------------------------------
    // the bug: a failing strategy bricks the whole vault
    // -----------------------------------------------------------------------

    function test_FailingStrategy_BricksTotalAssets() public {
        MockStrategyFacet(address(vault)).mockSetReverting(true);
        vm.expectRevert(abi.encodeWithSelector(Vault.StrategyTotalAssetsCallFailed.selector, MOCK_ID));
        vault.totalAssets();
    }

    function test_FailingStrategy_BricksDeposit() public {
        MockStrategyFacet(address(vault)).mockSetReverting(true);
        usdc.mint(alice, 100 * 1e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), 100 * 1e6);
        vm.expectRevert(abi.encodeWithSelector(Vault.StrategyTotalAssetsCallFailed.selector, MOCK_ID));
        vault.deposit(100 * 1e6, alice);
        vm.stopPrank();
    }

    function test_FailingStrategy_BricksWithdraw() public {
        MockStrategyFacet(address(vault)).mockSetReverting(true);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Vault.StrategyTotalAssetsCallFailed.selector, MOCK_ID));
        vault.withdraw(10 * 1e6, alice, alice);
    }

    // -----------------------------------------------------------------------
    // the fix: quarantine isolates the failing strategy
    // -----------------------------------------------------------------------

    function test_Quarantine_ExcludesFromNav() public {
        assertEq(vault.totalAssets(), 1000 * 1e6, "healthy NAV before");
        MockStrategyFacet(address(vault)).mockSetReverting(true);

        vm.prank(owner);
        AllocatorFacet(address(vault)).quarantineStrategy(MOCK_ID);

        assertTrue(AllocatorFacet(address(vault)).isQuarantined(MOCK_ID));
        assertEq(vault.totalAssets(), 500 * 1e6, "NAV = idle only; mock excluded");
    }

    function test_Quarantine_RestoresDepositAndWithdraw() public {
        MockStrategyFacet(address(vault)).mockSetReverting(true);
        vm.prank(owner);
        AllocatorFacet(address(vault)).quarantineStrategy(MOCK_ID);

        // Both flows work again now that the failing strategy is isolated.
        _depositToVault(alice, 100 * 1e6);
        vm.prank(alice);
        vault.withdraw(10 * 1e6, alice, alice);
    }

    function test_Quarantine_ZeroesTarget() public {
        vm.prank(owner);
        AllocatorFacet(address(vault)).quarantineStrategy(MOCK_ID);
        assertEq(AllocatorFacet(address(vault)).targetAllocation(MOCK_ID), 0);
    }

    function test_Rebalance_SkipsQuarantined() public {
        MockStrategyFacet(address(vault)).mockSetReverting(true);
        vm.prank(owner);
        AllocatorFacet(address(vault)).quarantineStrategy(MOCK_ID);

        // Rebalance must not revert even though the mock's read would fail.
        vm.roll(block.number + 1);
        vm.prank(owner);
        AllocatorFacet(address(vault)).rebalance();
    }

    // -----------------------------------------------------------------------
    // F06: permissionless recovery from a strategy whose NAV read reverts
    // -----------------------------------------------------------------------

    function test_QuarantineFailedStrategy_PermissionlesslyUnbricks() public {
        MockStrategyFacet(address(vault)).mockSetReverting(true); // NAV read now reverts

        // The vault is bricked: totalAssets (and thus every ERC-4626 entrypoint) reverts.
        vm.expectRevert(abi.encodeWithSelector(Vault.StrategyTotalAssetsCallFailed.selector, MOCK_ID));
        vault.totalAssets();

        // ANY caller — no role required — can isolate a strategy whose read is
        // actually failing, so recovery no longer waits on the owner.
        address keeper = makeAddr("keeper");
        vm.prank(keeper);
        AllocatorFacet(address(vault)).quarantineFailedStrategy(MOCK_ID);

        assertTrue(AllocatorFacet(address(vault)).isQuarantined(MOCK_ID), "permissionlessly quarantined");
        assertEq(vault.totalAssets(), 500 * 1e6, "vault live again; failing strategy excluded from NAV");
    }

    function test_QuarantineFailedStrategy_RevertsOnHealthyStrategy() public {
        // A healthy strategy cannot be griefed offline: the on-chain liveness
        // probe only permits quarantine when the NAV read genuinely reverts.
        address keeper = makeAddr("keeper");
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(AllocatorFacet.StrategyHealthy.selector, MOCK_ID));
        AllocatorFacet(address(vault)).quarantineFailedStrategy(MOCK_ID);
    }

    // -----------------------------------------------------------------------
    // F05: a strategy that prices fine but cannot move funds is skipped, not
    // allowed to brick the whole rebalance.
    // -----------------------------------------------------------------------

    function test_Rebalance_SkipsStrategyThatRevertsOnMove() public {
        // Reads succeed (NAV still 500), but deposits/withdrawals revert — e.g. a
        // paused lending pool. Quarantine's read-probe wouldn't catch this, so the
        // rebalancer itself must tolerate the failed move.
        MockStrategyFacet(address(vault)).mockSetRevertOnMove(true);

        _setSingleAllocation(MOCK_ID, 8000); // wants to deposit 300 more into the mock
        vm.roll(block.number + 1);

        vm.expectEmit(true, false, false, true, address(vault));
        emit AllocatorFacet.StrategyRebalanceSkipped(MOCK_ID, MockStrategyFacet.mockDeposit.selector);
        vm.prank(owner);
        AllocatorFacet(address(vault)).rebalance(); // must NOT revert

        assertEq(AllocatorFacet(address(vault)).strategyTotalAssets(MOCK_ID), 500 * 1e6, "mock position unchanged");
        assertEq(usdc.balanceOf(address(vault)), 500 * 1e6, "idle unchanged; failed move skipped");
    }

    // -----------------------------------------------------------------------
    // harvestAll isolation
    // -----------------------------------------------------------------------

    function test_HarvestAll_RevertsOnFailingStrategy_WhenNotQuarantined() public {
        MockStrategyFacet(address(vault)).mockSetReverting(true);
        vm.prank(owner);
        vm.expectRevert(bytes("mock: harvest reverted"));
        HarvestFacet(address(vault)).harvestAll();
    }

    function test_HarvestAll_SkipsQuarantined() public {
        MockStrategyFacet(address(vault)).mockSetReverting(true);
        vm.prank(owner);
        AllocatorFacet(address(vault)).quarantineStrategy(MOCK_ID);

        vm.prank(owner);
        HarvestFacet(address(vault)).harvestAll(); // must not revert
    }

    // -----------------------------------------------------------------------
    // release
    // -----------------------------------------------------------------------

    function test_Release_RestoresAccounting() public {
        MockStrategyFacet(address(vault)).mockSetReverting(true);
        vm.prank(owner);
        AllocatorFacet(address(vault)).quarantineStrategy(MOCK_ID);
        assertEq(vault.totalAssets(), 500 * 1e6);

        // Protocol recovers; owner lifts the quarantine.
        MockStrategyFacet(address(vault)).mockSetReverting(false);
        vm.prank(owner);
        AllocatorFacet(address(vault)).releaseStrategy(MOCK_ID);

        assertFalse(AllocatorFacet(address(vault)).isQuarantined(MOCK_ID));
        assertEq(vault.totalAssets(), 1000 * 1e6, "mock position counted again");
    }

    // -----------------------------------------------------------------------
    // access control & guards
    // -----------------------------------------------------------------------

    function test_Quarantine_OwnerOnly() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LibDiamond.NotContractOwner.selector, alice, owner));
        AllocatorFacet(address(vault)).quarantineStrategy(MOCK_ID);
    }

    function test_Quarantine_RevertsIfNotRegistered() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(AllocatorFacet.StrategyNotRegistered.selector, bytes32("nope")));
        AllocatorFacet(address(vault)).quarantineStrategy(bytes32("nope"));
    }

    function test_Quarantine_RevertsIfAlreadyQuarantined() public {
        vm.startPrank(owner);
        AllocatorFacet(address(vault)).quarantineStrategy(MOCK_ID);
        vm.expectRevert(abi.encodeWithSelector(AllocatorFacet.StrategyAlreadyQuarantined.selector, MOCK_ID));
        AllocatorFacet(address(vault)).quarantineStrategy(MOCK_ID);
        vm.stopPrank();
    }

    function test_Release_OwnerOnly() public {
        vm.prank(owner);
        AllocatorFacet(address(vault)).quarantineStrategy(MOCK_ID);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LibDiamond.NotContractOwner.selector, alice, owner));
        AllocatorFacet(address(vault)).releaseStrategy(MOCK_ID);
    }

    function test_Release_RevertsIfNotQuarantined() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(AllocatorFacet.StrategyNotQuarantined.selector, MOCK_ID));
        AllocatorFacet(address(vault)).releaseStrategy(MOCK_ID);
    }

    function test_SetAllocation_RejectsQuarantined() public {
        vm.prank(owner);
        AllocatorFacet(address(vault)).quarantineStrategy(MOCK_ID);

        bytes32[] memory ids = new bytes32[](1);
        uint16[] memory bps = new uint16[](1);
        ids[0] = MOCK_ID;
        bps[0] = 3000;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(AllocatorFacet.AllocationToQuarantined.selector, MOCK_ID));
        AllocatorFacet(address(vault)).setAllocation(ids, bps);
    }

    function test_SetAllocation_AllowsZeroToQuarantined() public {
        vm.prank(owner);
        AllocatorFacet(address(vault)).quarantineStrategy(MOCK_ID);

        bytes32[] memory ids = new bytes32[](1);
        uint16[] memory bps = new uint16[](1);
        ids[0] = MOCK_ID;
        bps[0] = 0;
        vm.prank(owner);
        AllocatorFacet(address(vault)).setAllocation(ids, bps); // no revert
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
        HarvestFacet harvest = new HarvestFacet();
        MockStrategyFacet mock = new MockStrategyFacet();

        IDiamond.FacetCut[] memory cuts = new IDiamond.FacetCut[](7);
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
        cuts[4] = IDiamond.FacetCut({
            facetAddress: address(allocator),
            action: IDiamond.FacetCutAction.Add,
            functionSelectors: _allocatorSelectors()
        });
        cuts[5] = IDiamond.FacetCut({
            facetAddress: address(harvest), action: IDiamond.FacetCutAction.Add, functionSelectors: _harvestSelectors()
        });
        cuts[6] = IDiamond.FacetCut({
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

    function _idleSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](1);
        s[0] = IdleStrategyFacet.idleTotalAssets.selector;
    }

    function _allocatorSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](17);
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
        s[13] = AllocatorFacet.quarantineStrategy.selector;
        s[14] = AllocatorFacet.releaseStrategy.selector;
        s[15] = AllocatorFacet.isQuarantined.selector;
        s[16] = AllocatorFacet.quarantineFailedStrategy.selector;
    }

    function _harvestSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](2);
        s[0] = HarvestFacet.harvest.selector;
        s[1] = HarvestFacet.harvestAll.selector;
    }

    function _mockSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](8);
        s[0] = MockStrategyFacet.mockSetProtocol.selector;
        s[1] = MockStrategyFacet.mockProtocol.selector;
        s[2] = MockStrategyFacet.mockTotalAssets.selector;
        s[3] = MockStrategyFacet.mockDeposit.selector;
        s[4] = MockStrategyFacet.mockWithdraw.selector;
        s[5] = MockStrategyFacet.mockHarvest.selector;
        s[6] = MockStrategyFacet.mockSetReverting.selector;
        s[7] = MockStrategyFacet.mockSetRevertOnMove.selector;
    }
}
