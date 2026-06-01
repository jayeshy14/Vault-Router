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
import { WithdrawQueueFacet } from "../../src/facets/WithdrawQueueFacet.sol";
import { LockFacet } from "../../src/facets/LockFacet.sol";
import { LibAllocator } from "../../src/libraries/LibAllocator.sol";
import { LibWithdrawQueue } from "../../src/libraries/LibWithdrawQueue.sol";
import { LibRoles } from "../../src/libraries/LibRoles.sol";

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

/// @title WithdrawQueueTest
/// @notice Unit coverage for the asynchronous withdrawal queue (Tier 3): escrow
///         on request, return on cancel, burn-and-pay on fulfillment at the live
///         share price, and the headline illiquid-exit flow where capital parked
///         in a strategy is freed by a rebalance before the claim is paid.
contract WithdrawQueueTest is Test {
    MockUSDC internal usdc;
    MockProtocol internal mockProtocol;
    Vault internal vault;

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    bytes32 internal constant MOCK_ID = bytes32("mock");

    function setUp() public {
        usdc = new MockUSDC();
        mockProtocol = new MockProtocol(IERC20(address(usdc)));
        vault = _deployVault();

        vm.prank(owner);
        MockStrategyFacet(address(vault)).mockSetProtocol(mockProtocol);
        vm.prank(owner);
        AllocatorFacet(address(vault)).registerStrategy(MOCK_ID, _mockStrategyConfig());

        // Alice funds the vault and holds all the shares.
        usdc.mint(alice, 1000 * 1e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(1000 * 1e6, alice);
        vm.stopPrank();
    }

    // -----------------------------------------------------------------------
    // requestWithdraw — escrow
    // -----------------------------------------------------------------------

    function test_Request_EscrowsSharesAndRecordsRequest() public {
        uint256 shares = vault.balanceOf(alice);

        vm.expectEmit(true, true, true, true, address(vault));
        emit Vault.WithdrawRequested(0, alice, alice, shares);
        vm.prank(alice);
        uint256 id = vault.requestWithdraw(shares, alice);

        assertEq(id, 0, "first request id");
        assertEq(vault.balanceOf(alice), 0, "alice's shares escrowed");
        assertEq(vault.balanceOf(address(vault)), shares, "shares held in escrow by the vault");
        assertEq(WithdrawQueueFacet(address(vault)).pendingWithdrawShares(), shares, "pending tracked");

        LibWithdrawQueue.WithdrawRequest memory req = WithdrawQueueFacet(address(vault)).withdrawRequest(id);
        assertEq(req.owner, alice, "owner recorded");
        assertEq(req.receiver, alice, "receiver recorded");
        assertEq(req.shares, shares, "shares recorded");
    }

    function test_Request_RevertsOnZeroShares() public {
        vm.prank(alice);
        vm.expectRevert(Vault.WithdrawQueueZeroShares.selector);
        vault.requestWithdraw(0, alice);
    }

    function test_Request_RevertsOnZeroReceiver() public {
        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(Vault.WithdrawToZeroAddress.selector);
        vault.requestWithdraw(shares, address(0));
    }

    function test_Request_RevertsWhenSharesExceedBalance() public {
        uint256 tooMany = vault.balanceOf(alice) + 1;
        vm.prank(alice);
        vm.expectRevert(); // ERC20 insufficient balance on the escrow transfer
        vault.requestWithdraw(tooMany, alice);
    }

    // -----------------------------------------------------------------------
    // cancelWithdraw
    // -----------------------------------------------------------------------

    function test_Cancel_ReturnsSharesToOwner() public {
        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        uint256 id = vault.requestWithdraw(shares, alice);

        vm.expectEmit(true, true, false, true, address(vault));
        emit Vault.WithdrawCancelled(id, alice, shares);
        vm.prank(alice);
        vault.cancelWithdraw(id);

        assertEq(vault.balanceOf(alice), shares, "shares returned");
        assertEq(vault.balanceOf(address(vault)), 0, "escrow emptied");
        assertEq(WithdrawQueueFacet(address(vault)).pendingWithdrawShares(), 0, "pending cleared");
        assertEq(WithdrawQueueFacet(address(vault)).withdrawRequest(id).shares, 0, "request slot cleared");
    }

    function test_Cancel_RevertsForNonOwner() public {
        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        uint256 id = vault.requestWithdraw(shares, alice);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Vault.NotRequestOwner.selector, id, bob));
        vault.cancelWithdraw(id);
    }

    function test_Cancel_RevertsWhenNotFound() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Vault.WithdrawRequestNotFound.selector, 99));
        vault.cancelWithdraw(99);
    }

    // -----------------------------------------------------------------------
    // fulfillWithdraw
    // -----------------------------------------------------------------------

    function test_Fulfill_BurnsEscrowAndPaysReceiver() public {
        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        uint256 id = vault.requestWithdraw(shares, bob); // pay a different receiver

        uint256 supplyBefore = vault.totalSupply();
        uint256 expectedAssets = vault.convertToAssets(shares); // no fee recipient -> price stable

        vm.expectEmit(true, true, false, true, address(vault));
        emit Vault.WithdrawFulfilled(id, bob, shares, expectedAssets);
        vm.prank(owner); // owner is implicitly a curator
        vault.fulfillWithdraw(id);

        assertEq(usdc.balanceOf(bob), expectedAssets, "receiver paid the live-priced assets");
        assertEq(vault.balanceOf(address(vault)), 0, "escrowed shares burned");
        assertEq(vault.totalSupply(), supplyBefore - shares, "supply reduced by burned shares");
        assertEq(WithdrawQueueFacet(address(vault)).pendingWithdrawShares(), 0, "pending cleared");
    }

    function test_Fulfill_RevertsForNonCurator() public {
        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        uint256 id = vault.requestWithdraw(shares, alice);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LibRoles.NotCurator.selector, alice));
        vault.fulfillWithdraw(id);
    }

    function test_Fulfill_RevertsWhenNotFound() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Vault.WithdrawRequestNotFound.selector, 7));
        vault.fulfillWithdraw(7);
    }

    function test_Fulfill_PaysAtLiveSharePrice() public {
        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        uint256 id = vault.requestWithdraw(shares, alice);

        // Yield accrues to the vault after the request was queued. Because the
        // claim is priced at fulfil time (not request time), the requester
        // captures it.
        uint256 assetsAtRequest = vault.convertToAssets(shares);
        usdc.mint(address(vault), 100 * 1e6); // +10% donated as idle yield
        uint256 assetsAtFulfil = vault.convertToAssets(shares);
        assertGt(assetsAtFulfil, assetsAtRequest, "claim repriced upward by yield");

        vm.prank(owner);
        vault.fulfillWithdraw(id);
        assertEq(usdc.balanceOf(alice), assetsAtFulfil, "paid at the live, post-yield price");
    }

    // -----------------------------------------------------------------------
    // Illiquid exit — the reason the queue exists
    // -----------------------------------------------------------------------

    function test_IlliquidExit_FreedByRebalanceThenFulfilled() public {
        // Deploy 100% of the vault into the strategy, draining idle to zero.
        _setSingleAllocation(MOCK_ID, 10_000);
        vm.roll(block.number + 1);
        vm.prank(owner);
        AllocatorFacet(address(vault)).rebalance();
        assertEq(usdc.balanceOf(address(vault)), 0, "no idle after full deployment");

        // Alice queues a full exit.
        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        uint256 id = vault.requestWithdraw(shares, alice);

        // Nothing idle yet -> fulfilment reverts until liquidity is freed.
        uint256 owed = vault.convertToAssets(shares);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Vault.InsufficientIdleLiquidity.selector, owed, 0));
        vault.fulfillWithdraw(id);

        // Curator frees liquidity by pulling the strategy allocation back to 0.
        _setSingleAllocation(MOCK_ID, 0);
        vm.roll(block.number + 1);
        vm.prank(owner);
        AllocatorFacet(address(vault)).rebalance();

        // Now the claim can be paid.
        vm.prank(owner);
        vault.fulfillWithdraw(id);

        assertGt(usdc.balanceOf(alice), 0, "alice exited an illiquid position via the queue");
        assertEq(vault.balanceOf(address(vault)), 0, "escrow burned");
        assertEq(WithdrawQueueFacet(address(vault)).pendingWithdrawShares(), 0, "queue drained");
    }

    // -----------------------------------------------------------------------
    // Griefing regression (F01): an attacker must not be able to brick the queue
    // by arming the share lock on the vault's own escrow address.
    // -----------------------------------------------------------------------

    function test_Griefing_DepositToVaultCannotBrickQueue() public {
        // Enable the anti-MEV share lock — the precondition the old bug needed.
        vm.prank(owner);
        LockFacet(address(vault)).setShareLockPeriod(1 hours);

        // Alice escrows half her shares for an async exit (her setUp deposit
        // predates the lock, so her shares are unlocked and movable).
        uint256 shares = vault.balanceOf(alice) / 2;
        vm.prank(alice);
        uint256 id = vault.requestWithdraw(shares, alice);

        // Attacker attempts the brick: a 1-wei deposit naming the VAULT as
        // receiver, trying to arm lockedUntil[address(this)] so the escrow
        // _burn/_transfer in fulfill/cancel revert SharesLocked.
        address attacker = makeAddr("attacker");
        usdc.mint(attacker, 1);
        vm.startPrank(attacker);
        usdc.approve(address(vault), 1);
        vault.deposit(1, address(vault));
        vm.stopPrank();

        // The vault address must remain unlocked (caller != receiver ⇒ not armed).
        assertEq(
            LockFacet(address(vault)).lockedUntil(address(vault)), 0, "vault escrow address must never be lock-armed"
        );

        // Fulfill still works — the queue is not bricked.
        vm.prank(owner);
        vault.fulfillWithdraw(id);
        assertGt(usdc.balanceOf(alice), 0, "curator fulfilled despite griefing attempt");

        // And the cancel path is not bricked either.
        uint256 rest = vault.balanceOf(alice);
        vm.prank(alice);
        uint256 id2 = vault.requestWithdraw(rest, alice);
        vm.prank(alice);
        vault.cancelWithdraw(id2);
        assertEq(vault.balanceOf(alice), rest, "alice reclaimed escrowed shares via cancel");
    }

    // -----------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------

    function _setSingleAllocation(bytes32 id, uint16 bps) internal {
        bytes32[] memory ids = new bytes32[](1);
        uint16[] memory b = new uint16[](1);
        ids[0] = id;
        b[0] = bps;
        vm.prank(owner);
        AllocatorFacet(address(vault)).setAllocation(ids, b);
    }

    function _mockStrategyConfig() internal pure returns (LibAllocator.StrategyConfig memory) {
        return LibAllocator.StrategyConfig({
            totalAssetsSelector: MockStrategyFacet.mockTotalAssets.selector,
            depositSelector: MockStrategyFacet.mockDeposit.selector,
            withdrawSelector: MockStrategyFacet.mockWithdraw.selector,
            harvestSelector: MockStrategyFacet.mockHarvest.selector,
            capBps: 0,
            active: false // overwritten in registerStrategy
        });
    }

    function _deployVault() internal returns (Vault) {
        DiamondCutFacet cut = new DiamondCutFacet();
        DiamondLoupeFacet loupe = new DiamondLoupeFacet();
        OwnershipFacet ownership = new OwnershipFacet();
        AllocatorFacet allocator = new AllocatorFacet();
        MockStrategyFacet mock = new MockStrategyFacet();
        WithdrawQueueFacet queue = new WithdrawQueueFacet();
        LockFacet lock = new LockFacet();

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
            facetAddress: address(allocator),
            action: IDiamond.FacetCutAction.Add,
            functionSelectors: _allocatorSelectors()
        });
        cuts[4] = IDiamond.FacetCut({
            facetAddress: address(mock), action: IDiamond.FacetCutAction.Add, functionSelectors: _mockSelectors()
        });
        cuts[5] = IDiamond.FacetCut({
            facetAddress: address(queue),
            action: IDiamond.FacetCutAction.Add,
            functionSelectors: _withdrawQueueSelectors()
        });
        cuts[6] = IDiamond.FacetCut({
            facetAddress: address(lock), action: IDiamond.FacetCutAction.Add, functionSelectors: _lockSelectors()
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
        s = new bytes4[](6);
        s[0] = AllocatorFacet.registerStrategy.selector;
        s[1] = AllocatorFacet.setAllocation.selector;
        s[2] = AllocatorFacet.rebalance.selector;
        s[3] = AllocatorFacet.setIdleReserve.selector;
        s[4] = AllocatorFacet.strategyTotalAssets.selector;
        s[5] = AllocatorFacet.idleAssets.selector;
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

    function _withdrawQueueSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](3);
        s[0] = WithdrawQueueFacet.nextWithdrawRequestId.selector;
        s[1] = WithdrawQueueFacet.pendingWithdrawShares.selector;
        s[2] = WithdrawQueueFacet.withdrawRequest.selector;
    }

    function _lockSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](3);
        s[0] = LockFacet.setShareLockPeriod.selector;
        s[1] = LockFacet.shareLockPeriod.selector;
        s[2] = LockFacet.lockedUntil.selector;
    }
}
