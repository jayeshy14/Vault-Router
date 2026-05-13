// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IDiamond} from "./interfaces/IDiamond.sol";
import {LibDiamond} from "./libraries/LibDiamond.sol";
import {LibAllocator} from "./libraries/LibAllocator.sol";
import {LibFees} from "./libraries/LibFees.sol";

/// @title Vault Router — modular ERC-4626 vault on the EIP-2535 Diamond pattern.
/// @notice Vault.sol owns the ERC-4626 surface (deposit/withdraw/totalAssets) and
///         acts as the Diamond proxy. Strategy logic, allocation policy, and
///         harvesting live in facets attached via diamondCut.
/// @dev Inflation attack mitigation comes from OZ ERC-4626's `_decimalsOffset`
///      virtual shares, not the literal 1 wei dead deposit pattern.
contract Vault is ERC4626 {
    error UnknownSelector(bytes4 selector);
    error StrategyTotalAssetsCallFailed(bytes32 strategyId);

    constructor(
        IERC20 asset_,
        string memory name_,
        string memory symbol_,
        address initialOwner,
        IDiamond.FacetCut[] memory diamondCut_,
        address init_,
        bytes memory initCalldata_
    ) ERC20(name_, symbol_) ERC4626(asset_) {
        LibDiamond.setContractOwner(initialOwner);
        LibDiamond.diamondCut(diamondCut_, init_, initCalldata_);
    }

    /// @dev 6 decimals of virtual shares — OZ's recommended inflation-attack
    ///      mitigation for ERC-4626 vaults.
    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

    /// @notice Total assets under management = idle vault balance + sum of every
    ///         registered strategy's reported position.
    /// @dev Self-staticcalls each strategy's totalAssets selector via the diamond
    ///      fallback. When no strategies are registered the result equals the
    ///      vault's idle USDC balance (default ERC-4626 behaviour).
    function totalAssets() public view override returns (uint256) {
        uint256 total = IERC20(asset()).balanceOf(address(this));
        LibAllocator.AllocatorStorage storage s = LibAllocator.allocatorStorage();
        uint256 n = s.strategyIds.length;
        for (uint256 i; i < n; i++) {
            bytes32 id = s.strategyIds[i];
            LibAllocator.StrategyConfig storage cfg = s.configs[id];
            if (!cfg.active) continue;
            (bool ok, bytes memory data) =
                address(this).staticcall(abi.encodeWithSelector(cfg.totalAssetsSelector));
            if (!ok) revert StrategyTotalAssetsCallFailed(id);
            total += abi.decode(data, (uint256));
        }
        return total;
    }

    // -----------------------------------------------------------------------
    // Fee-accrual hooks
    // -----------------------------------------------------------------------

    function _deposit(
        address caller,
        address receiver,
        uint256 assets,
        uint256 shares
    ) internal override {
        // Pre-accrue so the new depositor doesn't dilute the perf-fee owed on
        // yield earned by existing holders. No-op on the very first deposit
        // (supply == 0 → early return).
        _accrueFees();
        super._deposit(caller, receiver, assets, shares);
        // Post-accrue handles the first-deposit bootstrap: now that supply > 0,
        // initialise HWM and the accrual timestamp. No-op for subsequent deposits.
        _accrueFees();
    }

    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares
    ) internal override {
        _accrueFees();
        super._withdraw(caller, receiver, owner, assets, shares);
        _accrueFees();
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
        uint256 effectiveSupply = supply + 10 ** _decimalsOffset();
        uint256 sharePrice = ((ta + 1) * 1e18) / effectiveSupply;

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
            uint256 profitPerShare = sharePrice - f.highWaterMark;
            uint256 profitValue = (profitPerShare * supply) / 1e18;
            uint256 feeValue = (profitValue * uint256(f.performanceFeeBps)) / LibFees.BPS_DENOMINATOR;
            if (ta > 0) feeShares += (feeValue * supply) / ta;
            f.highWaterMark = sharePrice;
        }

        f.lastFeeAccrual = nowTs;
        if (feeShares > 0) _mint(f.feeRecipient, feeShares);
    }

    fallback() external payable {
        LibDiamond.DiamondStorage storage ds;
        bytes32 position = LibDiamond.DIAMOND_STORAGE_POSITION;
        assembly {
            ds.slot := position
        }
        address facet = ds.selectorToFacetAndPosition[msg.sig].facetAddress;
        if (facet == address(0)) revert UnknownSelector(msg.sig);
        assembly {
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), facet, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch result
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }

    receive() external payable {}
}
