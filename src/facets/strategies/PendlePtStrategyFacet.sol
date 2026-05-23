// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import { LibDiamond } from "../../libraries/LibDiamond.sol";
import { IPendleRouter } from "../../interfaces/external/IPendleRouter.sol";
import { IPPrincipalToken } from "../../interfaces/external/IPPrincipalToken.sol";

/// @title PendleStrategyFacet
/// @notice Strategy facet that buys Pendle PT with the vault's underlying asset,
///         holds it until maturity (or sells early via the Pendle AMM), and
///         reports the position value back to the allocator.
///
/// @dev Selectors are prefixed with `pendle*` to coexist with other strategy
///      facets in the same Diamond without selector collisions.
///      State lives at EIP-7201 slot `vaultrouter.strategy.pendle`.
///
///      YIELD MECHANISM
///      PT is a zero-coupon bond — you buy it at a discount and redeem 1:1 for
///      the underlying at maturity. The "yield" is the discount captured at
///      purchase. There are no claimable reward tokens; pendleHarvest is a no-op.
///
///      TOTAL ASSETS REPORTING
///      Pre-maturity: reports PT face value (1:1 to underlying). This slightly
///      overstates the immediately-realisable value because PT trades at a
///      discount before expiry. A production deployment should replace this with
///      a call to PendlePYLpOracle for accurate mark-to-market pricing.
///      Post-maturity: face value equals redeemable value exactly.
///
///      WITHDRAWAL PATH
///      Pre-maturity:  PendleRouterV4.swapExactPtForToken  (sell on AMM)
///      Post-maturity: PendleRouterV4.redeemPyToToken      (burn PT, skip YT)
contract PendlePtStrategyFacet {
    using SafeERC20 for IERC20;

    // -----------------------------------------------------------------------
    // Errors
    // -----------------------------------------------------------------------

    /// @notice Thrown when the facet has not been configured yet.
    error PendleNotConfigured();

    /// @notice Thrown on deposit when the market has already expired.
    error PendleMarketExpired();

    /// @notice Thrown when a deposit produces zero PT.
    error PendleDepositFailed(uint256 received);

    /// @notice Thrown when a withdrawal produces zero underlying.
    error PendleWithdrawFailed(uint256 minExpected, uint256 received);

    /// @notice Thrown when the requested withdrawal amount exceeds PT balance.
    error PendleInsufficientPt(uint256 requested, uint256 available);

    // -----------------------------------------------------------------------
    // Events
    // -----------------------------------------------------------------------

    /// @notice Emitted when the facet is configured (or reconfigured).
    event PendleConfigSet(
        address indexed router,
        address indexed market,
        address indexed pt
    );

    // -----------------------------------------------------------------------
    // Storage
    // -----------------------------------------------------------------------

    /// @dev erc7201:vaultrouter.strategy.pendle
    bytes32 internal constant PENDLE_STORAGE_SLOT =
        0xb0e016db49ce2cfbe35770c2200cbf5f1a9b502bca57dbaaddf328cb9e0cef00;

    struct PendleStorage {
        /// @notice PendleRouterV4 — handles all swap and redemption paths.
        IPendleRouter router;
        /// @notice Pendle market address (PT/SY AMM pool).
        address market;
        /// @notice The PT token this strategy holds.
        IPPrincipalToken pt;
    }

    function _ps() internal pure returns (PendleStorage storage s) {
        bytes32 slot = PENDLE_STORAGE_SLOT;
        assembly {
            s.slot := slot
        }
    }

    // -----------------------------------------------------------------------
    // Configuration
    // -----------------------------------------------------------------------

    /// @notice Configure the Pendle router, market, and PT for this strategy.
    /// @dev Owner-gated. Must be called before the strategy is registered with
    ///      the allocator. Can be called again to switch to a different market
    ///      or PT maturity (e.g. rolling a position forward).
    /// @param router  PendleRouterV4 address.
    /// @param market  Pendle market (PT/SY pool) address.
    /// @param pt      PendlePrincipalToken address for the chosen market.
    function pendleSetConfig(IPendleRouter router, address market, IPPrincipalToken pt) external {
        LibDiamond.enforceIsContractOwner();
        if (address(router) == address(0) || market == address(0) || address(pt) == address(0)) {
            revert PendleNotConfigured();
        }

        PendleStorage storage s = _ps();
        s.router = router;
        s.market = market;
        s.pt = pt;

        emit PendleConfigSet(address(router), market, address(pt));
    }

    // -----------------------------------------------------------------------
    // Strategy surface (pendle* prefix)
    // -----------------------------------------------------------------------

    /// @notice Current asset value of the Pendle position, denominated in the
    ///         vault's underlying asset.
    /// @dev Returns PT face value (1:1 to underlying). Pre-maturity this is a
    ///      slight overstatement because PT trades at a discount. Post-maturity
    ///      it is exact — PT redeems 1:1.
    ///      TODO: replace with PendlePYLpOracle call for accurate pre-maturity pricing.
    function pendleTotalAssets() external view returns (uint256) {
        PendleStorage storage s = _ps();
        if (address(s.pt) == address(0)) return 0;
        return s.pt.balanceOf(address(this));
    }

    /// @notice Buy PT with `amount` of the vault's underlying asset.
    /// @dev Calls PendleRouterV4.swapExactTokenForPt with a direct token->SY->PT
    ///      path (no external swap aggregator). Reverts if the market is expired
    ///      or if zero PT is received.
    /// @param amount Quantity of underlying asset to spend.
    function pendleDeposit(uint256 amount) external {
        PendleStorage storage s = _ps();
        if (address(s.router) == address(0)) revert PendleNotConfigured();
        if (s.pt.isExpired()) revert PendleMarketExpired();

        IERC20 underlying = IERC20(IERC4626(address(this)).asset());
        underlying.forceApprove(address(s.router), amount);

        // Direct token -> SY path. tokenMintSy == tokenIn means the SY
        // wrapper accepts the underlying directly (true for most USDC SYs).
        IPendleRouter.TokenInput memory input = IPendleRouter.TokenInput({
            tokenIn: address(underlying),
            netTokenIn: amount,
            tokenMintSy: address(underlying),
            pendleSwap: address(0),
            swapData: IPendleRouter.SwapData({
                swapType: IPendleRouter.SwapType.NONE,
                extRouter: address(0),
                extCalldata: "",
                needScale: false
            })
        });

        // Loose binary-search bounds — the router will converge within 256
        // iterations to within 0.1% of the optimal PT amount.
        IPendleRouter.ApproxParams memory approx = IPendleRouter.ApproxParams({
            guessMin: 0,
            guessMax: type(uint256).max,
            guessOffchain: 0,
            maxIteration: 256,
            eps: 1e15
        });

        // Empty limit order — strategy does not participate in the limit book.
        IPendleRouter.LimitOrderData memory limit;

        uint256 ptBefore = s.pt.balanceOf(address(this));

        s.router.swapExactTokenForPt(
            address(this), // PT receiver is the vault itself
            s.market,
            0, // minPtOut: checked post-call below
            approx,
            input,
            limit
        );

        uint256 ptReceived = s.pt.balanceOf(address(this)) - ptBefore;
        if (ptReceived == 0) revert PendleDepositFailed(ptReceived);
    }

    /// @notice Return `amount` of underlying from the Pendle position to the vault.
    /// @dev Routes through the appropriate path depending on maturity:
    ///      - Pre-maturity:  sells PT on the Pendle AMM via swapExactPtForToken.
    ///      - Post-maturity: redeems PT at face value via redeemPyToToken.
    ///
    ///      `amount` is treated as the PT quantity to liquidate (face value units).
    ///      The underlying received may be slightly less pre-maturity due to
    ///      the AMM discount; post-maturity it is 1:1.
    /// @param amount PT quantity to liquidate (denominated in underlying units).
    function pendleWithdraw(uint256 amount) external {
        PendleStorage storage s = _ps();
        if (address(s.router) == address(0)) revert PendleNotConfigured();

        uint256 ptBalance = s.pt.balanceOf(address(this));
        if (amount > ptBalance) revert PendleInsufficientPt(amount, ptBalance);

        IERC20 underlying = IERC20(IERC4626(address(this)).asset());
        uint256 underlyingBefore = underlying.balanceOf(address(this));

        IERC20(address(s.pt)).forceApprove(address(s.router), amount);

        if (s.pt.isExpired()) {
            // Post-maturity: PT redeems 1:1. minTokenOut = 99% (dust tolerance).
            IPendleRouter.TokenOutput memory output = IPendleRouter.TokenOutput({
                tokenOut: address(underlying),
                minTokenOut: amount * 99 / 100,
                tokenRedeemSy: address(underlying),
                pendleSwap: address(0),
                swapData: IPendleRouter.SwapData({
                    swapType: IPendleRouter.SwapType.NONE,
                    extRouter: address(0),
                    extCalldata: "",
                    needScale: false
                })
            });

            // redeemPyToToken burns PT (YT is implicitly 0 post-maturity).
            s.router.redeemPyToToken(address(this), s.pt.YT(), amount, output);
        } else {
            // Pre-maturity: sell PT on the Pendle AMM.
            // minTokenOut = 0 here; slippage is validated post-call.
            IPendleRouter.TokenOutput memory output = IPendleRouter.TokenOutput({
                tokenOut: address(underlying),
                minTokenOut: 0,
                tokenRedeemSy: address(underlying),
                pendleSwap: address(0),
                swapData: IPendleRouter.SwapData({
                    swapType: IPendleRouter.SwapType.NONE,
                    extRouter: address(0),
                    extCalldata: "",
                    needScale: false
                })
            });

            IPendleRouter.LimitOrderData memory limit;

            s.router.swapExactPtForToken(address(this), s.market, amount, output, limit);
        }

        uint256 received = underlying.balanceOf(address(this)) - underlyingBefore;
        if (received == 0) revert PendleWithdrawFailed(amount, received);
    }

    /// @notice No-op. PT yield accrues entirely to face value at maturity —
    ///         there are no claimable reward tokens to harvest.
    function pendleHarvest() external pure { }

    // -----------------------------------------------------------------------
    // Readers
    // -----------------------------------------------------------------------

    function pendleRouter() external view returns (IPendleRouter) {
        return _ps().router;
    }

    function pendleMarket() external view returns (address) {
        return _ps().market;
    }

    function pendlePT() external view returns (IPPrincipalToken) {
        return _ps().pt;
    }

    function pendleIsExpired() external view returns (bool) {
        PendleStorage storage s = _ps();
        if (address(s.pt) == address(0)) revert PendleNotConfigured();
        return s.pt.isExpired();
    }

    function pendleExpiry() external view returns (uint256) {
        PendleStorage storage s = _ps();
        if (address(s.pt) == address(0)) revert PendleNotConfigured();
        return s.pt.expiry();
    }
}
