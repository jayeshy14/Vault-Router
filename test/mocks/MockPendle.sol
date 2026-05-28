// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import { IPendleRouter } from "../../src/interfaces/external/IPendleRouter.sol";
import { IPYLpOracle } from "../../src/interfaces/external/IPYLpOracle.sol";

/// @title MockPrincipalToken
/// @notice Test-only stand-in for a Pendle PT. An ERC20 plus the maturity
///         surface the strategy facet reads (`isExpired`, `expiry`, `YT`, `SY`).
///         Mint/burn are open so the paired MockPendleRouter can settle swaps.
contract MockPrincipalToken is ERC20 {
    uint256 internal immutable _expiry;
    address internal immutable _yt;
    address internal immutable _sy;
    uint8 internal immutable _dec;

    constructor(uint8 dec_, uint256 expiry_, address yt_, address sy_) ERC20("Mock PT", "PT") {
        _dec = dec_;
        _expiry = expiry_;
        _yt = yt_;
        _sy = sy_;
    }

    function isExpired() external view returns (bool) {
        return block.timestamp >= _expiry;
    }

    function expiry() external view returns (uint256) {
        return _expiry;
    }

    function SY() external view returns (address) {
        return _sy;
    }

    function YT() external view returns (address) {
        return _yt;
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

/// @title MockPendleRouter
/// @notice Test-only PendleRouterV4 stand-in covering the three paths the
///         strategy facet uses: buy PT, sell PT pre-maturity, redeem PT at
///         maturity. Conversion is configurable so tests can model both a clean
///         par market and a discounted one:
///         - `depositRateBps` — PT minted per unit of asset on deposit
///           (10_000 = 1:1 par; 10_500 = buy at a 5% discount → more PT).
///         - `withdrawHaircutBps` — underlying shaved off on a pre-maturity
///           sell, simulating the AMM discount (post-maturity redeem is always
///           1:1). Set to 10_000 to force a zero-output revert path.
///         Must be pre-funded with the underlying asset to pay out withdrawals.
contract MockPendleRouter is IPendleRouter {
    IERC20 internal immutable asset;
    MockPrincipalToken internal immutable pt;

    uint256 public depositRateBps = 10_000;
    uint256 public withdrawHaircutBps;

    constructor(IERC20 asset_, MockPrincipalToken pt_) {
        asset = asset_;
        pt = pt_;
    }

    function setDepositRateBps(uint256 bps) external {
        depositRateBps = bps;
    }

    function setWithdrawHaircutBps(uint256 bps) external {
        withdrawHaircutBps = bps;
    }

    function swapExactTokenForPt(
        address receiver,
        address,
        uint256 minPtOut,
        ApproxParams calldata,
        TokenInput calldata input,
        LimitOrderData calldata
    )
        external
        payable
        returns (uint256 netPtOut, uint256, uint256)
    {
        asset.transferFrom(msg.sender, address(this), input.netTokenIn);
        netPtOut = (input.netTokenIn * depositRateBps) / 10_000;
        require(netPtOut >= minPtOut, "MockPendle: minPtOut");
        pt.mint(receiver, netPtOut);
    }

    function swapExactPtForToken(
        address receiver,
        address,
        uint256 exactPtIn,
        TokenOutput calldata output,
        LimitOrderData calldata
    )
        external
        returns (uint256 netTokenOut, uint256, uint256)
    {
        pt.transferFrom(msg.sender, address(this), exactPtIn);
        netTokenOut = (exactPtIn * (10_000 - withdrawHaircutBps)) / 10_000;
        require(netTokenOut >= output.minTokenOut, "MockPendle: minTokenOut");
        asset.transfer(receiver, netTokenOut);
    }

    function redeemPyToToken(
        address receiver,
        address,
        uint256 netPyIn,
        TokenOutput calldata output
    )
        external
        returns (uint256 netTokenOut, uint256)
    {
        pt.transferFrom(msg.sender, address(this), netPyIn);
        netTokenOut = netPyIn; // post-maturity PT redeems 1:1
        require(netTokenOut >= output.minTokenOut, "MockPendle: minTokenOut");
        asset.transfer(receiver, netTokenOut);
    }
}

/// @title MockPYLpOracle
/// @notice Test-only PendlePYLpOracle stand-in. Returns a settable PT->asset
///         rate (1e18 = par; 0.95e18 = PT marked at a 5% discount) so tests can
///         drive the facet's mark-to-market branch deterministically.
contract MockPYLpOracle is IPYLpOracle {
    uint256 public rate = 1e18;

    function setRate(uint256 rate_) external {
        rate = rate_;
    }

    function getPtToAssetRate(address, uint32) external view returns (uint256) {
        return rate;
    }

    function getOracleState(address, uint32) external pure returns (bool, uint16, bool) {
        return (false, 0, true);
    }
}
