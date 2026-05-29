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
import { GuardFacet } from "../../src/facets/GuardFacet.sol";
import { IdleStrategyFacet } from "../../src/facets/strategies/IdleStrategyFacet.sol";
import { AllocatorFacet } from "../../src/facets/AllocatorFacet.sol";
import { LibAllocator } from "../../src/libraries/LibAllocator.sol";
import { LibGuard } from "../../src/libraries/LibGuard.sol";
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

/// @notice Exercises the NAV circuit breaker: the hot-path deviation tripwire on
///         deposit/withdraw, the permissionless latching poke, and owner pause
///         controls. NAV is moved by simulating gains/losses in the mock strategy.
contract CircuitBreakerTest is Test {
    MockUSDC internal usdc;
    Vault internal vault;
    MockProtocol internal mockProtocol;

    address internal owner = makeAddr("owner");
    address internal keeper = makeAddr("keeper");
    address internal alice = makeAddr("alice");

    bytes32 internal constant MOCK_ID = bytes32("mock");
    uint16 internal constant BOUND_BPS = 1000; // 10%

    event Paused(address indexed by);
    event Unpaused(address indexed by, uint256 baseline);
    event BreakerTripped(uint256 lastSharePrice, uint256 currentSharePrice);

    function setUp() public {
        usdc = new MockUSDC();
        mockProtocol = new MockProtocol(IERC20(address(usdc)));
        vault = _deployVault();

        vm.prank(owner);
        MockStrategyFacet(address(vault)).mockSetProtocol(mockProtocol);
        vm.prank(owner);
        AllocatorFacet(address(vault)).registerStrategy(MOCK_ID, _mockStrategyConfig(0));

        // Deposit and deploy 100% into the mock so a strategy loss maps 1:1 to NAV.
        _depositToVault(alice, 1000 * 1e6);
        _setSingleAllocation(MOCK_ID, 10_000);
        vm.roll(block.number + 1);
        vm.prank(owner);
        AllocatorFacet(address(vault)).rebalance();
    }

    // -----------------------------------------------------------------------
    // configuration / access control
    // -----------------------------------------------------------------------

    function test_SetMaxDelta_OwnerOnly() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LibDiamond.NotContractOwner.selector, alice, owner));
        GuardFacet(address(vault)).setMaxSharePriceDelta(BOUND_BPS);
    }

    function test_SetMaxDelta_RejectsOutOfRange() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(GuardFacet.InvalidBps.selector, 10_001));
        GuardFacet(address(vault)).setMaxSharePriceDelta(10_001);
    }

    function test_SetMaxDelta_StoresValue() public {
        vm.prank(owner);
        GuardFacet(address(vault)).setMaxSharePriceDelta(BOUND_BPS);
        assertEq(GuardFacet(address(vault)).maxSharePriceDeltaBps(), BOUND_BPS);
    }

    function test_Pause_OwnerOnly() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LibDiamond.NotContractOwner.selector, alice, owner));
        GuardFacet(address(vault)).pause();
    }

    // -----------------------------------------------------------------------
    // manual pause halts deposit + withdraw
    // -----------------------------------------------------------------------

    function test_ManualPause_BlocksDeposit() public {
        vm.prank(owner);
        GuardFacet(address(vault)).pause();
        assertTrue(GuardFacet(address(vault)).paused());

        usdc.mint(alice, 100 * 1e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), 100 * 1e6);
        vm.expectRevert(LibGuard.EnforcedPause.selector);
        vault.deposit(100 * 1e6, alice);
        vm.stopPrank();
    }

    function test_ManualPause_BlocksWithdraw() public {
        vm.prank(owner);
        GuardFacet(address(vault)).pause();

        vm.prank(alice);
        vm.expectRevert(LibGuard.EnforcedPause.selector);
        vault.withdraw(10 * 1e6, alice, alice);
    }

    function test_Unpause_ResumesAndRebaselines() public {
        vm.startPrank(owner);
        GuardFacet(address(vault)).pause();
        GuardFacet(address(vault)).unpause();
        vm.stopPrank();

        assertFalse(GuardFacet(address(vault)).paused());
        // Baseline was reset to the live price, so a normal deposit goes through.
        _depositToVault(alice, 100 * 1e6);
    }

    // -----------------------------------------------------------------------
    // hot-path deviation tripwire
    // -----------------------------------------------------------------------

    function test_Tripwire_RevertsDepositOnLargeLoss() public {
        vm.prank(owner);
        GuardFacet(address(vault)).setMaxSharePriceDelta(BOUND_BPS);
        _armBreaker();

        // Strategy loses 20% — beyond the 10% bound.
        mockProtocol._testSimulateLoss(address(vault), 200 * 1e6);

        uint256 last = GuardFacet(address(vault)).lastSharePrice();
        usdc.mint(alice, 100 * 1e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), 100 * 1e6);
        vm.expectRevert(
            abi.encodeWithSelector(LibGuard.SharePriceDeviation.selector, last, _liveSharePrice(), BOUND_BPS)
        );
        vault.deposit(100 * 1e6, alice);
        vm.stopPrank();
    }

    function test_Tripwire_RevertsWithdrawOnLargeLoss() public {
        vm.prank(owner);
        GuardFacet(address(vault)).setMaxSharePriceDelta(BOUND_BPS);
        _armBreaker();

        mockProtocol._testSimulateLoss(address(vault), 200 * 1e6);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                LibGuard.SharePriceDeviation.selector,
                GuardFacet(address(vault)).lastSharePrice(),
                _liveSharePrice(),
                BOUND_BPS
            )
        );
        vault.withdraw(10 * 1e6, alice, alice);
    }

    function test_Tripwire_AllowsWithinBound() public {
        vm.prank(owner);
        GuardFacet(address(vault)).setMaxSharePriceDelta(BOUND_BPS);
        _armBreaker();

        // 5% loss — within the 10% bound. Deposit still succeeds.
        mockProtocol._testSimulateLoss(address(vault), 50 * 1e6);
        _depositToVault(alice, 100 * 1e6);
    }

    function test_Tripwire_TriggersOnLargeGainToo() public {
        vm.prank(owner);
        GuardFacet(address(vault)).setMaxSharePriceDelta(BOUND_BPS);
        _armBreaker();

        // 30% sudden gain (e.g. price manipulation) also breaches the bound.
        mockProtocol._testAccrueYield(address(vault), 300 * 1e6);

        usdc.mint(alice, 100 * 1e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), 100 * 1e6);
        vm.expectRevert(
            abi.encodeWithSelector(
                LibGuard.SharePriceDeviation.selector,
                GuardFacet(address(vault)).lastSharePrice(),
                _liveSharePrice(),
                BOUND_BPS
            )
        );
        vault.deposit(100 * 1e6, alice);
        vm.stopPrank();
    }

    function test_Disabled_LossDoesNotTrip() public {
        // maxDelta left at 0 (default disabled).
        _armBreaker();
        mockProtocol._testSimulateLoss(address(vault), 500 * 1e6); // 50% loss
        _depositToVault(alice, 100 * 1e6); // still works
        GuardFacet(address(vault)).guardCheckpoint();
        assertFalse(GuardFacet(address(vault)).paused());
    }

    // -----------------------------------------------------------------------
    // permissionless latching poke
    // -----------------------------------------------------------------------

    function test_GuardCheckpoint_LatchesPauseOnDeviation() public {
        vm.prank(owner);
        GuardFacet(address(vault)).setMaxSharePriceDelta(BOUND_BPS);
        _armBreaker();

        mockProtocol._testSimulateLoss(address(vault), 200 * 1e6); // 20% loss

        uint256 last = GuardFacet(address(vault)).lastSharePrice();
        vm.expectEmit(false, false, false, true, address(vault));
        emit BreakerTripped(last, _liveSharePrice());
        vm.prank(keeper); // anyone can poke
        GuardFacet(address(vault)).guardCheckpoint();

        assertTrue(GuardFacet(address(vault)).paused());

        // Once latched, deposits are halted even though the move was transient.
        usdc.mint(alice, 100 * 1e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), 100 * 1e6);
        vm.expectRevert(LibGuard.EnforcedPause.selector);
        vault.deposit(100 * 1e6, alice);
        vm.stopPrank();
    }

    function test_GuardCheckpoint_NoOpWithinBound() public {
        vm.prank(owner);
        GuardFacet(address(vault)).setMaxSharePriceDelta(BOUND_BPS);
        _armBreaker();

        mockProtocol._testSimulateLoss(address(vault), 50 * 1e6); // 5% loss
        vm.prank(keeper);
        GuardFacet(address(vault)).guardCheckpoint();

        assertFalse(GuardFacet(address(vault)).paused());
    }

    function test_OwnerCanRecoverAfterTrip() public {
        vm.prank(owner);
        GuardFacet(address(vault)).setMaxSharePriceDelta(BOUND_BPS);
        _armBreaker();
        mockProtocol._testSimulateLoss(address(vault), 200 * 1e6);
        vm.prank(keeper);
        GuardFacet(address(vault)).guardCheckpoint();
        assertTrue(GuardFacet(address(vault)).paused());

        // Owner reviews, accepts the new NAV, and unpauses (rebaselines).
        vm.prank(owner);
        GuardFacet(address(vault)).unpause();
        assertFalse(GuardFacet(address(vault)).paused());
        _depositToVault(alice, 100 * 1e6);
    }

    // -----------------------------------------------------------------------
    // helpers
    // -----------------------------------------------------------------------

    function _armBreaker() internal {
        GuardFacet(address(vault)).guardCheckpoint(); // sets first checkpoint baseline
    }

    function _liveSharePrice() internal view returns (uint256) {
        return LibGuard.sharePrice(vault.totalAssets(), vault.totalSupply());
    }

    function _deployVault() internal returns (Vault) {
        DiamondCutFacet cut = new DiamondCutFacet();
        DiamondLoupeFacet loupe = new DiamondLoupeFacet();
        OwnershipFacet ownership = new OwnershipFacet();
        GuardFacet guard = new GuardFacet();
        IdleStrategyFacet idle = new IdleStrategyFacet();
        AllocatorFacet allocator = new AllocatorFacet();
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
            facetAddress: address(guard), action: IDiamond.FacetCutAction.Add, functionSelectors: _guardSelectors()
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

    function _guardSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](7);
        s[0] = GuardFacet.setMaxSharePriceDelta.selector;
        s[1] = GuardFacet.pause.selector;
        s[2] = GuardFacet.unpause.selector;
        s[3] = GuardFacet.guardCheckpoint.selector;
        s[4] = GuardFacet.paused.selector;
        s[5] = GuardFacet.maxSharePriceDeltaBps.selector;
        s[6] = GuardFacet.lastSharePrice.selector;
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
