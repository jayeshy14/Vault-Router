// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC4626 } from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IDiamond } from "./interfaces/IDiamond.sol";
import { Diamond } from "./Diamond.sol";
import { LibAllocator } from "./libraries/LibAllocator.sol";
import { LibFees } from "./libraries/LibFees.sol";
import { LibGuard } from "./libraries/LibGuard.sol";

/// @title Vault Router is a modular ERC-4626 vault on the EIP-2535 Diamond pattern.
/// @notice Vault owns the ERC-4626 surface (deposit/withdraw/totalAssets) plus the
///         fee and circuit-breaker hooks. The diamond proxy mechanics live in the
///         inherited Diamond base; strategy logic, allocation policy, and
///         harvesting live in facets attached via diamondCut.
/// @dev Inflation attack mitigation comes from OZ ERC-4626's `_decimalsOffset`
///      virtual shares. The ERC-4626 surface is native (non-facet) and therefore
///      non-upgradeable, so it cannot be altered by a later diamondCut.
contract Vault is Diamond, ERC4626 {
    error StrategyTotalAssetsCallFailed(bytes32 strategyId);

    constructor(
        IERC20 asset_,
        string memory name_,
        string memory symbol_,
        address initialOwner,
        IDiamond.FacetCut[] memory diamondCut_,
        address init_,
        bytes memory initCalldata_
    )
        Diamond(initialOwner, diamondCut_, init_, initCalldata_)
        ERC20(name_, symbol_)
        ERC4626(asset_)
    { }

    /// @dev 6 decimals of virtual shares, OZ's recommended inflation-attack
    ///      mitigation for ERC-4626 vaults. Sourced from LibGuard so the breaker's
    ///      share-price math and this offset can never drift apart.
    function _decimalsOffset() internal pure override returns (uint8) {
        return LibGuard.DECIMALS_OFFSET;
    }

    /// @notice Total assets under management = idle vault balance + sum of every
    ///         registered strategy's reported position.
    /// @dev Self-staticcalls each strategy's totalAssets selector via the diamond
    ///      fallback. When no strategies are registered the result equals the
    ///      vault's idle USDC balance (default ERC-4626 behavior).
    function totalAssets() public view override returns (uint256) {
        uint256 total = IERC20(asset()).balanceOf(address(this));
        LibAllocator.AllocatorStorage storage $ = LibAllocator.allocatorStorage();
        uint256 length = $.strategyIds.length;
        for (uint256 i; i < length; i++) {
            bytes32 id = $.strategyIds[i];
            LibAllocator.StrategyConfig storage configs = $.configs[id];
            if (!configs.active) continue;
            (bool ok, bytes memory data) = address(this).staticcall(abi.encodeWithSelector(configs.totalAssetsSelector));
            if (!ok) revert StrategyTotalAssetsCallFailed(id);
            total += abi.decode(data, (uint256));
        }
        return total;
    }

    // -----------------------------------------------------------------------
    // Fee-accrual hooks
    // -----------------------------------------------------------------------

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        // Circuit breaker: revert if paused, or if the current share price has
        // moved beyond the configured bound since the last checkpoint.
        _guard();
        // Pre-accrue so the new depositor doesn't dilute the perf-fee owed on
        // yield earned by existing holders. No-op on the very first deposit
        // (supply == 0 → early return).
        _accrueFees();
        super._deposit(caller, receiver, assets, shares);
        // Post-accrue handles the first-deposit bootstrap: now that supply > 0,
        // initialise HWM and the accrual timestamp. No-op for subsequent deposits.
        _accrueFees();
    }

    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares
    )
        internal
        override
    {
        _guard();
        _accrueFees();
        super._withdraw(caller, receiver, owner, assets, shares);
        _accrueFees();
    }

    /// @dev NAV circuit-breaker tripwire run on every deposit/withdraw. Reverts
    ///      when the breaker is latched (`EnforcedPause`) or when the live share
    ///      price deviates beyond the owner-set bound (`SharePriceDeviation`),
    ///      otherwise advances the checkpoint. Runs independently of fee accrual
    ///      so it is enforced even when no fee recipient is configured.
    function _guard() internal {
        LibGuard.GuardStorage storage g = LibGuard.guardStorage();
        if (g.paused) revert LibGuard.EnforcedPause();
        uint256 supply = totalSupply();
        if (supply == 0) return; // nothing to price yet; breaker arms on the next op
        LibGuard.checkpoint(g, LibGuard.sharePrice(totalAssets(), supply));
    }

    /// @dev Mints performance + management fee shares to the configured recipient.
    ///      Performance fee is taken on any increase in share price above the HWM
    ///      since the last accrual. Management fee accrues linearly over elapsed
    ///      time. Both use linear approximations valid for small fees; an exact
    ///      "no-self-dilution" form would mint slightly fewer shares.
    function _accrueFees() internal {
        LibFees.FeeStorage storage f = LibFees.feeStorage();
        if (f.feeRecipient == address(0)) return;

        uint256 supply = totalSupply();
        uint64 nowTs = uint64(block.timestamp);

        if (supply == 0) {
            f.lastFeeAccrual = nowTs;
            f.highWaterMark = 0;
            return;
        }

        uint256 ta = totalAssets();
        uint256 sharePrice = LibGuard.sharePrice(ta, supply);

        if (f.highWaterMark == 0) f.highWaterMark = sharePrice;
        if (f.lastFeeAccrual == 0) f.lastFeeAccrual = nowTs;

        uint256 feeShares;

        // Management fee — linear over elapsed seconds.
        if (f.managementFeeBps > 0 && nowTs > f.lastFeeAccrual) {
            uint256 elapsed = nowTs - f.lastFeeAccrual;
            feeShares += (supply * uint256(f.managementFeeBps) * elapsed)
                / (uint256(LibFees.BPS_DENOMINATOR) * LibFees.SECONDS_PER_YEAR);
        }

        // Performance fee — proportional to share-price gain above HWM.
        if (f.performanceFeeBps > 0 && sharePrice > f.highWaterMark) {
            uint256 profitPerShare = sharePrice - f.highWaterMark;
            uint256 profitValue = (profitPerShare * supply) / 1e18;
            uint256 feeValue = (profitValue * uint256(f.performanceFeeBps)) / LibFees.BPS_DENOMINATOR;
            if (ta > 0) feeShares += (feeValue * supply) / ta;
            f.highWaterMark = sharePrice;
        }

        f.lastFeeAccrual = nowTs;
        if (feeShares > 0) _mint(f.feeRecipient, feeShares);
    }
}
