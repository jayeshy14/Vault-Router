// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import { LibDiamond } from "../../libraries/LibDiamond.sol";
import { IMorpho } from "../../interfaces/external/IMorpho.sol";

/// @title MorphoStrategyFacet
/// @notice Strategy facet that supplies the diamond's underlying asset to a
///         Metamorpho ERC4626 vault and reports its position via the vault's
///         share balance.
/// @dev Selectors are prefixed with `morpho*` so the facet coexists with other
///      strategy facets in the same Diamond without selector collisions.
///      State lives at EIP-7201 slot `vaultrouter.strategy.morpho`.
contract MorphoStrategyFacet {
    using SafeERC20 for IERC20;

    //errors

    /// @notice Thrown when the Metamorpho vault has not yet been configured.
    error MorphoVaultNotConfigured();
    /// @notice Thrown when the configured vault returns a zero underlying asset.
    error MorphoAssetNotConfigured();
    /// @notice Thrown when the vault's underlying asset differs from the diamond's asset.
    error MorphoAssetMismatch();
    /// @notice Thrown when shares minted by `deposit` are below the slippage bound.
    /// @param expected Shares predicted by `previewDeposit`.
    /// @param received Shares actually minted by the vault.
    error MorphoSlippage(uint256 expected, uint256 received);

    //events

    /// @notice Emitted when the Metamorpho vault is configured (or reconfigured).
    /// @param vault The Metamorpho ERC4626 vault now active for this strategy.
    event MorphoVaultSet(IMorpho indexed vault);

    /// @dev Precomputed erc7201("vaultrouter.strategy.morpho"):
    ///      keccak256(abi.encode(uint256(keccak256(id)) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant MORPHO_STORAGE_SLOT = 0xf4b3fd2d8603f5a74e31f8c3250c4c70408eaa33a47a7d4535036bfa6799e900;

    /// @notice Storage layout for the Morpho strategy facet.
    /// @dev `vault` is the configured Metamorpho ERC4626 vault.
    /// @custom:storage-location erc7201:vaultrouter.strategy.morpho
    struct MorphoStorage {
        IMorpho vault;
    }

    /// @dev Returns the EIP-7201 namespaced storage struct for this facet.
    function _ms() internal pure returns (MorphoStorage storage s) {
        bytes32 slot = MORPHO_STORAGE_SLOT;
        assembly {
            s.slot := slot
        }
    }

    /// @notice Configure the Metamorpho vault this strategy routes capital to.
    /// @dev Owner-gated. Validates that the vault's underlying asset matches
    ///      the diamond's ERC4626 underlying asset before persisting.
    /// @param vault The Metamorpho ERC4626 vault to associate with this strategy.
    function MorphoSetVaultConfig(IMorpho vault) external {
        //gates
        LibDiamond.enforceIsContractOwner();
        if (address(vault) == address(0)) revert MorphoVaultNotConfigured();
        //imp check for underlying asset
        if (address(vault.asset()) == address(0)) revert MorphoAssetNotConfigured();
        //impt check for underlying asset is the same as the vault's asset
        if (address(vault.asset()) != address(IERC4626(address(this)).asset())) revert MorphoAssetMismatch();

        MorphoStorage storage s = _ms();
        s.vault = vault;
        emit MorphoVaultSet(vault);
    }

    //@notice there are three priciple functionalities that strategy user
    //can access: "checkTotalAssets", "morphoDeposit", "morphoWithdraw"
    //"morphoHarvest"

    /// @notice Report the underlying-asset value of the diamond's Morpho position.
    /// @dev Returns `vault.convertToAssets(vault.balanceOf(diamond))`. This is the
    ///      share-price NAV; it ignores withdrawal caps and fees that would affect
    ///      realizable liquidity. For redemption-headroom checks use
    ///      `vault.maxWithdraw(diamond)` instead.
    /// @return The current value of the strategy's position denominated in the
    ///         underlying asset.
    function morphoTotalAssets() external view returns (uint256) {
        MorphoStorage storage s = _ms();
        if (address(s.vault) == address(0)) revert MorphoVaultNotConfigured();
        return s.vault.convertToAssets(s.vault.balanceOf(address(this)));
    }

    /// @notice Deposit `amount` of the diamond's underlying asset into Metamorpho.
    /// @dev Strategy-internal primitive. The diamond is always the share
    ///      receiver — there is no caller-chosen receiver. Reverts with
    ///      `MorphoSlippage` if the vault mints fewer shares than
    ///      `previewDeposit(amount)` predicted.
    /// @param amount Quantity of underlying asset to allocate to Morpho.
    function morphoDeposit(uint256 amount) external {
        LibDiamond.enforceIsSelf();
        MorphoStorage storage s = _ms();
        if (address(s.vault) == address(0)) revert MorphoVaultNotConfigured();
        IERC20 underlying = IERC20(IERC4626(address(this)).asset());
        underlying.forceApprove(address(s.vault), amount);
        uint256 expected = s.vault.previewDeposit(amount);
        uint256 shares = s.vault.deposit(amount, address(this));
        if (shares < expected) revert MorphoSlippage(expected, shares);
    }

    /// @notice Withdraw `amount` of underlying from Metamorpho back to the diamond.
    /// @dev Strategy-internal primitive. Underlying always returns to the diamond
    ///      itself — forwarding to a user-chosen receiver is the responsibility
    ///      of the user-facing redeem path that also burns shares.
    /// @param amount Quantity of underlying asset to pull out of Morpho.
    function morphoWithdraw(uint256 amount) external {
        LibDiamond.enforceIsSelf();
        MorphoStorage storage s = _ms();
        if (address(s.vault) == address(0)) revert MorphoVaultNotConfigured();
        // Bound the shares burned: burning more than previewWithdraw predicted
        // means a worse-than-quoted price. Mirrors the morphoDeposit slippage check.
        uint256 expected = s.vault.previewWithdraw(amount);
        uint256 shares = s.vault.withdraw(amount, address(this), address(this));
        if (shares > expected) revert MorphoSlippage(expected, shares);
    }

    /// @notice No-op for Metamorpho — supply yield auto-compounds into the
    ///         vault's share price, so there is nothing to claim.
    /// @dev Present so the facet exposes the full strategy surface
    ///      (`harvestSelector`) the allocator's `StrategyConfig` expects.
    function morphoHarvest() external pure { }

    //view

    /// @notice Return the currently configured Metamorpho vault.
    /// @return The Metamorpho ERC4626 vault this strategy routes capital to.
    function morphoVault() external view returns (IMorpho) {
        MorphoStorage storage s = _ms();
        if (address(s.vault) == address(0)) revert MorphoVaultNotConfigured();
        return s.vault;
    }
}
