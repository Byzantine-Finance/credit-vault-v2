// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 [Byzantine Finance]
// The implementation of this contract was inspired by Morpho Vault V2, developed by the Morpho Association in 2025.
pragma solidity 0.8.28;

import {ByzantineEurVaultAdapter} from "./ByzantineEurVaultAdapter.sol";
import {IByzantineEurVaultAdapterFactory} from "./interfaces/IByzantineEurVaultAdapterFactory.sol";

contract ByzantineEurVaultAdapterFactory is IByzantineEurVaultAdapterFactory {
    /* STORAGE */

    mapping(address parentVault => mapping(address eurVault => address)) public byzantineEurVaultAdapter;
    mapping(address account => bool) public isByzantineEurVaultAdapter;

    /* FUNCTIONS */

    /// @dev Returns the address of the deployed ByzantineEurVaultAdapter.
    function createByzantineEurVaultAdapter(address parentVault, address eurVault) external returns (address) {
        address _byzantineEurVaultAdapter =
            address(new ByzantineEurVaultAdapter{salt: bytes32(0)}(parentVault, eurVault));
        byzantineEurVaultAdapter[parentVault][eurVault] = _byzantineEurVaultAdapter;
        isByzantineEurVaultAdapter[_byzantineEurVaultAdapter] = true;
        emit CreateByzantineEurVaultAdapter(parentVault, eurVault, _byzantineEurVaultAdapter);
        return _byzantineEurVaultAdapter;
    }
}
