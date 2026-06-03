// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2025 [Byzantine Finance]
// The implementation of this contract was inspired by Morpho Vault V2, developed by the Morpho Association in 2025.
pragma solidity ^0.8.0;

import "./AaveStrategyAdapterIntegrationTest.sol";

/// @title UsdcAaveStrategyIntegrationTest
/// @notice Runs the shared {AaveStrategy} integration suite against a USDC parent vault.
/// @dev Mainnet fork pinned at block 23027397; underlying is USDC supplied into the Aave v3
///      USDC market (aEthUSDC).
contract UsdcAaveStrategyIntegrationTest is AaveStrategyAdapterIntegrationTest {
    function _forkBlock() internal pure override returns (uint256) {
        return 23027397;
    }

    function _underlying() internal pure override returns (IERC20) {
        return IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48); // USDC
    }

    function _aToken() internal pure override returns (IERC20) {
        return IERC20(0x98C23E9d8f34FEFb1B7BD6a91B7FF122F4e16F5c); // aEthUSDC
    }

    function _vaultName() internal pure override returns (string memory) {
        return "USDC Aave Vault";
    }

    function _vaultSymbol() internal pure override returns (string memory) {
        return "vUSDC-AAVE";
    }

    /// forge-config: default.isolate = true
    function testYieldAccrualIsCapturedByVault() public {
        _checkYieldAccrualIsCapturedByVault(_yieldDepositAmount());
    }
}
