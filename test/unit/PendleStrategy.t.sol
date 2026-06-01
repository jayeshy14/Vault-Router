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
import { IPYLpOracle } from "../../src/interfaces/external/IPYLpOracle.sol";
import { LibAllocator } from "../../src/libraries/LibAllocator.sol";
import { LibDiamond } from "../../src/libraries/LibDiamond.sol";

import { MockPrincipalToken, MockPendleRouter, MockPYLpOracle } from "../mocks/MockPendle.sol";

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
    MockPYLpOracle internal oracle;
    Vault internal vault;

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal market = makeAddr("market");
    address internal yt = makeAddr("yt");
    address internal sy = makeAddr("sy");

    uint256 internal expiry;

    bytes32 internal constant PENDLE_ID = bytes32("pendle");
    uint32 internal constant TWAP = 900;

    function setUp() public {
        usdc = new MockUSDC();
        expiry = block.timestamp + 365 days;
        pt = new MockPrincipalToken(6, expiry, yt, sy);
        router = new MockPendleRouter(IERC20(address(usdc)), pt);
        oracle = new MockPYLpOracle();
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

    function test_Deposit_RevertsForExternalCaller() public {
        _configure();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LibDiamond.NotSelf.selector, alice));
        PendlePtStrategyFacet(address(vault)).pendleDeposit(1e6);
    }

    function test_Withdraw_RevertsForExternalCaller() public {
        _configure();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LibDiamond.NotSelf.selector, alice));
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

    // The fund-movers are onlySelf, so deposits are driven through the
    // allocator's rebalance (the legitimate dispatch path). A mandatory oracle
    // is configured first — pendleDeposit refuses to swap unpriced.

    function test_Deposit_BuysPtAndReportsAssets() public {
        _configureWithOracle(); // par oracle (1e18)
        _register();
        uint256 amount = 1000 * 1e6;
        _deployAll(amount); // 100% target -> rebalance buys PT with all idle

        assertEq(usdc.balanceOf(address(vault)), 0, "idle underlying fully spent on PT");
        assertEq(pt.balanceOf(address(vault)), amount, "diamond holds PT at par");
        assertEq(
            PendlePtStrategyFacet(address(vault)).pendleTotalAssets(), amount, "position reported in underlying units"
        );
    }

    function test_Deposit_AtDiscount_MintsMorePt() public {
        _configureWithOracle();
        _register();
        router.setDepositRateBps(10_500); // buy PT at a 5% discount -> more PT per USDC
        uint256 amount = 1000 * 1e6;
        _deployAll(amount);

        uint256 expectedPt = (amount * 10_500) / 10_000;
        assertEq(pt.balanceOf(address(vault)), expectedPt, "discount captured as extra PT");
        assertEq(PendlePtStrategyFacet(address(vault)).pendleTotalAssets(), expectedPt, "marked at par == face");
    }

    // F05: a strategy's protective deposit refusal (expired market / missing
    // oracle / slippage breach) must SKIP that strategy, not brick the whole
    // rebalance. The protection still works — the funds simply stay idle and a
    // StrategyRebalanceSkipped event records the skip.

    function test_Deposit_SkippedWhenExpired() public {
        _configureWithOracle();
        _register();
        usdc.mint(address(vault), 1000 * 1e6);
        _setSingleAllocation(PENDLE_ID, 10_000);
        vm.warp(expiry); // at/after expiry the market is closed for buys
        vm.roll(block.number + 1);

        vm.expectEmit(true, false, false, true, address(vault));
        emit AllocatorFacet.StrategyRebalanceSkipped(PENDLE_ID, PendlePtStrategyFacet.pendleDeposit.selector);
        vm.prank(owner);
        AllocatorFacet(address(vault)).rebalance();

        assertEq(usdc.balanceOf(address(vault)), 1000 * 1e6, "funds stayed idle; expired-market deposit skipped");
        assertEq(PendlePtStrategyFacet(address(vault)).pendleTotalAssets(), 0, "no PT bought");
    }

    function test_Deposit_SkippedWhenNoOracle() public {
        // Mandatory oracle: a deposit on an unpriced market is refused outright
        // rather than swapped with minOut = 0 — and the refusal skips, not bricks.
        _configure(); // router/market/pt, but NO oracle
        _register();
        usdc.mint(address(vault), 1000 * 1e6);
        _setSingleAllocation(PENDLE_ID, 10_000);
        vm.roll(block.number + 1);

        vm.expectEmit(true, false, false, true, address(vault));
        emit AllocatorFacet.StrategyRebalanceSkipped(PENDLE_ID, PendlePtStrategyFacet.pendleDeposit.selector);
        vm.prank(owner);
        AllocatorFacet(address(vault)).rebalance();

        assertEq(usdc.balanceOf(address(vault)), 1000 * 1e6, "funds stayed idle; unpriced deposit skipped");
        assertEq(PendlePtStrategyFacet(address(vault)).pendleTotalAssets(), 0, "no PT bought");
    }

    function test_Deposit_SkippedWhenFillBelowOracleSlippageBound() public {
        _configure();
        _setOracle(0.95e18); // oracle: 1 PT = 0.95 USDC -> a buy should yield ~1.053x PT
        _register();
        usdc.mint(address(vault), 1000 * 1e6);
        _setSingleAllocation(PENDLE_ID, 10_000);
        vm.roll(block.number + 1);

        // Router fills at par (1000 PT) — ~5% worse than the oracle-implied amount,
        // beyond the default 1% tolerance. The router enforces our derived minPtOut,
        // so the deposit reverts internally and rebalance skips it.
        vm.expectEmit(true, false, false, true, address(vault));
        emit AllocatorFacet.StrategyRebalanceSkipped(PENDLE_ID, PendlePtStrategyFacet.pendleDeposit.selector);
        vm.prank(owner);
        AllocatorFacet(address(vault)).rebalance();

        assertEq(usdc.balanceOf(address(vault)), 1000 * 1e6, "funds stayed idle; over-slippage buy skipped");
        assertEq(PendlePtStrategyFacet(address(vault)).pendleTotalAssets(), 0, "no PT bought");
    }

    function test_Deposit_SucceedsWhenFillWithinOracleSlippageBound() public {
        _configure();
        _setOracle(0.95e18);
        _register();
        router.setDepositRateBps(10_500); // 1050 PT, within 1% of the ~1052.6 oracle mark
        uint256 amount = 1000 * 1e6;
        _deployAll(amount);

        assertEq(pt.balanceOf(address(vault)), (amount * 10_500) / 10_000, "fill within tolerance accepted");
    }

    // -----------------------------------------------------------------------
    // Slippage config — gating & validation
    // -----------------------------------------------------------------------

    function test_SetSlippage_SetsAndEmits() public {
        vm.expectEmit(false, false, false, true, address(vault));
        emit PendlePtStrategyFacet.PendleSlippageSet(250);
        vm.prank(owner);
        PendlePtStrategyFacet(address(vault)).pendleSetSlippage(250);
    }

    function test_SetSlippage_RevertsAboveBps() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(PendlePtStrategyFacet.PendleInvalidSlippage.selector, 10_001));
        PendlePtStrategyFacet(address(vault)).pendleSetSlippage(10_001);
    }

    function test_SetSlippage_RevertsForNonOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LibDiamond.NotContractOwner.selector, alice, owner));
        PendlePtStrategyFacet(address(vault)).pendleSetSlippage(100);
    }

    // -----------------------------------------------------------------------
    // Withdraw — pre-maturity (sell on AMM) vs post-maturity (redeem 1:1)
    // -----------------------------------------------------------------------

    function test_Withdraw_PreMaturity_SellsPtForUnderlying() public {
        _configureWithOracle();
        _register();
        _deployAll(1000 * 1e6); // 1000 PT, par oracle

        // Drop target to 60% -> rebalance sells 400 PT on the AMM.
        _setSingleAllocation(PENDLE_ID, 6000);
        vm.roll(block.number + 1);
        vm.prank(owner);
        AllocatorFacet(address(vault)).rebalance();

        assertEq(usdc.balanceOf(address(vault)), 400 * 1e6, "underlying back to idle");
        assertEq(pt.balanceOf(address(vault)), 600 * 1e6, "PT reduced by the sold amount");
        assertEq(PendlePtStrategyFacet(address(vault)).pendleTotalAssets(), 600 * 1e6, "remaining position reported");
    }

    /// @notice Regression for F03: rebalance computes withdrawal deltas in ASSET
    ///         units, and pendleWithdraw must convert them to a PT quantity at the
    ///         oracle mark — NOT treat the asset delta as a raw PT amount. At a
    ///         non-par mark the two diverge, which is where the original bug bit.
    function test_Withdraw_PreMaturity_AssetDenominatedAtDiscount() public {
        _configureWithOracle();
        _register();
        _deployAll(1000 * 1e6); // 1000 PT bought at par

        // Mark the live position down to a 0.8 rate: 1000 PT now == 800 asset.
        oracle.setRate(0.8e18);
        assertEq(PendlePtStrategyFacet(address(vault)).pendleTotalAssets(), 800 * 1e6, "PT marked to 800 asset");

        // Target the Pendle sleeve at 50% of NAV. NAV == 800 (idle 0 + pendle 800),
        // so target == 400 and the allocator asks to withdraw 400 of ASSET value.
        // Correct behavior: liquidate 400 / 0.8 == 500 PT (the old bug sold 400).
        _setSingleAllocation(PENDLE_ID, 5000);
        vm.roll(block.number + 1);
        vm.prank(owner);
        AllocatorFacet(address(vault)).rebalance();

        assertEq(pt.balanceOf(address(vault)), 500 * 1e6, "liquidated asset-denominated PT (400 / 0.8)");
        assertEq(
            PendlePtStrategyFacet(address(vault)).pendleTotalAssets(), 400 * 1e6, "Pendle sleeve converged to target"
        );
    }

    function test_Withdraw_PostMaturity_RedeemsAtFaceValue() public {
        _configureWithOracle();
        _register();
        _deployAll(1000 * 1e6);

        vm.warp(expiry + 1); // PT now redeems 1:1 via redeemPyToToken (no oracle needed)
        assertTrue(PendlePtStrategyFacet(address(vault)).pendleIsExpired(), "PT expired");

        _setSingleAllocation(PENDLE_ID, 0);
        vm.roll(block.number + 1);
        vm.prank(owner);
        AllocatorFacet(address(vault)).rebalance();

        assertEq(usdc.balanceOf(address(vault)), 1000 * 1e6, "full face value redeemed");
        assertEq(pt.balanceOf(address(vault)), 0, "PT fully burned");
    }

    function test_Withdraw_PreMaturity_SkippedWhenNoOracle() public {
        // Mandatory oracle on the pre-maturity sell. Build a PT position directly
        // (no oracle) so we can reach the sell path, then rebalance to 0%. The
        // unpriced-sell refusal skips the strategy rather than bricking rebalance.
        _configure(); // no oracle
        _register();
        pt.mint(address(vault), 1000 * 1e6);
        _setSingleAllocation(PENDLE_ID, 0);
        vm.roll(block.number + 1);

        vm.expectEmit(true, false, false, true, address(vault));
        emit AllocatorFacet.StrategyRebalanceSkipped(PENDLE_ID, PendlePtStrategyFacet.pendleWithdraw.selector);
        vm.prank(owner);
        AllocatorFacet(address(vault)).rebalance();

        assertEq(pt.balanceOf(address(vault)), 1000 * 1e6, "PT retained; unpriced sell skipped");
        assertEq(usdc.balanceOf(address(vault)), 0, "no underlying freed");
    }

    function test_Withdraw_SkippedWhenAmmHaircutExceedsSlippageBound() public {
        _configureWithOracle(); // par mark: minTokenOut = 99% of PT sold
        _register();
        _deployAll(1000 * 1e6);

        router.setWithdrawHaircutBps(500); // 5% AMM haircut, beyond the 1% tolerance
        _setSingleAllocation(PENDLE_ID, 6000); // sell 400
        vm.roll(block.number + 1);

        vm.expectEmit(true, false, false, true, address(vault));
        emit AllocatorFacet.StrategyRebalanceSkipped(PENDLE_ID, PendlePtStrategyFacet.pendleWithdraw.selector);
        vm.prank(owner);
        AllocatorFacet(address(vault)).rebalance();

        assertEq(pt.balanceOf(address(vault)), 1000 * 1e6, "PT retained; over-slippage sell skipped");
        assertEq(usdc.balanceOf(address(vault)), 0, "no underlying freed");
    }

    function test_Withdraw_SucceedsWhenHaircutWithinSlippageBound() public {
        _configureWithOracle();
        _register();
        _deployAll(1000 * 1e6);

        router.setWithdrawHaircutBps(50); // 0.5% haircut, within the 1% tolerance
        _setSingleAllocation(PENDLE_ID, 6000); // sell 400
        vm.roll(block.number + 1);
        vm.prank(owner);
        AllocatorFacet(address(vault)).rebalance();

        assertEq(usdc.balanceOf(address(vault)), (400 * 1e6 * 9950) / 10_000, "fill within tolerance settled");
    }

    // -----------------------------------------------------------------------
    // Oracle config — gating & validation
    // -----------------------------------------------------------------------

    function test_SetOracle_SetsAndEmits() public {
        vm.expectEmit(true, false, false, true, address(vault));
        emit PendlePtStrategyFacet.PendleOracleSet(address(oracle), TWAP);

        vm.prank(owner);
        PendlePtStrategyFacet(address(vault)).pendleSetOracle(IPYLpOracle(address(oracle)), TWAP);

        assertEq(address(PendlePtStrategyFacet(address(vault)).pendleOracle()), address(oracle), "oracle readable");
        assertEq(PendlePtStrategyFacet(address(vault)).pendleTwapDuration(), TWAP, "twap readable");
    }

    function test_SetOracle_RevertsOnZeroOracle() public {
        vm.prank(owner);
        vm.expectRevert(PendlePtStrategyFacet.PendleInvalidOracle.selector);
        PendlePtStrategyFacet(address(vault)).pendleSetOracle(IPYLpOracle(address(0)), TWAP);
    }

    function test_SetOracle_RevertsOnZeroDuration() public {
        vm.prank(owner);
        vm.expectRevert(PendlePtStrategyFacet.PendleInvalidOracle.selector);
        PendlePtStrategyFacet(address(vault)).pendleSetOracle(IPYLpOracle(address(oracle)), 0);
    }

    function test_SetOracle_RevertsForNonOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LibDiamond.NotContractOwner.selector, alice, owner));
        PendlePtStrategyFacet(address(vault)).pendleSetOracle(IPYLpOracle(address(oracle)), TWAP);
    }

    // -----------------------------------------------------------------------
    // Total assets — mark-to-market vs face value
    // -----------------------------------------------------------------------

    function test_TotalAssets_MarksToMarketWhenOracleSet() public {
        _configureWithOracle(); // buy at par
        _register();
        uint256 amount = 1000 * 1e6;
        _deployAll(amount);

        oracle.setRate(0.95e18); // mark the live position down to a 5% discount

        assertEq(pt.balanceOf(address(vault)), amount, "holds PT at face");
        assertEq(PendlePtStrategyFacet(address(vault)).pendleTotalAssets(), 950 * 1e6, "marked to market via oracle");
    }

    function test_TotalAssets_FaceValueWhenNoOracle() public {
        // The no-oracle valuation branch: hold PT (minted directly, since a
        // deposit now requires an oracle) and confirm it reports face value.
        _configure(); // no oracle
        uint256 amount = 1000 * 1e6;
        pt.mint(address(vault), amount);

        assertEq(PendlePtStrategyFacet(address(vault)).pendleTotalAssets(), amount, "face value without oracle");
    }

    function test_TotalAssets_PostMaturityIgnoresOracle() public {
        _configureWithOracle();
        _register();
        uint256 amount = 1000 * 1e6;
        _deployAll(amount);
        oracle.setRate(0.95e18); // discounted mark

        vm.warp(expiry + 1); // PT now redeems 1:1 — oracle discount must be bypassed

        assertEq(PendlePtStrategyFacet(address(vault)).pendleTotalAssets(), amount, "face value post-maturity");
    }

    // -----------------------------------------------------------------------
    // Harvest — no-op (PT has no claimable rewards)
    // -----------------------------------------------------------------------

    function test_Harvest_IsNoOp() public {
        _configureWithOracle();
        _register();
        _deployAll(1000 * 1e6);

        uint256 before = PendlePtStrategyFacet(address(vault)).pendleTotalAssets();
        PendlePtStrategyFacet(address(vault)).pendleHarvest(); // pure no-op, stays callable
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
        _configureWithOracle();
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
        _configureWithOracle();
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

    function _setOracle(uint256 rate) internal {
        oracle.setRate(rate);
        vm.prank(owner);
        PendlePtStrategyFacet(address(vault)).pendleSetOracle(IPYLpOracle(address(oracle)), TWAP);
    }

    function _register() internal {
        vm.prank(owner);
        AllocatorFacet(address(vault)).registerStrategy(PENDLE_ID, _pendleStrategyConfig());
    }

    /// @dev Configure router/market/pt plus a par (1e18) oracle. The oracle is
    ///      mandatory for deposits/pre-maturity sells now, so most position-
    ///      building tests need it.
    function _configureWithOracle() internal {
        _configure();
        _setOracle(1e18);
    }

    /// @dev Seed `amount` idle into the vault and rebalance it 100% into Pendle
    ///      via the allocator's self-dispatch — the only path that can move funds
    ///      now that the mutators are onlySelf. Caller configures (with oracle) +
    ///      registers first.
    function _deployAll(uint256 amount) internal {
        usdc.mint(address(vault), amount);
        _setSingleAllocation(PENDLE_ID, 10_000);
        vm.roll(block.number + 1);
        vm.prank(owner);
        AllocatorFacet(address(vault)).rebalance();
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
        s = new bytes4[](14);
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
        s[10] = PendlePtStrategyFacet.pendleSetOracle.selector;
        s[11] = PendlePtStrategyFacet.pendleOracle.selector;
        s[12] = PendlePtStrategyFacet.pendleTwapDuration.selector;
        s[13] = PendlePtStrategyFacet.pendleSetSlippage.selector;
    }
}
