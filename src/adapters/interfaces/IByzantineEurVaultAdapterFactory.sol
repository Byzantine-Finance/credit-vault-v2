// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 [Byzantine Finance]
// The implementation of this contract was inspired by Morpho Vault V2, developed by the Morpho Association in 2025.
pragma solidity >=0.5.0;

interface IByzantineEurVaultAdapterFactory {
    /* EVENTS */

    event CreateByzantineEurVaultAdapter(
        address indexed parentVault, address indexed eurVault, address indexed byzantineEurVaultAdapter
    );

    /* FUNCTIONS */

    function byzantineEurVaultAdapter(address parentVault, address eurVault) external view returns (address);
    function isByzantineEurVaultAdapter(address account) external view returns (bool);
    function createByzantineEurVaultAdapter(address parentVault, address eurVault)
        external
        returns (address byzantineEurVaultAdapter);
}
