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
import { PendlePtStrategyFacet } from "../../src/facets/strategies/PendlePtStrategyFacet.sol";
import { IPendleRouter } from "../../src/interfaces/external/IPendleRouter.sol";
import { IPPrincipalToken } from "../../src/interfaces/external/IPPrincipalToken.sol";
import { LibAllocator } from "../../src/libraries/LibAllocator.sol";
import { LibDiamond } from "../../src/libraries/LibDiamond.sol";

import { MockPrincipalToken, MockPendleRouter } from "../mocks/MockPendle.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

/// @title PendleStrategyTest
/// @notice Unit coverage for `PendlePtStrategyFacet` against a mock Pendle
///         router + PT — no RPC required. Mirrors MorphoStrategy.t.sol: covers
///         config gating, the unconfigured-revert paths, the buy / sell /
///         redeem primitives across the maturity boundary, and the end-to-end
///         allocator rebalance. The pre/post-maturity branch and the discount
///         economics are unique to PT, so each gets a dedicated case.
contract PendleStrategyTest is Test {
    MockUSDC internal usdc;
    MockPrincipalToken internal pt;
    MockPendleRouter internal router;
    Vault internal vault;

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal market = makeAddr("market");
    address internal yt = makeAddr("yt");
    address internal sy = makeAddr("sy");

    uint256 internal expiry;

    bytes32 internal constant PENDLE_ID = bytes32("pendle");

    function setUp() public {
        usdc = new MockUSDC();
        expiry = block.timestamp + 365 days;
        pt = new MockPrincipalToken(6, expiry, yt, sy);
        router = new MockPendleRouter(IERC20(address(usdc)), pt);
        vault = _deployVault();
        // The router needs underlying liquidity to settle sells / redemptions.
        usdc.mint(address(router), 100_000_000 * 1e6);
        // Note: the strategy is intentionally left unconfigured here — several
        // tests exercise the unconfigured paths. Tests that need a live
        // strategy call `_configure()` / `_register()` explicitly.
    }

    // -----------------------------------------------------------------------
    // pendleSetConfig — gating & validation
    // -----------------------------------------------------------------------

    function test_SetConfig_SetsAndEmits() public {
        vm.expectEmit(true, true, true, false, address(vault));
        emit PendlePtStrategyFacet.PendleConfigSet(address(router), market, address(pt));

        vm.prank(owner);
        PendlePtStrategyFacet(address(vault))
            .pendleSetConfig(IPendleRouter(address(router)), market, IPPrincipalToken(address(pt)));

        assertEq(address(PendlePtStrategyFacet(address(vault)).pendleRouter()), address(router), "router readable");
        assertEq(PendlePtStrategyFacet(address(vault)).pendleMarket(), market, "market readable");
        assertEq(address(PendlePtStrategyFacet(address(vault)).pendlePT()), address(pt), "pt readable");
    }

    function test_SetConfig_RevertsOnZeroRouter() public {
        vm.prank(owner);
        vm.expectRevert(PendlePtStrategyFacet.PendleNotConfigured.selector);
        PendlePtStrategyFacet(address(vault))
            .pendleSetConfig(IPendleRouter(address(0)), market, IPPrincipalToken(address(pt)));
    }

    function test_SetConfig_RevertsOnZeroMarket() public {
        vm.prank(owner);
        vm.expectRevert(PendlePtStrategyFacet.PendleNotConfigured.selector);
        PendlePtStrategyFacet(address(vault))
            .pendleSetConfig(IPendleRouter(address(router)), address(0), IPPrincipalToken(address(pt)));
    }

    function test_SetConfig_RevertsOnZeroPt() public {
        vm.prank(owner);
        vm.expectRevert(PendlePtStrategyFacet.PendleNotConfigured.selector);
        PendlePtStrategyFacet(address(vault))
            .pendleSetConfig(IPendleRouter(address(router)), market, IPPrincipalToken(address(0)));
    }

    function test_SetConfig_RevertsForNonOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LibDiamond.NotContractOwner.selector, alice, owner));
        PendlePtStrategyFacet(address(vault))
            .pendleSetConfig(IPendleRouter(address(router)), market, IPPrincipalToken(address(pt)));
    }

    // -----------------------------------------------------------------------
    // Unconfigured behaviour
    // -----------------------------------------------------------------------
    // Divergence from Morpho: `pendleTotalAssets` returns 0 when unconfigured
    // (matches Aave), whereas the action/reader primitives revert hard.

    function test_TotalAssets_ReturnsZeroWhenUnconfigured() public view {
        assertEq(PendlePtStrategyFacet(address(vault)).pendleTotalAssets(), 0, "zero before config");
    }

    function test_Deposit_RevertsWhenUnconfigured() public {
        vm.expectRevert(PendlePtStrategyFacet.PendleNotConfigured.selector);
        PendlePtStrategyFacet(address(vault)).pendleDeposit(1e6);
    }

    function test_Withdraw_RevertsWhenUnconfigured() public {
        vm.expectRevert(PendlePtStrategyFacet.PendleNotConfigured.selector);
        PendlePtStrategyFacet(address(vault)).pendleWithdraw(1e6);
    }

    function test_IsExpired_RevertsWhenUnconfigured() public {
        vm.expectRevert(PendlePtStrategyFacet.PendleNotConfigured.selector);
        PendlePtStrategyFacet(address(vault)).pendleIsExpired();
    }

    function test_Expiry_RevertsWhenUnconfigured() public {
        vm.expectRevert(PendlePtStrategyFacet.PendleNotConfigured.selector);
        PendlePtStrategyFacet(address(vault)).pendleExpiry();
    }

    // -----------------------------------------------------------------------
    // Deposit (buy PT)
    // -----------------------------------------------------------------------

    function test_Deposit_BuysPtAndReportsAssets() public {
        _configure();
        uint256 amount = 1000 * 1e6;
        usdc.mint(address(vault), amount); // seed the diamond's idle balance

        PendlePtStrategyFacet(address(vault)).pendleDeposit(amount);

        assertEq(usdc.balanceOf(address(vault)), 0, "idle underlying fully spent on PT");
        assertEq(pt.balanceOf(address(vault)), amount, "diamond holds PT at par");
        assertEq(
            PendlePtStrategyFacet(address(vault)).pendleTotalAssets(), amount, "position reported in underlying units"
        );
    }

    function test_Deposit_AtDiscount_MintsMorePt() public {
        _configure();
        router.setDepositRateBps(10_500); // buy PT at a 5% discount -> more PT per USDC
        uint256 amount = 1000 * 1e6;
        usdc.mint(address(vault), amount);

        PendlePtStrategyFacet(address(vault)).pendleDeposit(amount);

        uint256 expectedPt = (amount * 10_500) / 10_000;
        assertEq(pt.balanceOf(address(vault)), expectedPt, "discount captured as extra PT");
        assertEq(PendlePtStrategyFacet(address(vault)).pendleTotalAssets(), expectedPt, "face value reported");
    }

    function test_Deposit_RevertsWhenExpired() public {
        _configure();
        vm.warp(expiry); // at/after expiry the market is closed for buys
        usdc.mint(address(vault), 1000 * 1e6);

        vm.expectRevert(PendlePtStrategyFacet.PendleMarketExpired.selector);
        PendlePtStrategyFacet(address(vault)).pendleDeposit(1000 * 1e6);
    }

    function test_Deposit_RevertsWhenZeroPtReceived() public {
        _configure();
        router.setDepositRateBps(0); // router mints no PT
        usdc.mint(address(vault), 1000 * 1e6);

        vm.expectRevert(abi.encodeWithSelector(PendlePtStrategyFacet.PendleDepositFailed.selector, 0));
        PendlePtStrategyFacet(address(vault)).pendleDeposit(1000 * 1e6);
    }

    // -----------------------------------------------------------------------
    // Withdraw — pre-maturity (sell on AMM) vs post-maturity (redeem 1:1)
    // -----------------------------------------------------------------------

    function test_Withdraw_PreMaturity_SellsPtForUnderlying() public {
        _configure();
        uint256 amount = 1000 * 1e6;
        usdc.mint(address(vault), amount);
        PendlePtStrategyFacet(address(vault)).pendleDeposit(amount);

        PendlePtStrategyFacet(address(vault)).pendleWithdraw(400 * 1e6);

        assertEq(usdc.balanceOf(address(vault)), 400 * 1e6, "underlying back to idle");
        assertEq(pt.balanceOf(address(vault)), 600 * 1e6, "PT reduced by the sold amount");
        assertEq(PendlePtStrategyFacet(address(vault)).pendleTotalAssets(), 600 * 1e6, "remaining position reported");
    }

    function test_Withdraw_PostMaturity_RedeemsAtFaceValue() public {
        _configure();
        uint256 amount = 1000 * 1e6;
        usdc.mint(address(vault), amount);
        PendlePtStrategyFacet(address(vault)).pendleDeposit(amount);

        vm.warp(expiry + 1); // PT now redeems 1:1 via redeemPyToToken
        assertTrue(PendlePtStrategyFacet(address(vault)).pendleIsExpired(), "PT expired");

        PendlePtStrategyFacet(address(vault)).pendleWithdraw(amount);

        assertEq(usdc.balanceOf(address(vault)), amount, "full face value redeemed");
        assertEq(pt.balanceOf(address(vault)), 0, "PT fully burned");
    }

    function test_Withdraw_RevertsOnInsufficientPt() public {
        _configure();
        uint256 amount = 1000 * 1e6;
        usdc.mint(address(vault), amount);
        PendlePtStrategyFacet(address(vault)).pendleDeposit(amount);

        vm.expectRevert(abi.encodeWithSelector(PendlePtStrategyFacet.PendleInsufficientPt.selector, amount + 1, amount));
        PendlePtStrategyFacet(address(vault)).pendleWithdraw(amount + 1);
    }

    function test_Withdraw_RevertsWhenZeroReceived() public {
        _configure();
        uint256 amount = 1000 * 1e6;
        usdc.mint(address(vault), amount);
        PendlePtStrategyFacet(address(vault)).pendleDeposit(amount);

        router.setWithdrawHaircutBps(10_000); // 100% haircut -> zero underlying out

        vm.expectRevert(abi.encodeWithSelector(PendlePtStrategyFacet.PendleWithdrawFailed.selector, 400 * 1e6, 0));
        PendlePtStrategyFacet(address(vault)).pendleWithdraw(400 * 1e6);
    }

    // -----------------------------------------------------------------------
    // Harvest — no-op (PT has no claimable rewards)
    // -----------------------------------------------------------------------

    function test_Harvest_IsNoOp() public {
        _configure();
        uint256 amount = 1000 * 1e6;
        usdc.mint(address(vault), amount);
        PendlePtStrategyFacet(address(vault)).pendleDeposit(amount);

        uint256 before = PendlePtStrategyFacet(address(vault)).pendleTotalAssets();
        PendlePtStrategyFacet(address(vault)).pendleHarvest(); // must not revert
        assertEq(PendlePtStrategyFacet(address(vault)).pendleTotalAssets(), before, "harvest is a no-op");
    }

    // -----------------------------------------------------------------------
    // Readers
    // -----------------------------------------------------------------------

    function test_IsExpired_ReflectsMaturity() public {
        _configure();
        assertFalse(PendlePtStrategyFacet(address(vault)).pendleIsExpired(), "not expired before maturity");
        vm.warp(expiry);
        assertTrue(PendlePtStrategyFacet(address(vault)).pendleIsExpired(), "expired at maturity");
    }

    function test_Expiry_ReturnsConfigured() public {
        _configure();
        assertEq(PendlePtStrategyFacet(address(vault)).pendleExpiry(), expiry, "expiry readable");
    }

    // -----------------------------------------------------------------------
    // End-to-end through the allocator
    // -----------------------------------------------------------------------

    function test_Rebalance_RoutesAssetsIntoPendle() public {
        _configure();
        _register();
        _depositToVault(alice, 1000 * 1e6);
        _setSingleAllocation(PENDLE_ID, 8000); // 80% to Pendle

        vm.roll(block.number + 1);
        vm.prank(owner);
        AllocatorFacet(address(vault)).rebalance();

        assertEq(PendlePtStrategyFacet(address(vault)).pendleTotalAssets(), 800 * 1e6, "80% routed into PT");
        assertEq(usdc.balanceOf(address(vault)), 200 * 1e6, "20% stays idle");
        assertApproxEqAbs(vault.totalAssets(), 1000 * 1e6, 1, "totalAssets unchanged across rebalance");
    }

    function test_Rebalance_PullsBackWhenAllocationDrops() public {
        _configure();
        _register();
        _depositToVault(alice, 1000 * 1e6);
        _setSingleAllocation(PENDLE_ID, 8000);
        vm.roll(block.number + 1);
        vm.prank(owner);
        AllocatorFacet(address(vault)).rebalance();

        // Drop the allocation to 0 and rebalance again — exercises the
        // pre-maturity sell path via pendleWithdraw.
        _setSingleAllocation(PENDLE_ID, 0);
        vm.roll(block.number + 1);
        vm.prank(owner);
        AllocatorFacet(address(vault)).rebalance();

        assertEq(PendlePtStrategyFacet(address(vault)).pendleTotalAssets(), 0, "PT position drained");
        assertApproxEqAbs(usdc.balanceOf(address(vault)), 1000 * 1e6, 1, "all assets back idle");
    }

    // -----------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------

    function _configure() internal {
        vm.prank(owner);
        PendlePtStrategyFacet(address(vault))
            .pendleSetConfig(IPendleRouter(address(router)), market, IPPrincipalToken(address(pt)));
    }

    function _register() internal {
        vm.prank(owner);
        AllocatorFacet(address(vault)).registerStrategy(PENDLE_ID, _pendleStrategyConfig());
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

    function _pendleStrategyConfig() internal pure returns (LibAllocator.StrategyConfig memory) {
        return LibAllocator.StrategyConfig({
            totalAssetsSelector: PendlePtStrategyFacet.pendleTotalAssets.selector,
            depositSelector: PendlePtStrategyFacet.pendleDeposit.selector,
            withdrawSelector: PendlePtStrategyFacet.pendleWithdraw.selector,
            harvestSelector: PendlePtStrategyFacet.pendleHarvest.selector,
            capBps: 0,
            active: false // overwritten in registerStrategy
        });
    }

    function _deployVault() internal returns (Vault) {
        DiamondCutFacet cut = new DiamondCutFacet();
        DiamondLoupeFacet loupe = new DiamondLoupeFacet();
        OwnershipFacet ownership = new OwnershipFacet();
        AllocatorFacet allocator = new AllocatorFacet();
        PendlePtStrategyFacet pendle = new PendlePtStrategyFacet();

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
            facetAddress: address(pendle), action: IDiamond.FacetCutAction.Add, functionSelectors: _pendleSelectors()
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

    function _pendleSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](10);
        s[0] = PendlePtStrategyFacet.pendleSetConfig.selector;
        s[1] = PendlePtStrategyFacet.pendleTotalAssets.selector;
        s[2] = PendlePtStrategyFacet.pendleDeposit.selector;
        s[3] = PendlePtStrategyFacet.pendleWithdraw.selector;
        s[4] = PendlePtStrategyFacet.pendleHarvest.selector;
        s[5] = PendlePtStrategyFacet.pendleRouter.selector;
        s[6] = PendlePtStrategyFacet.pendleMarket.selector;
        s[7] = PendlePtStrategyFacet.pendlePT.selector;
        s[8] = PendlePtStrategyFacet.pendleIsExpired.selector;
        s[9] = PendlePtStrategyFacet.pendleExpiry.selector;
    }
}
