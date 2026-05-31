// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

interface IStakedUSDEV2 {
    function asset() external view returns (address); // == USDe
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function convertToAssets(uint256 shares) external view returns (uint256 assets);
    function balanceOf(address account) external view returns (uint256);

    // ERC-4626 instant exit — valid ONLY when cooldownDuration == 0
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
    function maxRedeem(address owner) external view returns (uint256);

    // Cooldown exit — valid ONLY when cooldownDuration > 0
    function cooldownDuration() external view returns (uint24);
    function cooldownShares(uint256 shares) external returns (uint256 assets);
    function cooldownAssets(uint256 assets) external returns (uint256 shares);
    function unstake(address receiver) external;
    function cooldowns(address account) external view returns (uint104 cooldownEnd, uint152 underlyingAmount);
}
