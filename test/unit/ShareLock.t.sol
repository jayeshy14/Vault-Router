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
import { LockFacet } from "../../src/facets/LockFacet.sol";
import { LibDiamond } from "../../src/libraries/LibDiamond.sol";
import { LibLock } from "../../src/libraries/LibLock.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

/// @title ShareLockTest
/// @notice Unit coverage for the post-deposit share-lock window (Tier 2.5).
///         Verifies the lock arms on deposit, blocks withdraw/redeem AND
///         transfer within the window (the transfer path closes the
///         transfer-then-withdraw bypass), releases after it elapses, and is a
///         no-op when disabled.
contract ShareLockTest is Test {
    MockUSDC internal usdc;
    Vault internal vault;

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint64 internal constant PERIOD = 300; // 5 minutes

    function setUp() public {
        usdc = new MockUSDC();
        vault = _deployVault();
        usdc.mint(alice, 1_000_000 * 1e6);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
    }

    // -----------------------------------------------------------------------
    // setShareLockPeriod — gating & validation
    // -----------------------------------------------------------------------

    function test_SetShareLockPeriod_SetsAndEmits() public {
        vm.expectEmit(false, false, false, true, address(vault));
        emit LockFacet.ShareLockPeriodSet(PERIOD);
        vm.prank(owner);
        LockFacet(address(vault)).setShareLockPeriod(PERIOD);
        assertEq(LockFacet(address(vault)).shareLockPeriod(), PERIOD, "stored and readable");
    }

    function test_SetShareLockPeriod_RevertsAboveMax() public {
        uint64 tooLong = uint64(1 days) + 1;
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(LockFacet.ShareLockPeriodTooLong.selector, tooLong, LibLock.MAX_SHARE_LOCK_PERIOD)
        );
        LockFacet(address(vault)).setShareLockPeriod(tooLong);
    }

    function test_SetShareLockPeriod_RevertsForNonOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LibDiamond.NotContractOwner.selector, alice, owner));
        LockFacet(address(vault)).setShareLockPeriod(PERIOD);
    }

    function test_ShareLockPeriod_DefaultsToZeroDisabled() public view {
        assertEq(LockFacet(address(vault)).shareLockPeriod(), 0, "off by default");
    }

    // -----------------------------------------------------------------------
    // Lock arming
    // -----------------------------------------------------------------------

    function test_Deposit_ArmsLockForReceiver() public {
        _setPeriod(PERIOD);
        uint256 expectedUnlock = block.timestamp + PERIOD;
        vm.prank(alice);
        vault.deposit(1000 * 1e6, alice);
        assertEq(LockFacet(address(vault)).lockedUntil(alice), expectedUnlock, "lock armed to now + period");
    }

    function test_Deposit_NoLockWhenDisabled() public {
        // Period defaults to 0; deposit then immediate withdraw must succeed.
        vm.startPrank(alice);
        vault.deposit(1000 * 1e6, alice);
        vault.withdraw(1000 * 1e6, alice, alice);
        vm.stopPrank();
        assertEq(LockFacet(address(vault)).lockedUntil(alice), 0, "no lock set when disabled");
    }

    // -----------------------------------------------------------------------
    // Enforcement — withdraw / redeem / transfer within the window
    // -----------------------------------------------------------------------

    function test_Withdraw_RevertsWithinLockWindow() public {
        _setPeriod(PERIOD);
        uint256 unlockAt = block.timestamp + PERIOD;
        vm.startPrank(alice);
        vault.deposit(1000 * 1e6, alice);
        vm.expectRevert(abi.encodeWithSelector(LibLock.SharesLocked.selector, alice, unlockAt));
        vault.withdraw(500 * 1e6, alice, alice);
        vm.stopPrank();
    }

    function test_Redeem_RevertsWithinLockWindow() public {
        _setPeriod(PERIOD);
        uint256 unlockAt = block.timestamp + PERIOD;
        vm.startPrank(alice);
        uint256 shares = vault.deposit(1000 * 1e6, alice);
        vm.expectRevert(abi.encodeWithSelector(LibLock.SharesLocked.selector, alice, unlockAt));
        vault.redeem(shares, alice, alice);
        vm.stopPrank();
    }

    function test_Transfer_RevertsWithinLockWindow() public {
        _setPeriod(PERIOD);
        uint256 unlockAt = block.timestamp + PERIOD;
        vm.startPrank(alice);
        uint256 shares = vault.deposit(1000 * 1e6, alice);
        // Transfer-then-withdraw bypass is closed: the transfer itself reverts.
        vm.expectRevert(abi.encodeWithSelector(LibLock.SharesLocked.selector, alice, unlockAt));
        vault.transfer(bob, shares);
        vm.stopPrank();
    }

    // -----------------------------------------------------------------------
    // Release — after the window elapses
    // -----------------------------------------------------------------------

    function test_Withdraw_SucceedsAfterLockWindow() public {
        _setPeriod(PERIOD);
        uint256 unlockAt = block.timestamp + PERIOD;
        vm.startPrank(alice);
        vault.deposit(1000 * 1e6, alice);

        vm.warp(unlockAt); // strict `<` check: at == unlockAt the shares are free
        uint256 before = usdc.balanceOf(alice);
        vault.withdraw(1000 * 1e6, alice, alice);
        vm.stopPrank();
        assertEq(usdc.balanceOf(alice) - before, 1000 * 1e6, "withdrawal settles after the window");
    }

    function test_Transfer_SucceedsAfterLockWindow() public {
        _setPeriod(PERIOD);
        vm.startPrank(alice);
        uint256 shares = vault.deposit(1000 * 1e6, alice);
        vm.warp(block.timestamp + PERIOD + 1);
        vault.transfer(bob, shares);
        vm.stopPrank();
        assertEq(vault.balanceOf(bob), shares, "transfer allowed once unlocked");
    }

    // -----------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------

    function _setPeriod(uint64 period) internal {
        vm.prank(owner);
        LockFacet(address(vault)).setShareLockPeriod(period);
    }

    function _deployVault() internal returns (Vault) {
        DiamondCutFacet cut = new DiamondCutFacet();
        DiamondLoupeFacet loupe = new DiamondLoupeFacet();
        OwnershipFacet ownership = new OwnershipFacet();
        LockFacet lock = new LockFacet();

        IDiamond.FacetCut[] memory cuts = new IDiamond.FacetCut[](4);
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

    function _lockSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](3);
        s[0] = LockFacet.setShareLockPeriod.selector;
        s[1] = LockFacet.shareLockPeriod.selector;
        s[2] = LockFacet.lockedUntil.selector;
    }
}
