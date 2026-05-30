// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import { MockProtocol } from "./MockProtocol.sol";

/// @title MockStrategyFacet
/// @notice Test-only strategy facet that bridges the Diamond to a `MockProtocol`.
///         Stores its protocol pointer in an EIP-7201 namespaced slot so it
///         doesn't collide with the vault's ERC-4626 storage or with LibAllocator.
/// @dev keccak256(abi.encode(uint256(keccak256("vaultrouter.test.mockstrategy")) - 1)) & ~bytes32(uint256(0xff))
contract MockStrategyFacet {
    bytes32 internal constant MOCK_STORAGE_SLOT = 0x2a93387479f60fbd0b1454d20ad1a7e5268ff2625b39049c9905b150353cb300;

    struct MockStorage {
        MockProtocol protocol;
        uint256 harvestCount;
        bool reverting;
    }

    function _ms() internal pure returns (MockStorage storage s) {
        bytes32 slot = MOCK_STORAGE_SLOT;
        assembly {
            s.slot := slot
        }
    }

    function mockSetProtocol(MockProtocol protocol) external {
        _ms().protocol = protocol;
    }

    function mockProtocol() external view returns (MockProtocol) {
        return _ms().protocol;
    }

    /// @notice Test-only — when set, the strategy's totalAssets and harvest revert,
    ///         simulating a failing/exploited/stuck underlying protocol.
    function mockSetReverting(bool v) external {
        _ms().reverting = v;
    }

    function mockTotalAssets() external view returns (uint256) {
        if (_ms().reverting) revert("mock: totalAssets reverted");
        MockProtocol p = _ms().protocol;
        if (address(p) == address(0)) return 0;
        return p.balanceOf(address(this));
    }

    function mockDeposit(uint256 amount) external {
        MockProtocol p = _ms().protocol;
        IERC20 token = IERC20(IERC4626(address(this)).asset());
        token.approve(address(p), amount);
        p.deposit(amount);
    }

    function mockWithdraw(uint256 amount) external {
        _ms().protocol.withdraw(amount);
    }

    function mockHarvest() external {
        if (_ms().reverting) revert("mock: harvest reverted");
        _ms().harvestCount += 1;
    }

    function mockHarvestCount() external view returns (uint256) {
        return _ms().harvestCount;
    }
}
