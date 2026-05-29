// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import { LibDiamond } from "../libraries/LibDiamond.sol";
import { LibGuard } from "../libraries/LibGuard.sol";

/// @title GuardFacet
/// @notice Owner controls for the NAV circuit breaker plus a permissionless
///         `guardCheckpoint` poke. The hot-path tripwire that protects every
///         deposit/withdraw lives in Vault.sol; this facet configures the bound,
///         exposes the latch, and lets a keeper or the curator agent enforce the
///         breaker continuously between user actions.
contract GuardFacet {
    error InvalidBps(uint16 bps);

    event MaxSharePriceDeltaSet(uint16 bps);
    event Paused(address indexed by);
    event Unpaused(address indexed by, uint256 baseline);
    event Checkpoint(uint256 sharePrice);
    event BreakerTripped(uint256 lastSharePrice, uint256 currentSharePrice);

    // -----------------------------------------------------------------------
    // Owner-gated configuration
    // -----------------------------------------------------------------------

    /// @notice Set the max allowed share-price move between checkpoints, in bps.
    /// @dev 0 disables the deviation check (pause latch still works manually).
    function setMaxSharePriceDelta(uint16 bps) external {
        LibDiamond.enforceIsContractOwner();
        if (bps > LibGuard.BPS_DENOMINATOR) revert InvalidBps(bps);
        LibGuard.guardStorage().maxSharePriceDeltaBps = bps;
        emit MaxSharePriceDeltaSet(bps);
    }

    /// @notice Manually latch the breaker, halting deposits and withdrawals.
    function pause() external {
        LibDiamond.enforceIsContractOwner();
        LibGuard.guardStorage().paused = true;
        emit Paused(msg.sender);
    }

    /// @notice Clear the latch and re-baseline the checkpoint to the current
    ///         share price, so a normalised (or owner-accepted) NAV resumes
    ///         cleanly without immediately re-tripping the hot-path tripwire.
    function unpause() external {
        LibDiamond.enforceIsContractOwner();
        LibGuard.GuardStorage storage g = LibGuard.guardStorage();
        g.paused = false;
        uint256 baseline = _currentSharePrice();
        g.lastSharePrice = baseline;
        emit Unpaused(msg.sender, baseline);
    }

    // -----------------------------------------------------------------------
    // Permissionless enforcement
    // -----------------------------------------------------------------------

    /// @notice Sample the current share price; if it deviates beyond the bound,
    ///         latch the vault into a paused state, otherwise advance the
    ///         checkpoint. Callable by anyone (keeper, curator agent, monitor).
    /// @dev This call *commits* its state change, so the latch persists — unlike
    ///      the hot-path tripwire which can only revert the offending op.
    function guardCheckpoint() external {
        LibGuard.GuardStorage storage g = LibGuard.guardStorage();
        if (g.paused) return;

        uint256 supply = IERC20(address(this)).totalSupply();
        if (supply == 0) return;

        uint256 price = LibGuard.sharePrice(IERC4626(address(this)).totalAssets(), supply);
        uint256 last = g.lastSharePrice;
        if (last == 0) {
            g.lastSharePrice = price;
            emit Checkpoint(price);
            return;
        }
        if (LibGuard.deviationExceeded(last, price, g.maxSharePriceDeltaBps)) {
            g.paused = true;
            emit BreakerTripped(last, price);
            return;
        }
        g.lastSharePrice = price;
        emit Checkpoint(price);
    }

    // -----------------------------------------------------------------------
    // Readers
    // -----------------------------------------------------------------------

    function paused() external view returns (bool) {
        return LibGuard.guardStorage().paused;
    }

    function maxSharePriceDeltaBps() external view returns (uint16) {
        return LibGuard.guardStorage().maxSharePriceDeltaBps;
    }

    function lastSharePrice() external view returns (uint256) {
        return LibGuard.guardStorage().lastSharePrice;
    }

    // -----------------------------------------------------------------------
    // Internals
    // -----------------------------------------------------------------------

    function _currentSharePrice() internal view returns (uint256) {
        uint256 supply = IERC20(address(this)).totalSupply();
        if (supply == 0) return 0;
        return LibGuard.sharePrice(IERC4626(address(this)).totalAssets(), supply);
    }
}
