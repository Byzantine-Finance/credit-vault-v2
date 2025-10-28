// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2025 [Byzantine Finance]
// The implementation of this contract was inspired by Morpho Vault V2, developed by the Morpho Association in 2025.
pragma solidity ^0.8.0;

import "./GateBase.sol";
import {ISendAssetsGate} from "../../src/interfaces/IGate.sol";

/**
 * @notice Gate that whitelists accounts that can send assets when a deposit is made.
 * @dev It checks users who deposit assets to the vault.
 */
contract SendAssetsGate is GateBase, ISendAssetsGate {
    constructor(address _initialOwner) GateBase(_initialOwner) {}

    /// @notice Check if `account` can supply assets when a deposit is made.
    function canSendAssets(address account) external view returns (bool) {
        return _whitelistedOrHandlingOnBehalf(account);
    }
}
