// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IPendleRouter
/// @notice Minimal interface for PendleRouterV4 — only the functions the
///         Pendle strategy facet calls. Full router ABI is much larger.
/// @dev Reference: https://github.com/pendle-finance/pendle-core-v2-public/blob/main/contracts/router
interface IPendleRouter {
    // -----------------------------------------------------------------------
    // Swap aggregator type — NONE means no external swap, token goes straight
    // into the SY wrapper.
    // -----------------------------------------------------------------------
    enum SwapType {
        NONE,
        KYBERSWAP,
        ONE_INCH,
        // ETH <-> WETH
        ETH_WETH
    }

    /// @notice Calldata for an optional swap through an external aggregator
    ///         before the token is wrapped into SY. Set all fields to zero /
    ///         false when going directly token -> SY (no aggregator hop).
    struct SwapData {
        SwapType swapType;
        address extRouter;
        bytes extCalldata;
        bool needScale;
    }

    /// @notice Describes the input token path when buying PT or adding liquidity.
    /// @param tokenIn         Token the caller is spending (e.g. USDC).
    /// @param netTokenIn      Amount of tokenIn to spend.
    /// @param tokenMintSy     Token the SY wrapper actually accepts. Equal to
    ///                        tokenIn when no aggregator swap is needed.
    /// @param pendleSwap      Pendle swap helper address (address(0) = none).
    /// @param swapData        External aggregator data (all-zero = none).
    struct TokenInput {
        address tokenIn;
        uint256 netTokenIn;
        address tokenMintSy;
        address pendleSwap;
        SwapData swapData;
    }

    /// @notice Describes the output token path when selling PT or removing liquidity.
    /// @param tokenOut        Token the caller receives (e.g. USDC).
    /// @param minTokenOut     Minimum acceptable output — reverts if not met.
    /// @param tokenRedeemSy   Token the SY wrapper redeems into. Equal to
    ///                        tokenOut when no aggregator swap is needed.
    /// @param pendleSwap      Pendle swap helper address (address(0) = none).
    /// @param swapData        External aggregator data (all-zero = none).
    struct TokenOutput {
        address tokenOut;
        uint256 minTokenOut;
        address tokenRedeemSy;
        address pendleSwap;
        SwapData swapData;
    }

    /// @notice Binary-search bounds for approximating PT output amounts.
    /// @param guessMin       Lower bound for the binary search.
    /// @param guessMax       Upper bound for the binary search.
    /// @param guessOffchain  Off-chain hint to seed the search (0 = no hint).
    /// @param maxIteration   Maximum binary-search iterations.
    /// @param eps            Acceptable relative error (1e18 = 100%). 1e15 = 0.1%.
    struct ApproxParams {
        uint256 guessMin;
        uint256 guessMax;
        uint256 guessOffchain;
        uint256 maxIteration;
        uint256 eps;
    }

    // Limit order structs — included for ABI completeness; the strategy passes
    // empty arrays and zero values (no limit orders used).
    struct Order {
        uint256 salt;
        uint256 expiry;
        uint256 nonce;
        uint8 orderType;
        address token;
        address YT;
        address maker;
        address receiver;
        uint256 makingAmount;
        uint256 lnImpliedRate;
        uint256 failSafeRate;
        bytes permit;
    }

    struct FillOrderParams {
        Order order;
        bytes signature;
        uint256 makingAmount;
    }

    struct LimitOrderData {
        address limitRouter;
        uint256 epsSkipMarket;
        FillOrderParams[] normalFills;
        FillOrderParams[] flashFills;
        bytes optData;
    }

    // -----------------------------------------------------------------------
    // Core functions used by the strategy facet
    // -----------------------------------------------------------------------

    /// @notice Swap an exact amount of a token for PT.
    /// @param receiver     Address that receives the PT.
    /// @param market       Pendle market address (PT/SY pair).
    /// @param minPtOut     Minimum PT output — reverts if not met.
    /// @param guessPtOut   Binary-search params for approximating PT amount.
    /// @param input        Input token path descriptor.
    /// @param limit        Limit order data (pass empty for no limit orders).
    /// @return netPtOut    PT tokens received.
    /// @return netSyFee    SY fee paid to the protocol.
    /// @return netSyInterm Intermediate SY amount used internally.
    function swapExactTokenForPt(
        address receiver,
        address market,
        uint256 minPtOut,
        ApproxParams calldata guessPtOut,
        TokenInput calldata input,
        LimitOrderData calldata limit
    ) external payable returns (uint256 netPtOut, uint256 netSyFee, uint256 netSyInterm);

    /// @notice Swap an exact amount of PT for a token.
    /// @param receiver   Address that receives the output token.
    /// @param market     Pendle market address.
    /// @param exactPtIn  Exact amount of PT to sell.
    /// @param output     Output token path descriptor (includes minTokenOut).
    /// @param limit      Limit order data (pass empty for no limit orders).
    /// @return netTokenOut  Underlying tokens received.
    /// @return netSyFee     SY fee paid to the protocol.
    /// @return netSyInterm  Intermediate SY amount used internally.
    function swapExactPtForToken(
        address receiver,
        address market,
        uint256 exactPtIn,
        TokenOutput calldata output,
        LimitOrderData calldata limit
    ) external returns (uint256 netTokenOut, uint256 netSyFee, uint256 netSyInterm);

    /// @notice Redeem PT (and optionally YT) for the underlying token post-maturity.
    /// @dev After expiry the YT has zero value. Pass netPyIn = PT balance and
    ///      the router will redeem PT-only when YT amount is implicitly zero.
    /// @param receiver  Address that receives the underlying token.
    /// @param YT        Address of the YT contract (= PT's paired YT).
    /// @param netPyIn   Amount of PT to redeem.
    /// @param output    Output token path descriptor.
    /// @return netTokenOut  Underlying tokens received.
    /// @return netSyFee     SY fee paid.
    function redeemPyToToken(
        address receiver,
        address YT,
        uint256 netPyIn,
        TokenOutput calldata output
    ) external returns (uint256 netTokenOut, uint256 netSyFee);
}
