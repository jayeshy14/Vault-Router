// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import { LibDiamond } from "../../libraries/LibDiamond.sol";
import { IStakedUSDEV2 } from "../../interfaces/external/IStakedUSDEV2.sol";
import { ICurvePool } from "../../interfaces/external/ICurvePool.sol";

contract EthenaStrategyFacet {
    using SafeERC20 for IERC20;

    /*====errors====*/

    error EthenaUSDENotConfigured();
    error EthenaSlippageExceeded(uint256 minOut, uint256 received);
    error EthenaCoinNotInPool(address tokenIn, address tokenOut);
    error EthenaZeroAddress();


    /*====events====*/

    event EthenaSetConfig( address indexed usde, address indexed curvePool, address indexed stakedUSDEV2);

    // erc7201:vaultrouter.strategy.ethena
    bytes32 internal constant ETHENA_STORAGE_SLOT =
        //0x79d5a97e8f8d9829cf9573ba239138882c2da3a5eaaa986a771c2ca1596b9500;
    
    struct EthenaStorage {
        IERC20 usde;
        ICurvePool curvePool;
        IStakedUSDEV2 stakedUSDEV2;
        uint256 maxSlippageBps;
        uint256 cooldownDuration;

        /*====only for offchain explicit routing ====*/ 

        //mapping (address => bool) allowedRouter;
        //mapping (address => bool) allowedSpender;

    }

    function _es() internal pure returns (EthenaStorage storage s) {
        bytes32 slot = ETHENA_STORAGE_SLOT;
        assembly {
            s.slot := slot
        }
    }

    function ethenaSetConfig(
        IERC20 usde,
        ICurvePool curvePool,
        IStakedUSDEV2 stakedUSDEV2,
        uint256 maxSlippageBps
    )
        external
    {
        LibDiamond.enforceIsContractOwner();
        if (
            address(usde) == address(0) || address(curvePool) == address(0)
                || address(stakedUSDEV2) == address(0)
        ) {
            revert EthenaUSDENotConfigured();
        }
        EthenaStorage storage s = _es();
        s.usde = usde;
        s.curvePool = curvePool;
        s.stakedUSDEV2 = stakedUSDEV2;
        s.maxSlippageBps = maxSlippageBps;
        emit EthenaSetConfig(address(usde), address(curvePool), address(stakedUSDEV2));
    }

    /*====IEthenaStrategy surface====*/

    /// @notice Swap `amount` of the vault's underlying (USDC) into USDe and stake
    ///         it into sUSDe. Driven by the allocator's rebalance with a computed
    ///         delta, so it deposits exactly `amount` — not the whole balance.
    function ethenaDeposit(uint256 amount) external {
        EthenaStorage storage s = _es();
        if (
            address(s.usde) == address(0) || address(s.curvePool) == address(0)
                || address(s.stakedUSDEV2) == address(0)
        ) {
            revert EthenaUSDENotConfigured();
        }
        if (amount == 0) return;

        address underlying = IERC4626(address(this)).asset(); // USDC (6dec)

        // Par-anchored floor: USDC(6dec) -> USDe(18dec), discounted by slippage.
        uint256 minUsde = amount * 1e12 * (10_000 - s.maxSlippageBps) / 10_000;

        // 1. USDC -> USDe on Curve (slippage enforced inside _swap).
        uint256 usde = _swap(underlying, address(s.usde), amount, minUsde);

        // 2. Stake USDe -> sUSDe.
        s.usde.forceApprove(address(s.stakedUSDEV2), usde);
        s.stakedUSDEV2.deposit(usde, address(this));
    }

    /// @notice Position value in underlying (USDC) terms. The facet holds sUSDe,
    ///         not USDe — value the shares at par and scale 18dec -> 6dec.
    function ethenaTotalAssets() external view returns (uint256) {
        EthenaStorage storage s = _es();
        if (address(s.stakedUSDEV2) == address(0)) revert EthenaZeroAddress();
        uint256 shares = s.stakedUSDEV2.balanceOf(address(this));
        if (shares == 0) revert EthenaZeroAddress();
        return s.stakedUSDEV2.convertToAssets(shares) / 1e12; // USDe(18) -> USDC(6)
    }

    function ethenaWithdraw () external {
        
        //withdraw is gated on the core protocol side
        //going asynchronous has lots of variables included and is practically complex

    }

    /*=== cooldown ===*/




    /*==== internal swap helper — Curve only, par-floor enforced by caller ====*/

    /// @dev Executes tokenIn -> tokenOut on the configured Curve StableSwap pool.
    ///      `minOut` is the caller-supplied par-anchored floor; this function is
    ///      pure execution and holds no slippage policy of its own. Returns the
    ///      amount of tokenOut actually received, measured by balance delta so we
    ///      never trust the pool's return value. Internal: the only callers are
    ///      ethenaDeposit / ethenaWithdraw, both reached via the gated rebalance.
    function _swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minOut
    )
        internal
        returns (uint256 received)
    {
        if (amountIn == 0) return 0;
        ICurvePool pool = _es().curvePool;
        if (address(pool) == address(0)) revert EthenaUSDENotConfigured();

        (int128 i, int128 j) = _coinIndices(pool, tokenIn, tokenOut);

        uint256 balBefore = IERC20(tokenOut).balanceOf(address(this));

        IERC20(tokenIn).forceApprove(address(pool), amountIn);
        pool.exchange(i, j, amountIn, minOut, address(this));

        received = IERC20(tokenOut).balanceOf(address(this)) - balBefore;
        if (received < minOut) revert EthenaSlippageExceeded(minOut, received);
    }

    /// @dev Resolve Curve coin indices for a token pair by scanning `coins()`.
    ///      Curve's DynArray getter reverts past the last index, so we try/catch
    ///      and stop at the first out-of-range read. Pools here hold ≤ 8 coins.
    function _coinIndices(
        ICurvePool pool,
        address tokenIn,
        address tokenOut
    )
        internal
        view
        returns (int128 inIdx, int128 outIdx)
    {
        bool foundIn;
        bool foundOut;
        for (uint256 k; k < 8; k++) {
            try pool.coins(k) returns (address c) {
                if (c == tokenIn) {
                    inIdx = int128(uint128(k));
                    foundIn = true;
                }
                if (c == tokenOut) {
                    outIdx = int128(uint128(k));
                    foundOut = true;
                }
            } catch {
                break;
            }
        }
        if (!foundIn || !foundOut) revert EthenaCoinNotInPool(tokenIn, tokenOut);
    }


}