// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IMintable {
    function mint(address to, uint256 amount) external;
}

/// @notice Test-only stand-in for an external yield protocol (Morpho/Aave style).
///         Holds the underlying asset on behalf of depositors and tracks per-account
///         balances. Includes a test-only `_testAccrueYield` to simulate yield growth.
contract MockProtocol {
    IERC20 public immutable asset;
    mapping(address => uint256) public balanceOf;

    constructor(IERC20 _asset) {
        asset = _asset;
    }

    function deposit(uint256 amount) external {
        asset.transferFrom(msg.sender, address(this), amount);
        balanceOf[msg.sender] += amount;
    }

    function withdraw(uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        asset.transfer(msg.sender, amount);
    }

    /// @notice Test-only — mints `amount` of the underlying to this contract and
    ///         credits `account`'s internal balance. Lets tests simulate yield
    ///         accrual without modelling a real interest curve.
    function _testAccrueYield(address account, uint256 amount) external {
        IMintable(address(asset)).mint(address(this), amount);
        balanceOf[account] += amount;
    }
}
