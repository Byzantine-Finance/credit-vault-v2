// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2025 [Byzantine Finance]
// The implementation of this contract was inspired by Morpho Vault V2, developed by the Morpho Association in 2025.
pragma solidity ^0.8.0;

import "./GateBase.sol";
import {IReceiveAssetsGate} from "../../src/interfaces/IGate.sol";

/**
 * @notice Gate that whitelists accounts that can receive assets when a withdrawal is made.
 * @dev It checks users who receive assets from the vault.
 */
contract ReceiveAssetsGate is GateBase, IReceiveAssetsGate {
    constructor(address _initialOwner) GateBase(_initialOwner) {}
    
    /// @notice Check if `account` can receive assets when a withdrawal is made.
    function canReceiveAssets(address account) external view returns (bool) {
        return _whitelistedOrHandlingOnBehalf(account);
    }
}
