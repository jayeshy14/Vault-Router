// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {LibDiamond} from "../../libraries/LibDiamond.sol";
import {IMorpho} from "../../interfaces/external/IMorpho.sol";

contract MorphoStrategyFacet {
    using SafeERC20 for IERC20;

    //errors

    error MorphoVaultNotConfigured();
    error MorphoAssetNotConfigured();
    error MorphoAssetMismatch();
    error MorphoSlippage(uint256 expected, uint256 received);

    //events

    event MorphoVaultSet(IMorpho indexed vault);

    
    bytes32 internal constant MORPHO_STORAGE_SLOT = "";

    struct MorphoStorage{
        IMorpho vault;
    }

    function _ms() internal pure returns (MorphoStorage storage s) {
        bytes32 slot = MORPHO_STORAGE_SLOT;
        assembly {
            s.slot := slot
        }
    }


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

    function morphoTotalAssets() external view returns (uint256){
        MorphoStorage storage s = _ms();
        if (address(s.vault) == address(0)) revert MorphoVaultNotConfigured();
        return s.vault.convertToAssets(s.vault.balanceOf(address(this)));

    }

    function morphoDeposit (uint256 amount) external {
        MorphoStorage storage s = _ms();
        if (address(s.vault) == address(0)) revert MorphoVaultNotConfigured();
        IERC20 underlying = IERC20(IERC4626(address(this)).asset());
        underlying.forceApprove(address(s.vault), amount);
        uint256 expected = s.vault.previewDeposit(amount);
        uint256 shares = s.vault.deposit(amount, address(this));
        if (shares < expected) revert MorphoSlippage(expected, shares);
    }

    function morphoWithdraw (uint256 assets) external{
        MorphoStorage storage s = _ms();
        if (address(s.vault) == address(0)) revert MorphoVaultNotConfigured();
        s.vault.withdraw(assets,address(this), address(this));
    }

    //view 

    function morphoVault() external view returns (IMorpho) {
        MorphoStorage storage s = _ms();
        if (address(s.vault) == address(0)) revert MorphoVaultNotConfigured();
        return s.vault;
    }


}