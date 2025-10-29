// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2025 [Byzantine Finance]
// The implementation of this contract was inspired by Morpho Vault V2, developed by the Morpho Association in 2025.
pragma solidity ^0.8.0;

import {GateBase} from "./GateBase.sol";
import {ISendSharesGate} from "../../src/interfaces/IGate.sol";

/**
 * @notice Gate that whitelists accounts that can send shares when a withdraw or transfer is made.
 * @dev It checks users who withdraw or transfer shares to an address.
 */
contract SendSharesGate is GateBase, ISendSharesGate {
    constructor(address _initialOwner) GateBase(_initialOwner) {}

    /// @notice Check if `account` can send shares.
    function canSendShares(address account) external view returns (bool) {
        return _whitelistedOrHandlingOnBehalf(account);
    }
}
