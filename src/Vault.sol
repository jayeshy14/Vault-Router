// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC4626 } from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { IDiamond } from "./interfaces/IDiamond.sol";
import { Diamond } from "./Diamond.sol";
import { LibAllocator } from "./libraries/LibAllocator.sol";
import { LibFees } from "./libraries/LibFees.sol";
import { LibGuard } from "./libraries/LibGuard.sol";
import { LibLock } from "./libraries/LibLock.sol";
import { LibRoles } from "./libraries/LibRoles.sol";
import { LibWithdrawQueue } from "./libraries/LibWithdrawQueue.sol";

/// @title Vault Router is a modular ERC-4626 vault on the EIP-2535 Diamond pattern.
/// @notice Vault owns the ERC-4626 surface (deposit/withdraw/totalAssets) plus the
///         fee and circuit-breaker hooks. The diamond proxy mechanics live in the
///         inherited Diamond base; strategy logic, allocation policy, and
///         harvesting live in facets attached via diamondCut.
/// @dev Inflation attack mitigation comes from OZ ERC-4626's `_decimalsOffset`
///      virtual shares. The ERC-4626 surface is native (non-facet) and therefore
///      non-upgradeable, so it cannot be altered by a later diamondCut.
contract Vault is Diamond, ERC4626, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error StrategyTotalAssetsCallFailed(bytes32 strategyId);

    error WithdrawQueueZeroShares();
    error WithdrawToZeroAddress();
    error WithdrawRequestNotFound(uint256 id);
    error NotRequestOwner(uint256 id, address caller);
    error InsufficientIdleLiquidity(uint256 needed, uint256 available);

    event WithdrawRequested(uint256 indexed id, address indexed owner, address indexed receiver, uint256 shares);
    event WithdrawCancelled(uint256 indexed id, address indexed owner, uint256 shares);
    event WithdrawFulfilled(uint256 indexed id, address indexed receiver, uint256 shares, uint256 assets);

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
            // Isolated strategy: excluded from NAV so a single failing protocol
            // cannot brick deposits, withdrawals, or fee accrual vault-wide.
            if ($.quarantined[id]) continue;
            (bool ok, bytes memory data) = address(this).staticcall(abi.encodeWithSelector(configs.totalAssetsSelector));
            if (!ok) revert StrategyTotalAssetsCallFailed(id);
            total += abi.decode(data, (uint256));
        }
        return total;
    }

    // -----------------------------------------------------------------------
    // Fee-accrual hooks
    // -----------------------------------------------------------------------

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override nonReentrant {
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
        // Lock the receiver's shares for the configured window so an attacker
        // cannot deposit, manipulate, and withdraw within the same block. Skipped
        // when the period is 0 (disabled). Re-deposits refresh the window.
        //
        // Armed ONLY when the depositor is locking their own shares
        // (caller == receiver). A third party must never be able to set the lock
        // on an arbitrary receiver: doing so would let an attacker freeze a
        // victim's entire balance, or — with receiver == address(this) — lock the
        // vault's own escrowed withdraw-queue shares and brick cancel/fulfill.
        LibLock.LockStorage storage l = LibLock.lockStorage();
        if (l.shareLockPeriod > 0 && caller == receiver) {
            l.lockedUntil[receiver] = block.timestamp + uint256(l.shareLockPeriod);
        }
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
        nonReentrant
    {
        _guard();
        _accrueFees();
        super._withdraw(caller, receiver, owner, assets, shares);
        _accrueFees();
    }

    /// @dev Single enforcement point for the share lock. Runs on every ERC20
    ///      mutation: mints (`from == 0`) are exempt — that is how the lock is
    ///      armed in `_deposit` — while transfers AND burns of still-locked
    ///      shares revert. Catching burns here covers withdraw/redeem, and
    ///      catching transfers stops the transfer-then-withdraw bypass, so no
    ///      separate check is needed in `_withdraw`.
    function _update(address from, address to, uint256 value) internal override {
        // Mints (from == 0) are exempt — that is how the lock is armed. The
        // vault's own address is also exempt: shares it custodies are protocol
        // escrow (the withdraw queue), not user funds subject to the anti-MEV
        // lock, and blocking their movement would brick cancel/fulfill.
        if (from != address(0) && from != address(this)) {
            uint256 unlockAt = LibLock.lockStorage().lockedUntil[from];
            if (block.timestamp < unlockAt) revert LibLock.SharesLocked(from, unlockAt);
        }
        super._update(from, to, value);
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
            // Full-precision mulDiv throughout: each step multiplies at 512-bit
            // width before dividing, so no intermediate truncation feeds the next
            // multiplication (fixes the divide-before-multiply rounding).
            uint256 profitPerShare = sharePrice - f.highWaterMark;
            uint256 profitValue = Math.mulDiv(profitPerShare, supply, 1e18);
            uint256 feeValue = Math.mulDiv(profitValue, uint256(f.performanceFeeBps), LibFees.BPS_DENOMINATOR);
            if (ta > 0) feeShares += Math.mulDiv(feeValue, supply, ta);
            f.highWaterMark = sharePrice;
        }

        f.lastFeeAccrual = nowTs;
        if (feeShares > 0) _mint(f.feeRecipient, feeShares);
    }

    // -----------------------------------------------------------------------
    // Async withdrawal queue
    // -----------------------------------------------------------------------
    // Synchronous `withdraw`/`redeem` pay from idle balance and revert when the
    // vault is short — which happens when capital sits in an illiquid strategy
    // (notably Pendle PT before maturity). The queue gives those exits a path:
    // the requester escrows shares, a curator frees liquidity via `rebalance`,
    // then fulfils the claim at the live share price. These live on the native
    // surface because only it can `_transfer`/`_burn` shares; the readers are on
    // `WithdrawQueueFacet`.

    /// @notice Escrow `shares` for a later asynchronous exit to `receiver`.
    /// @dev The shares are transferred to the vault (not burned), so the request
    ///      stays NAV-neutral and the requester keeps full exposure until
    ///      fulfillment — the claim is priced at fulfil time, not now. Subject to
    ///      the share lock: locked shares cannot be queued.
    /// @param shares   Amount of vault shares to escrow.
    /// @param receiver Address that will receive the underlying on fulfillment.
    /// @return id      The request id, used to fulfil or cancel.
    function requestWithdraw(uint256 shares, address receiver) external nonReentrant returns (uint256 id) {
        if (shares == 0) revert WithdrawQueueZeroShares();
        if (receiver == address(0)) revert WithdrawToZeroAddress();

        // Escrow the shares (reverts on insufficient balance or active lock).
        _transfer(msg.sender, address(this), shares);

        LibWithdrawQueue.QueueStorage storage q = LibWithdrawQueue.queueStorage();
        id = q.nextRequestId++;
        q.requests[id] = LibWithdrawQueue.WithdrawRequest({ owner: msg.sender, receiver: receiver, shares: shares });
        q.totalPendingShares += shares;

        emit WithdrawRequested(id, msg.sender, receiver, shares);
    }

    /// @notice Cancel a pending request and return the escrowed shares to their owner.
    /// @dev Only the request's owner may cancel, and only while it is unfulfilled.
    /// @param id The request id returned by `requestWithdraw`.
    function cancelWithdraw(uint256 id) external nonReentrant {
        LibWithdrawQueue.QueueStorage storage q = LibWithdrawQueue.queueStorage();
        LibWithdrawQueue.WithdrawRequest memory req = q.requests[id];
        if (req.shares == 0) revert WithdrawRequestNotFound(id);
        if (req.owner != msg.sender) revert NotRequestOwner(id, msg.sender);

        q.totalPendingShares -= req.shares;
        delete q.requests[id];

        _transfer(address(this), req.owner, req.shares);

        emit WithdrawCancelled(id, req.owner, req.shares);
    }

    /// @notice Fulfil a pending request: burn the escrowed shares and pay the
    ///         underlying to the recorded receiver.
    /// @dev Curator-gated (the keeper seat). Honors the circuit breaker and
    ///      accrues fees first, so the payout reflects the live, post-fee share
    ///      price. Reverts if idle liquidity is insufficient — the curator must
    ///      `rebalance` enough out of strategies first. Effects precede the
    ///      transfer (CEI) and the function is `nonReentrant`.
    /// @param id The request id to fulfil.
    function fulfillWithdraw(uint256 id) external nonReentrant {
        LibRoles.enforceIsCurator();

        LibWithdrawQueue.QueueStorage storage q = LibWithdrawQueue.queueStorage();
        LibWithdrawQueue.WithdrawRequest memory req = q.requests[id];
        if (req.shares == 0) revert WithdrawRequestNotFound(id);

        _guard();
        _accrueFees();

        uint256 assets = convertToAssets(req.shares);
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        if (idle < assets) revert InsufficientIdleLiquidity(assets, idle);

        q.totalPendingShares -= req.shares;
        delete q.requests[id];

        _burn(address(this), req.shares);
        IERC20(asset()).safeTransfer(req.receiver, assets);

        emit WithdrawFulfilled(id, req.receiver, req.shares, assets);
    }
}
