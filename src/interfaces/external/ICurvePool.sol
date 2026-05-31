//SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

interface ICurvePool {
    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy, address receiver) external returns (uint256);
    function exchange_received(
        int128 i,
        int128 j,
        uint256 _dx,
        uint256 _min_dy,
        address _receiver
    )
        external
        returns (uint256);

    function get_dy(int128 i, int128 j, uint256 dx) external view returns (uint256);
    function get_dx(int128 i, int128 j, uint256 dy) external view returns (uint256);

    // metadata
    function coins(uint256 i) external view returns (address);
    function balances(uint256 i) external view returns (uint256);
    function A() external view returns (uint256);
    function fee() external view returns (uint256);
}
