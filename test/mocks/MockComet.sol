// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IMintable } from "./MockProtocol.sol";

/// @title MockComet
/// @notice Test-only stand-in for a Compound III (Comet) base market. Models the
///         pieces the strategy facet touches: a 1:1 present-value `balanceOf`,
///         base-asset `supply`/`withdraw`, and `baseToken`. Adds test hooks the
///         real market doesn't need:
///         - `setSupplyShortfallBps` credits fewer base units than supplied, to
///           exercise the facet's `CompoundDepositFailed` guard (fee-on-supply).
///         - `setWithdrawShortfallBps` transfers fewer base units than requested,
///           to exercise `CompoundWithdrawFailed`.
///         - `setWithdrawReverts` makes `withdraw` revert, to exercise the
///           allocator's per-strategy rebalance-skip path on an illiquid market.
///         - `_testAccrueYield` lifts a supplier's balance to simulate accrued
///           supply interest without modelling a real rate curve.
contract MockComet {
    IERC20 internal immutable _base;
    mapping(address => uint256) internal _balances;

    uint256 public supplyShortfallBps;
    uint256 public withdrawShortfallBps;
    bool public withdrawReverts;

    // Canned rate-reader returns, so a curator-style on-chain read can be tested.
    uint256 internal _utilization;
    uint64 internal _supplyRate;

    error MockCometWrongAsset();
    error MockCometWithdrawPaused();

    constructor(IERC20 base_) {
        _base = base_;
    }

    // -----------------------------------------------------------------------
    // Comet surface
    // -----------------------------------------------------------------------

    function baseToken() external view returns (address) {
        return address(_base);
    }

    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    function supply(address asset, uint256 amount) external {
        if (asset != address(_base)) revert MockCometWrongAsset();
        _base.transferFrom(msg.sender, address(this), amount);
        uint256 credited = supplyShortfallBps == 0 ? amount : (amount * (10_000 - supplyShortfallBps)) / 10_000;
        _balances[msg.sender] += credited;
    }

    function withdraw(address asset, uint256 amount) external {
        if (asset != address(_base)) revert MockCometWrongAsset();
        if (withdrawReverts) revert MockCometWithdrawPaused();
        // Underflows (reverts) if the caller overdraws — the real market would
        // tip into a borrow; the facet's clamp keeps `amount <= balanceOf` so
        // this path is never hit in normal operation.
        _balances[msg.sender] -= amount;
        uint256 sent = withdrawShortfallBps == 0 ? amount : (amount * (10_000 - withdrawShortfallBps)) / 10_000;
        _base.transfer(msg.sender, sent);
    }

    function getUtilization() external view returns (uint256) {
        return _utilization;
    }

    function getSupplyRate(uint256) external view returns (uint64) {
        return _supplyRate;
    }

    // -----------------------------------------------------------------------
    // Test hooks
    // -----------------------------------------------------------------------

    function setSupplyShortfallBps(uint256 bps) external {
        supplyShortfallBps = bps;
    }

    function setWithdrawShortfallBps(uint256 bps) external {
        withdrawShortfallBps = bps;
    }

    function setWithdrawReverts(bool v) external {
        withdrawReverts = v;
    }

    function setRateReads(uint256 utilization_, uint64 supplyRate_) external {
        _utilization = utilization_;
        _supplyRate = supplyRate_;
    }

    /// @notice Test-only — mint `amount` of base into the market and credit
    ///         `account`'s supply balance, simulating accrued supply interest.
    function _testAccrueYield(address account, uint256 amount) external {
        IMintable(address(_base)).mint(address(this), amount);
        _balances[account] += amount;
    }
}
