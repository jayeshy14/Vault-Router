// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import { LibDiamond } from "../../libraries/LibDiamond.sol";
import { IAavePool } from "../../interfaces/external/IAavePool.sol";

/// @title AaveStrategyFacet
/// @notice Strategy facet that supplies the vault's asset to Aave V3 and
///         reports its position via the corresponding aToken.
/// @dev Selectors are prefixed with `aave*` so the facet coexists with other
///      strategy facets in the same Diamond without selector collisions.
///      State lives at EIP-7201 slot `vaultrouter.strategy.aave`.
contract AaveStrategyFacet {
    using SafeERC20 for IERC20;

    error AavePoolNotConfigured();
    error AaveATokenNotConfigured();

    event AaveConfigSet(IAavePool indexed pool, IERC20 indexed aToken);

    /// @dev erc7201:vaultrouter.strategy.aave
    bytes32 internal constant AAVE_STORAGE_SLOT = 0x340080245a7d3e67835fb5055646777827d09fc7212fda4d8d724367e1215700;

    struct AaveStorage {
        IAavePool pool;
        IERC20 aToken;
    }

    function _as() internal pure returns (AaveStorage storage s) {
        bytes32 slot = AAVE_STORAGE_SLOT;
        assembly {
            s.slot := slot
        }
    }

    // -----------------------------------------------------------------------
    // Curator-gated setup
    // -----------------------------------------------------------------------

    /// @notice Set the Aave V3 pool and the aToken that corresponds to the
    ///         vault's underlying asset. Must be called once before the strategy
    ///         is registered with the allocator.
    function aaveSetConfig(IAavePool pool, IERC20 aToken) external {
        LibDiamond.enforceIsContractOwner();
        if (address(pool) == address(0)) revert AavePoolNotConfigured();
        if (address(aToken) == address(0)) revert AaveATokenNotConfigured();
        AaveStorage storage s = _as();
        s.pool = pool;
        s.aToken = aToken;
        emit AaveConfigSet(pool, aToken);
    }

    // -----------------------------------------------------------------------
    // IStrategy surface (prefixed)
    // -----------------------------------------------------------------------

    /// @notice Current asset value held by the strategy. aTokens rebase upward
    ///         as borrow interest accrues, so `balanceOf` of the vault is the
    ///         exact current position in underlying units.
    function aaveTotalAssets() external view returns (uint256) {
        IERC20 aToken = _as().aToken;
        if (address(aToken) == address(0)) return 0;
        return aToken.balanceOf(address(this));
    }

    /// @notice Pulls `amount` of the underlying from idle and supplies it to Aave V3.
    /// @dev Called via diamond fallback by the AllocatorFacet during rebalance.
    function aaveDeposit(uint256 amount) external {
        AaveStorage storage s = _as();
        if (address(s.pool) == address(0)) revert AavePoolNotConfigured();
        IERC20 underlying = IERC20(IERC4626(address(this)).asset());
        underlying.forceApprove(address(s.pool), amount);
        s.pool.supply(address(underlying), amount, address(this), 0);
    }

    /// @notice Withdraws `amount` of the underlying from Aave V3 back to idle.
    function aaveWithdraw(uint256 amount) external {
        AaveStorage storage s = _as();
        if (address(s.pool) == address(0)) revert AavePoolNotConfigured();
        IERC20 underlying = IERC20(IERC4626(address(this)).asset());
        s.pool.withdraw(address(underlying), amount, address(this));
    }

    /// @notice No-op for Aave V3 — supply yield auto-accrues into the aToken's
    ///         rebasing balance, so there's nothing to claim.
    function aaveHarvest() external pure { }

    // -----------------------------------------------------------------------
    // Readers
    // -----------------------------------------------------------------------

    function aavePool() external view returns (IAavePool) {
        return _as().pool;
    }

    function aaveAToken() external view returns (IERC20) {
        return _as().aToken;
    }
}
