// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import { LibDiamond } from "../../libraries/LibDiamond.sol";
import { IPendleRouter } from "../../interfaces/external/IPendleRouter.sol";
import { IPPrincipalToken } from "../../interfaces/external/IPPrincipalToken.sol";
import { IPYLpOracle } from "../../interfaces/external/IPYLpOracle.sol";

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
///      Pre-maturity: marks the PT position to market via PendlePYLpOracle
///      (getPtToAssetRate), so the reported value reflects the discount PT
///      trades at before expiry rather than its face value. If no oracle has
///      been configured the facet falls back to face value (a slight
///      overstatement) so the strategy still functions on markets without a
///      seeded oracle.
///      Post-maturity: PT redeems 1:1, so face value is exact and the oracle is
///      bypassed.
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

    /// @notice Thrown when the oracle is configured with a zero address or a
    ///         zero TWAP duration.
    error PendleInvalidOracle();

    /// @notice Thrown when a configured slippage tolerance exceeds 100%.
    error PendleInvalidSlippage(uint16 bps);

    // -----------------------------------------------------------------------
    // Events
    // -----------------------------------------------------------------------

    /// @notice Emitted when the facet is configured (or reconfigured).
    event PendleConfigSet(address indexed router, address indexed market, address indexed pt);

    /// @notice Emitted when the mark-to-market oracle is set (or cleared).
    event PendleOracleSet(address indexed oracle, uint32 twapDuration);

    /// @notice Emitted when the max AMM slippage tolerance is set.
    event PendleSlippageSet(uint16 maxSlippageBps);

    // -----------------------------------------------------------------------
    // Storage
    // -----------------------------------------------------------------------

    /// @dev erc7201:vaultrouter.strategy.pendle
    bytes32 internal constant PENDLE_STORAGE_SLOT = 0xb0e016db49ce2cfbe35770c2200cbf5f1a9b502bca57dbaaddf328cb9e0cef00;

    /// @dev Basis-points denominator.
    uint16 internal constant PENDLE_BPS = 10_000;

    /// @dev Slippage tolerance (bps) used when none is explicitly configured: 1%.
    uint16 internal constant DEFAULT_MAX_SLIPPAGE_BPS = 100;

    struct PendleStorage {
        /// @notice PendleRouterV4 — handles all swap and redemption paths.
        IPendleRouter router;
        /// @notice Pendle market address (PT/SY AMM pool).
        address market;
        /// @notice The PT token this strategy holds.
        IPPrincipalToken pt;
        /// @notice PendlePYLpOracle used to mark the PT position to market
        ///         pre-maturity. Zero address => fall back to face value.
        IPYLpOracle oracle;
        /// @notice TWAP window (seconds) passed to the oracle.
        uint32 twapDuration;
        /// @notice Max AMM slippage tolerance (bps) applied against the oracle
        ///         mark when deriving minOut for swaps. Zero => 1% default.
        uint16 maxSlippageBps;
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

    /// @notice Set the PendlePYLpOracle and TWAP window used to mark the PT
    ///         position to market pre-maturity.
    /// @dev Owner-gated and orthogonal to pendleSetConfig — kept separate so a
    ///      market can be wired up first and priced accurately once its oracle
    ///      is seeded. Until this is called, pendleTotalAssets reports face
    ///      value. The caller is responsible for confirming the market's oracle
    ///      is ready (see IPYLpOracle.getOracleState) for the chosen duration.
    /// @param oracle        PendlePYLpOracle address.
    /// @param twapDuration  TWAP window in seconds (must be non-zero).
    function pendleSetOracle(IPYLpOracle oracle, uint32 twapDuration) external {
        LibDiamond.enforceIsContractOwner();
        if (address(oracle) == address(0) || twapDuration == 0) revert PendleInvalidOracle();

        PendleStorage storage s = _ps();
        s.oracle = oracle;
        s.twapDuration = twapDuration;

        emit PendleOracleSet(address(oracle), twapDuration);
    }

    /// @notice Set the maximum AMM slippage tolerance (bps) for pre-maturity
    ///         swaps, applied against the oracle mark when deriving minOut.
    /// @dev Owner-gated. Only enforceable when an oracle is configured — without
    ///      an on-chain mark there is no reference to bound the swap against.
    /// @param bps Tolerance in basis points (<= 10_000). Zero selects the 1% default.
    function pendleSetSlippage(uint16 bps) external {
        LibDiamond.enforceIsContractOwner();
        if (bps > PENDLE_BPS) revert PendleInvalidSlippage(bps);
        _ps().maxSlippageBps = bps;
        emit PendleSlippageSet(bps);
    }

    /// @dev Effective slippage tolerance: the configured value, or the 1% default.
    function _maxSlippageBps(PendleStorage storage s) private view returns (uint16) {
        uint16 bps = s.maxSlippageBps;
        return bps == 0 ? DEFAULT_MAX_SLIPPAGE_BPS : bps;
    }

    // -----------------------------------------------------------------------
    // Strategy surface (pendle* prefix)
    // -----------------------------------------------------------------------

    /// @notice Current asset value of the Pendle position, denominated in the
    ///         vault's underlying asset.
    /// @dev Pre-maturity, with an oracle configured: marks the PT balance to
    ///      market via PendlePYLpOracle.getPtToAssetRate (rate scaled 1e18), so
    ///      the discount PT trades at is reflected. Post-maturity, or when no
    ///      oracle is set, returns PT face value — exact after expiry, a slight
    ///      overstatement before it.
    function pendleTotalAssets() external view returns (uint256) {
        PendleStorage storage s = _ps();
        if (address(s.pt) == address(0)) return 0;

        uint256 ptBalance = s.pt.balanceOf(address(this));

        // Face value when the position is empty, post-maturity (redeems 1:1),
        // or no oracle is configured.
        if (ptBalance == 0 || address(s.oracle) == address(0) || s.pt.isExpired()) {
            return ptBalance;
        }

        // PT and the underlying asset share decimals in Pendle, so the 1e18
        // rate converts the balance directly with no decimal adjustment.
        uint256 rate = s.oracle.getPtToAssetRate(s.market, s.twapDuration);
        return ptBalance * rate / 1e18;
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
                swapType: IPendleRouter.SwapType.NONE, extRouter: address(0), extCalldata: "", needScale: false
            })
        });

        // Loose binary-search bounds — the router will converge within 256
        // iterations to within 0.1% of the optimal PT amount.
        IPendleRouter.ApproxParams memory approx = IPendleRouter.ApproxParams({
            guessMin: 0, guessMax: type(uint256).max, guessOffchain: 0, maxIteration: 256, eps: 1e15
        });

        // Empty limit order, strategy does not participate in the limit book.
        IPendleRouter.LimitOrderData memory limit;

        // Derive an on-chain minimum from the oracle mark when available: invert
        // the PT->asset rate to value `amount` in PT, then haircut by the
        // slippage tolerance. The router reverts if it cannot meet minPtOut.
        // Without an oracle there is no mark to bound against, so we fall back to
        // 0 (unchanged behaviour for unpriced markets) and rely on the post-call
        // zero check.
        uint256 minPtOut;
        if (address(s.oracle) != address(0)) {
            uint256 rate = s.oracle.getPtToAssetRate(s.market, s.twapDuration);
            if (rate > 0) {
                uint256 expectedPt = amount * 1e18 / rate;
                minPtOut = expectedPt * (PENDLE_BPS - _maxSlippageBps(s)) / PENDLE_BPS;
            }
        }

        (uint256 netPtOut,,) = s.router
            .swapExactTokenForPt(
                address(this), // PT receiver is the vault itself
                s.market,
                minPtOut,
                approx,
                input,
                limit
            );

        if (netPtOut == 0) revert PendleDepositFailed(netPtOut);
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

        IERC20(address(s.pt)).forceApprove(address(s.router), amount);

        uint256 received;

        if (s.pt.isExpired()) {
            // Post-maturity: PT redeems 1:1. minTokenOut = 99% (dust tolerance).
            IPendleRouter.TokenOutput memory output = IPendleRouter.TokenOutput({
                tokenOut: address(underlying),
                minTokenOut: amount * 99 / 100,
                tokenRedeemSy: address(underlying),
                pendleSwap: address(0),
                swapData: IPendleRouter.SwapData({
                    swapType: IPendleRouter.SwapType.NONE, extRouter: address(0), extCalldata: "", needScale: false
                })
            });

            // redeemPyToToken burns PT (YT is implicitly 0 post-maturity).
            (received,) = s.router.redeemPyToToken(address(this), s.pt.YT(), amount, output);
        } else {
            // Pre-maturity: sell PT on the Pendle AMM. Derive minTokenOut from the
            // oracle mark when available (PT->asset rate, haircut by slippage) so
            // the router itself enforces the bound; fall back to 0 only when no
            // oracle is configured (unchanged behaviour for unpriced markets).
            uint256 minTokenOut;
            if (address(s.oracle) != address(0)) {
                uint256 rate = s.oracle.getPtToAssetRate(s.market, s.twapDuration);
                if (rate > 0) {
                    uint256 expected = amount * rate / 1e18;
                    minTokenOut = expected * (PENDLE_BPS - _maxSlippageBps(s)) / PENDLE_BPS;
                }
            }

            IPendleRouter.TokenOutput memory output = IPendleRouter.TokenOutput({
                tokenOut: address(underlying),
                minTokenOut: minTokenOut,
                tokenRedeemSy: address(underlying),
                pendleSwap: address(0),
                swapData: IPendleRouter.SwapData({
                    swapType: IPendleRouter.SwapType.NONE, extRouter: address(0), extCalldata: "", needScale: false
                })
            });

            IPendleRouter.LimitOrderData memory limit;

            (received,,) = s.router.swapExactPtForToken(address(this), s.market, amount, output, limit);
        }

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

    function pendleOracle() external view returns (IPYLpOracle) {
        return _ps().oracle;
    }

    function pendleTwapDuration() external view returns (uint32) {
        return _ps().twapDuration;
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
