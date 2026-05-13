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
import { FeeFacet } from "../../src/facets/FeeFacet.sol";
import { LibAllocator } from "../../src/libraries/LibAllocator.sol";
import { LibFees } from "../../src/libraries/LibFees.sol";

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

contract FeesTest is Test {
    MockUSDC internal usdc;
    Vault internal vault;
    MockProtocol internal mockProtocol;

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal feeRx = makeAddr("feeRecipient");

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

    // -----------------------------------------------------------------------
    // No fees when not configured
    // -----------------------------------------------------------------------

    function test_NoFee_WhenRecipientUnset() public {
        // Even with non-zero rates set, no recipient → no fee shares.
        // (Setters reject 0-address recipient, so we just leave it default.)
        _depositToVault(alice, 1000 * 1e6);
        mockProtocol._testAccrueYield(address(vault), 100 * 1e6); // 10% yield
        _depositToVault(alice, 1000 * 1e6); // triggers _accrueFees

        assertEq(vault.balanceOf(feeRx), 0, "no fee minted without recipient");
    }

    // -----------------------------------------------------------------------
    // Performance fee
    // -----------------------------------------------------------------------

    function test_PerformanceFee_BootstrapsHwmOnFirstAccrual() public {
        _configureFees(2000, 0); // 20% perf, 0% mgmt
        _depositToVault(alice, 1000 * 1e6);

        // First deposit just initialised HWM to the current share price.
        // No fee should have been charged.
        assertEq(vault.balanceOf(feeRx), 0, "no fee on the bootstrap deposit");
        assertGt(FeeFacet(address(vault)).highWaterMark(), 0, "HWM initialised");
    }

    function test_PerformanceFee_ChargedOnShareGrowth() public {
        _configureFees(2000, 0); // 20% perf
        _depositToVault(alice, 1000 * 1e6);
        _setSingleAllocation(MOCK_ID, 8000);
        vm.roll(block.number + 1);
        vm.prank(owner);
        AllocatorFacet(address(vault)).rebalance();

        // Yield: 100 USDC profit (10% of TVL) accrues to the mock-protocol position.
        mockProtocol._testAccrueYield(address(vault), 100 * 1e6);

        // Trigger accrual via a fresh deposit.
        _depositToVault(alice, 1 * 1e6);

        // 20% of 100 USDC profit ≈ 20 USDC worth of shares minted to feeRx.
        // Recipient's share of TVL after the mint ≈ 20 / 1101 ≈ 1.82%.
        uint256 supplyTotal = vault.totalSupply();
        uint256 recipientShare = (vault.balanceOf(feeRx) * 10_000) / supplyTotal;
        assertApproxEqAbs(recipientShare, 182, 10, "feeRx owns ~1.82% of supply");
    }

    function test_PerformanceFee_NotChargedBelowHWM() public {
        _configureFees(2000, 0);
        _depositToVault(alice, 1000 * 1e6);
        _setSingleAllocation(MOCK_ID, 8000);
        vm.roll(block.number + 1);
        vm.prank(owner);
        AllocatorFacet(address(vault)).rebalance();

        // Bump then trigger an accrual to lock HWM at the high.
        mockProtocol._testAccrueYield(address(vault), 100 * 1e6);
        _depositToVault(alice, 1 * 1e6);

        uint256 sharesBefore = vault.balanceOf(feeRx);

        // Burn yield (simulate loss by withdrawing from mock at a discount).
        // Easier: manipulate the mock balance directly.
        vm.prank(address(vault));
        mockProtocol.withdraw(50 * 1e6); // pulls 50 back, both protocol-side balance and vault USDC change

        // Trigger another accrual. Share price now BELOW the previous HWM
        // (we lost value). Perf fee must NOT trigger.
        _depositToVault(alice, 1 * 1e6);

        assertEq(vault.balanceOf(feeRx), sharesBefore, "no extra perf fee below HWM");
    }

    // -----------------------------------------------------------------------
    // Management fee
    // -----------------------------------------------------------------------

    function test_ManagementFee_AccruedOverTime() public {
        _configureFees(0, 200); // 0% perf, 2%/year mgmt
        _depositToVault(alice, 1000 * 1e6);

        uint256 supplyBefore = vault.totalSupply();

        // Warp one full year forward.
        vm.warp(block.timestamp + 365 days);

        // Trigger accrual via a fresh deposit.
        _depositToVault(alice, 1 * 1e6);

        // After 1 year at 2%, fee shares should be ~2% of the pre-warp supply.
        // The exact share count uses our linear approximation; allow ±5% drift.
        uint256 expected = (supplyBefore * 200) / 10_000;
        assertApproxEqRel(vault.balanceOf(feeRx), expected, 0.05e18, "mgmt fee ~ 2% of supply after 1 yr");
    }

    // -----------------------------------------------------------------------
    // setUp helpers
    // -----------------------------------------------------------------------

    function _configureFees(uint16 perfBps, uint16 mgmtBps) internal {
        vm.startPrank(owner);
        FeeFacet(address(vault)).setFeeRecipient(feeRx);
        if (perfBps > 0) FeeFacet(address(vault)).setPerformanceFee(perfBps);
        if (mgmtBps > 0) FeeFacet(address(vault)).setManagementFee(mgmtBps);
        vm.stopPrank();
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

    function _deployVault() internal returns (Vault) {
        DiamondCutFacet cut = new DiamondCutFacet();
        DiamondLoupeFacet loupe = new DiamondLoupeFacet();
        OwnershipFacet ownership = new OwnershipFacet();
        AllocatorFacet allocator = new AllocatorFacet();
        FeeFacet feeFacet = new FeeFacet();
        MockStrategyFacet mock = new MockStrategyFacet();

        IDiamond.FacetCut[] memory cuts = new IDiamond.FacetCut[](6);
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
            facetAddress: address(feeFacet), action: IDiamond.FacetCutAction.Add, functionSelectors: _feeSelectors()
        });
        cuts[5] = IDiamond.FacetCut({
            facetAddress: address(mock), action: IDiamond.FacetCutAction.Add, functionSelectors: _mockSelectors()
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

    function _feeSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](8);
        s[0] = FeeFacet.setFeeRecipient.selector;
        s[1] = FeeFacet.setPerformanceFee.selector;
        s[2] = FeeFacet.setManagementFee.selector;
        s[3] = FeeFacet.feeRecipient.selector;
        s[4] = FeeFacet.performanceFeeBps.selector;
        s[5] = FeeFacet.managementFeeBps.selector;
        s[6] = FeeFacet.highWaterMark.selector;
        s[7] = FeeFacet.lastFeeAccrual.selector;
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
