// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import { LibDiamond } from "../../libraries/LibDiamond.sol";
import { IComet } from "../../interfaces/external/IComet.sol";

/// @title CompoundV3StrategyFacet
/// @notice Strategy facet that supplies the vault's underlying asset to a
///         Compound III (Comet) base market and reports its position via the
///         market's rebasing `balanceOf`.
/// @dev Selectors are prefixed with `compound*` so the facet coexists with other
///      strategy facets in the same Diamond without selector collisions. State
///      lives at EIP-7201 slot `vaultrouter.strategy.compound`.
///
///      Shape mirrors `AaveStrategyFacet`: Comet's `balanceOf` is a non-standard
///      rebasing balance that already includes accrued supply interest, so the
///      position needs no receipt-token bookkeeping and `harvest` is a no-op.
///      Unlike the Aave facet it validates `comet.baseToken()` against the
///      diamond's asset at config time (the same defensive check the Morpho facet
///      makes), so a market for the wrong asset can never be wired in.
contract CompoundV3StrategyFacet {
    using SafeERC20 for IERC20;

    /// @notice Thrown when the Comet market has not been configured.
    error CompoundCometNotConfigured();
    /// @notice Thrown when the configured market reports a zero base token.
    error CompoundBaseNotConfigured();
    /// @notice Thrown when the market's base token differs from the diamond's asset.
    error CompoundAssetMismatch();
    /// @notice Thrown when a supply credits fewer base units than supplied (beyond
    ///         acceptable rounding) — e.g. a fee-on-supply or misconfigured market.
    error CompoundDepositFailed(uint256 expected, uint256 received);
    /// @notice Thrown when a withdraw returns fewer base units than requested.
    error CompoundWithdrawFailed(uint256 expected, uint256 received);

    /// @notice Emitted when the Comet market is configured (or reconfigured).
    /// @param comet The Comet market now active for this strategy.
    /// @param baseToken The market's base asset (must equal the diamond's asset).
    event CompoundConfigSet(IComet indexed comet, address indexed baseToken);

    /// @dev Slack (in base units) tolerated between the amount supplied and the
    ///      present value credited by Comet. Comet stores principal as
    ///      `presentValue * 1e15 / baseSupplyIndex` (rounded down), so a supply can
    ///      credit a wei or two less than supplied. A shortfall beyond this is
    ///      treated as a real failure. Withdrawals transfer the exact requested
    ///      amount, so the same slack only ever helps there.
    uint256 internal constant SUPPLY_ROUNDING_SLACK = 2;

    /// @dev Precomputed erc7201("vaultrouter.strategy.compound"):
    ///      keccak256(abi.encode(uint256(keccak256(id)) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant COMPOUND_STORAGE_SLOT =
        0x2695057c79bcfe520225f23a9e04dfe44b4fdf099be81c65c6c26e611ce7be00;

    /// @custom:storage-location erc7201:vaultrouter.strategy.compound
    struct CompoundStorage {
        IComet comet;
    }

    function _cs() internal pure returns (CompoundStorage storage s) {
        bytes32 slot = COMPOUND_STORAGE_SLOT;
        assembly {
            s.slot := slot
        }
    }

    // -----------------------------------------------------------------------
    // Curator-gated setup
    // -----------------------------------------------------------------------

    /// @notice Set the Compound III market this strategy supplies to. Must be
    ///         called once before the strategy is registered with the allocator.
    /// @dev Owner-gated. Validates that the market's base token matches the
    ///      diamond's ERC4626 underlying before persisting, so capital can never
    ///      be routed into a market denominated in the wrong asset.
    /// @param comet The Comet base market (e.g. cUSDCv3 on Arbitrum).
    function compoundSetConfig(IComet comet) external {
        LibDiamond.enforceIsContractOwner();
        if (address(comet) == address(0)) revert CompoundCometNotConfigured();
        address base = comet.baseToken();
        if (base == address(0)) revert CompoundBaseNotConfigured();
        if (base != IERC4626(address(this)).asset()) revert CompoundAssetMismatch();
        _cs().comet = comet;
        emit CompoundConfigSet(comet, base);
    }

    // -----------------------------------------------------------------------
    // IStrategy surface (prefixed)
    // -----------------------------------------------------------------------

    /// @notice Current asset value held by the strategy. Comet's `balanceOf`
    ///         rebases upward as supply interest accrues, so it is the exact
    ///         present value of the position in underlying units.
    /// @dev Returns 0 (rather than reverting) when unconfigured, matching the Aave
    ///      facet, so an unconfigured-but-registered strategy reads as empty
    ///      instead of bricking the allocator's NAV sweep.
    function compoundTotalAssets() external view returns (uint256) {
        IComet comet = _cs().comet;
        if (address(comet) == address(0)) return 0;
        return comet.balanceOf(address(this));
    }

    /// @notice Pulls `amount` of the underlying from idle and supplies it to Comet.
    /// @dev Called via diamond fallback by the AllocatorFacet during rebalance.
    ///      Verifies the rebasing balance increased by at least `amount` (minus
    ///      `SUPPLY_ROUNDING_SLACK`) so a fee-on-supply or broken market is caught.
    function compoundDeposit(uint256 amount) external {
        LibDiamond.enforceIsSelf();
        CompoundStorage storage s = _cs();
        if (address(s.comet) == address(0)) revert CompoundCometNotConfigured();
        IERC20 underlying = IERC20(IERC4626(address(this)).asset());
        uint256 balBefore = s.comet.balanceOf(address(this));
        underlying.forceApprove(address(s.comet), amount);
        s.comet.supply(address(underlying), amount);
        uint256 received = s.comet.balanceOf(address(this)) - balBefore;
        if (received + SUPPLY_ROUNDING_SLACK < amount) revert CompoundDepositFailed(amount, received);
    }

    /// @notice Withdraws `amount` of the underlying from Comet back to idle.
    /// @dev Clamps the request to the current position so a withdraw can never
    ///      overshoot the supply balance and flip into a borrow. Measures the
    ///      underlying actually received (Comet's `withdraw` returns nothing) and
    ///      reverts if it falls short of the clamped request.
    function compoundWithdraw(uint256 amount) external {
        LibDiamond.enforceIsSelf();
        CompoundStorage storage s = _cs();
        if (address(s.comet) == address(0)) revert CompoundCometNotConfigured();
        IERC20 underlying = IERC20(IERC4626(address(this)).asset());

        uint256 bal = s.comet.balanceOf(address(this));
        uint256 toWithdraw = amount > bal ? bal : amount;
        if (toWithdraw == 0) return;

        uint256 idleBefore = underlying.balanceOf(address(this));
        s.comet.withdraw(address(underlying), toWithdraw);
        uint256 received = underlying.balanceOf(address(this)) - idleBefore;
        if (received + SUPPLY_ROUNDING_SLACK < toWithdraw) revert CompoundWithdrawFailed(toWithdraw, received);
    }

    /// @notice No-op for Comet — base supply interest auto-accrues into the
    ///         rebasing `balanceOf`, so there is nothing to claim. (COMP incentive
    ///         rewards, where present, accrue separately via CometRewards and are
    ///         out of scope for this facet: they are a non-underlying token that
    ///         would need its own claim + sell + accounting path.)
    function compoundHarvest() external pure { }

    // -----------------------------------------------------------------------
    // Readers
    // -----------------------------------------------------------------------

    /// @notice The currently configured Comet market (address(0) if unset).
    function compoundComet() external view returns (IComet) {
        return _cs().comet;
    }
}
