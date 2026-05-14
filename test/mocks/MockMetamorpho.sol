// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC4626 } from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

import { IMintable } from "./MockProtocol.sol";

/// @title MockMetamorpho
/// @notice Test-only stand-in for a Metamorpho ERC4626 vault. Behaves like a
///         vanilla OpenZeppelin ERC4626 vault, plus two test hooks the real
///         thing doesn't need:
///         - `setShortchangeBps` makes `deposit` mint fewer shares than
///           `previewDeposit` quotes, to exercise the strategy facet's
///           `MorphoSlippage` guard.
///         - `_testAccrueYield` donates underlying into the vault, lifting the
///           share price to simulate supply-yield accrual without modelling a
///           real interest curve.
contract MockMetamorpho is ERC4626 {
    /// @notice When non-zero, `deposit` mints `(10_000 - bps) / 10_000` of the
    ///         shares `previewDeposit` returns. `previewDeposit` itself is left
    ///         honest, so the caller's slippage check has something to catch on.
    uint256 public shortchangeBps;

    constructor(IERC20 asset_) ERC20("Mock Metamorpho USDC", "mmUSDC") ERC4626(asset_) { }

    /// @notice Test-only — set the share shortfall applied by `deposit`.
    function setShortchangeBps(uint256 bps) external {
        shortchangeBps = bps;
    }

    /// @notice Test-only — donate `amount` of underlying to the vault so the
    ///         share price rises, simulating accrued supply yield.
    function _testAccrueYield(uint256 amount) external {
        IMintable(asset()).mint(address(this), amount);
    }

    /// @dev Mirrors OZ's `deposit` but optionally mints fewer shares than quoted.
    function deposit(uint256 assets, address receiver) public override returns (uint256) {
        uint256 shares = previewDeposit(assets);
        if (shortchangeBps != 0) {
            shares = (shares * (10_000 - shortchangeBps)) / 10_000;
        }
        _deposit(_msgSender(), receiver, assets, shares);
        return shares;
    }
}
