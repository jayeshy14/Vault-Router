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
import { PendlePtStrategyFacet } from "../../src/facets/strategies/PendlePtStrategyFacet.sol";
import { IPendleRouter } from "../../src/interfaces/external/IPendleRouter.sol";
import { IPPrincipalToken } from "../../src/interfaces/external/IPPrincipalToken.sol";
import { IPYLpOracle } from "../../src/interfaces/external/IPYLpOracle.sol";
import { LibAllocator } from "../../src/libraries/LibAllocator.sol";

/// @title PendleStrategyForkTest
/// @notice Exercises the PendlePtStrategyFacet end-to-end against a real Pendle
///         PT market on Arbitrum One. Skipped automatically when no Arbitrum
///         RPC is available — set ARBITRUM_RPC_URL to opt in. Also skipped until
///         ARB_PENDLE_MARKET / ARB_PENDLE_PT are set to a live, non-expired
///         USDC market (see below). Mirrors AaveStrategy.fork.t.sol.
///
///         NOTE on assertions: unlike the lending strategies, PT does not track
///         the underlying 1:1 pre-maturity — it is bought at a discount and
///         `pendleTotalAssets` reports PT face value. So the routed position is
///         asserted as "face value ≥ cost" rather than an exact figure, and the
///         pin block must precede the market's expiry for the buy path.
contract PendleStrategyForkTest is Test {
    // -----------------------------------------------------------------------
    // Arbitrum One — native USDC and Pendle.
    // Pendle RouterV4 (Arbitrum): 0x888888888889758F76e7103c6CbF23ABbF58F946.
    // TODO: set ARB_PENDLE_MARKET (PT/SY pool) and ARB_PENDLE_PT (PT token) to a
    //       live, non-expired USDC-settling market on Arbitrum, and pin
    //       ARBITRUM_FORK_BLOCK to a block before that market's expiry. Left as
    //       address(0) until confirmed — the test skips while unset so it never
    //       silently passes against a bogus market.
    // -----------------------------------------------------------------------
    address internal constant ARB_USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address internal constant ARB_PENDLE_ROUTER = 0x888888888889758F76e7103c6CbF23ABbF58F946;
    address internal constant ARB_PENDLE_MARKET = address(0);
    address internal constant ARB_PENDLE_PT = address(0);
    // Mandatory oracle for swaps: set to the live Pendle PtYtLpOracle on Arbitrum
    // for the chosen market (TODO: confirm address + that the market's oracle is
    // ready for ARB_PENDLE_TWAP via getOracleState). Left as address(0) so the
    // test skips until wired — pendleDeposit/withdraw now revert without it.
    address internal constant ARB_PENDLE_ORACLE = address(0);
    uint32 internal constant ARB_PENDLE_TWAP = 900;

    bytes32 internal constant PENDLE_ID = bytes32("pendle");

    Vault internal vault;
    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");

    function setUp() public {
        string memory rpc = vm.envOr("ARBITRUM_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        // Skip until a real, non-expired Arbitrum Pendle USDC market + oracle are
        // wired in (the oracle is mandatory for the swap paths).
        if (ARB_PENDLE_MARKET == address(0) || ARB_PENDLE_PT == address(0) || ARB_PENDLE_ORACLE == address(0)) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, vm.envOr("ARBITRUM_FORK_BLOCK", uint256(300_000_000)));

        vault = _deployVault();

        vm.startPrank(owner);
        PendlePtStrategyFacet(address(vault))
            .pendleSetConfig(IPendleRouter(ARB_PENDLE_ROUTER), ARB_PENDLE_MARKET, IPPrincipalToken(ARB_PENDLE_PT));
        PendlePtStrategyFacet(address(vault)).pendleSetOracle(IPYLpOracle(ARB_PENDLE_ORACLE), ARB_PENDLE_TWAP);
        AllocatorFacet(address(vault)).registerStrategy(PENDLE_ID, _pendleStrategyConfig());
        _setSingleAllocation(PENDLE_ID, 8000); // 80% to Pendle
        vm.stopPrank();
    }

    // -----------------------------------------------------------------------
    // Tests
    // -----------------------------------------------------------------------

    function test_DepositRebalanceBuysPt() public {
        _seedAndDeposit(alice, 1000 * 1e6);

        assertEq(IERC20(ARB_USDC).balanceOf(address(vault)), 1000 * 1e6, "USDC sits idle pre-rebalance");

        vm.roll(block.number + 1);
        vm.prank(owner);
        AllocatorFacet(address(vault)).rebalance();

        // 80% (800 USDC) spent on PT, 20% stays idle. PT is bought at a discount,
        // so face value (== pendleTotalAssets) is at least the 800 spent.
        assertEq(IERC20(ARB_USDC).balanceOf(address(vault)), 200 * 1e6, "20% idle");
        assertGe(PendlePtStrategyFacet(address(vault)).pendleTotalAssets(), 800 * 1e6, "PT face value >= cost");
        assertGt(IERC20(ARB_PENDLE_PT).balanceOf(address(vault)), 0, "diamond holds PT");
    }

    function test_RebalancePullsBackFromPendle() public {
        _seedAndDeposit(alice, 1000 * 1e6);
        vm.roll(block.number + 1);
        vm.prank(owner);
        AllocatorFacet(address(vault)).rebalance();

        // Drop the allocation to 0 and rebalance — sells PT back to USDC on the
        // Pendle AMM via pendleWithdraw (pre-maturity path).
        vm.prank(owner);
        _setSingleAllocation(PENDLE_ID, 0);
        vm.roll(block.number + 1);
        vm.prank(owner);
        AllocatorFacet(address(vault)).rebalance();

        assertEq(PendlePtStrategyFacet(address(vault)).pendleTotalAssets(), 0, "PT position drained");
        // Selling PT before maturity realises the AMM discount, so the idle
        // balance returns to within a few percent of the original 1000.
        assertApproxEqRel(
            IERC20(ARB_USDC).balanceOf(address(vault)), 1000 * 1e6, 5e16, "assets back idle (within AMM slippage)"
        );
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

    function _pendleStrategyConfig() internal pure returns (LibAllocator.StrategyConfig memory) {
        return LibAllocator.StrategyConfig({
            totalAssetsSelector: PendlePtStrategyFacet.pendleTotalAssets.selector,
            depositSelector: PendlePtStrategyFacet.pendleDeposit.selector,
            withdrawSelector: PendlePtStrategyFacet.pendleWithdraw.selector,
            harvestSelector: PendlePtStrategyFacet.pendleHarvest.selector,
            capBps: 0,
            active: false
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

        return new Vault(IERC20(ARB_USDC), "Vault Router", "vUSDC", owner, cuts, address(0), "");
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
        s = new bytes4[](11);
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
    }
}
