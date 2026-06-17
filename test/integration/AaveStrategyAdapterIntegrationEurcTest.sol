// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2025 [Byzantine Finance]
// The implementation of this contract was inspired by Morpho Vault V2, developed by the Morpho Association in 2025.
pragma solidity ^0.8.0;

import "./AaveStrategyAdapterIntegrationTest.sol";

/// @title EurcAaveStrategyIntegrationTest
/// @notice Runs the shared {AaveStrategy} integration suite against a EURC parent vault.
/// @dev Mainnet fork pinned at block 23027397; underlying is Circle's EURC supplied into the
///      Aave v3 EURC market (aEthEURC).
contract EurcAaveStrategyIntegrationTest is AaveStrategyAdapterIntegrationTest {
    function _forkBlock() internal pure override returns (uint256) {
        return 23027397;
    }

    function _underlying() internal pure override returns (IERC20) {
        return IERC20(0x1aBaEA1f7C830bD89Acc67eC4af516284b1bC33c); // EURC
    }

    function _aToken() internal pure override returns (IERC20) {
        return IERC20(0xAA6e91C82942aeAE040303Bf96c15a6dBcB82CA0); // aEthEURC
    }

    function _vaultName() internal pure override returns (string memory) {
        return "EURC Aave Vault";
    }

    function _vaultSymbol() internal pure override returns (string memory) {
        return "vEURC-AAVE";
    }

    // The Aave v3 EURC market has a small supply cap (~7M EURC, only tens of thousands of
    // headroom at the test block), so deposits are sized conservatively below it.
    function _largeDepositAmount() internal pure override returns (uint256) {
        return 25_000e6;
    }

    function _yieldDepositAmount() internal pure override returns (uint256) {
        return 25_000e6;
    }

    /// forge-config: default.isolate = true
    function testYieldAccrualIsCapturedByVault() public {
        _checkYieldAccrualIsCapturedByVault(_yieldDepositAmount());
    }
}
