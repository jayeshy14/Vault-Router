// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IPYLpOracle
/// @notice Minimal interface for Pendle's PendlePYLpOracle (a.k.a. PtYtLpOracle),
///         the canonical on-chain mark-to-market oracle for PT / YT / LP.
/// @dev Reference:
/// https://github.com/pendle-finance/pendle-core-v2-public/blob/main/contracts/oracles/PtYtLpOracle/PendlePYLpOracle.sol
interface IPYLpOracle {
    /// @notice TWAP rate of PT denominated in the SY's underlying asset, scaled
    ///         to 1e18. Multiply a PT balance by this and divide by 1e18 to get
    ///         the asset value. Pre-maturity this sits below 1e18 (PT trades at a
    ///         discount); it converges to 1e18 at expiry.
    /// @param market   Pendle market (PT/SY pool) address.
    /// @param duration TWAP window in seconds.
    function getPtToAssetRate(address market, uint32 duration) external view returns (uint256);

    /// @notice Reports whether the market's built-in oracle is ready to serve a
    ///         TWAP over `duration`. Callers must ensure the oracle is seeded
    ///         (cardinality increased, oldest observation old enough) before
    ///         relying on getPtToAssetRate, otherwise the rate read can revert.
    /// @return increaseCardinalityRequired True if the market needs more slots.
    /// @return cardinalityRequired         The cardinality needed for `duration`.
    /// @return oldestObservationSatisfied  True if the window is fully covered.
    function getOracleState(
        address market,
        uint32 duration
    )
        external
        view
        returns (bool increaseCardinalityRequired, uint16 cardinalityRequired, bool oldestObservationSatisfied);
}
