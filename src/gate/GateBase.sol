// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2025 [Byzantine Finance]
// The implementation of this contract was inspired by Morpho Vault V2, developed by the Morpho Association in 2025.
pragma solidity ^0.8.0;

import {Ownable2Step, Ownable} from "../../lib/openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import {Clones} from "../../lib/openzeppelin-contracts/contracts/proxy/Clones.sol";

/// @notice Morpho Bundler3 contract interface
/// @dev Must give the address that initiates the transaction to the vault (real msg.sender)
/// @dev Source code here: https://github.com/morpho-org/bundler3/blob/main/src/Bundler3.sol
interface IBundler3 {
    function initiator() external view returns (address);
}

/// @notice Bundler Adapter contract interface (must support erc4626 deposits and withdrawals)
/// @dev Must give the Bundler3 contract used by the initiator
/// @dev Very likely the GeneralAdapter1:
/// https://github.com/morpho-org/bundler3/blob/main/src/adapters/GeneralAdapter1.sol
interface IBundlerAdapter {
    function BUNDLER3() external view returns (IBundler3);
}

/**
 * @title GateBase
 * @notice Base contract for ReceiveSharesGate, SendSharesGate, ReceiveAssetsGate and SendAssetsGate.
 * @dev This contract is used to manage the whitelist and the bundler adapters.
 */
abstract contract GateBase is Ownable2Step {
    /* STORAGE */

    mapping(address => bool) public isBundlerAdapter;
    mapping(address => bool) public whitelisted;
    mapping(address => address) public clonerImplementation;

    /* EVENTS */

    event SetIsWhitelisted(address indexed account, bool newIsWhitelisted);
    event SetIsBundlerAdapter(address indexed account, bool newIsBundlerAdapter);
    event SetClonerImplementation(address indexed cloner, address indexed implementation);

    /* ERRORS */

    error ArrayLengthMismatch();
    error AlreadySet();
    error NotAllowedToRenounceOwnership();
    error NotTrustedCloner();

    /* CONSTRUCTOR */

    constructor(address _owner) Ownable(_owner) {}

    /* ROLES FUNCTIONS */

    /// @notice Set who is whitelisted.
    function setIsWhitelisted(address account, bool newIsWhitelisted) external onlyOwner {
        _setIsWhitelisted(account, newIsWhitelisted);
    }

    /// @notice Set who is whitelisted in batch.
    function setIsWhitelistedBatch(address[] memory accounts, bool[] memory newIsWhitelisted) external onlyOwner {
        require(accounts.length == newIsWhitelisted.length, ArrayLengthMismatch());
        for (uint256 i; i < accounts.length; ++i) {
            _setIsWhitelisted(accounts[i], newIsWhitelisted[i]);
        }
    }

    /// @notice Set who is allowed to handle shares and assets on behalf of another account.
    function setIsBundlerAdapter(address account, bool newIsBundlerAdapter) external onlyOwner {
        isBundlerAdapter[account] = newIsBundlerAdapter;
        emit SetIsBundlerAdapter(account, newIsBundlerAdapter);
    }

    /// @notice Allow (or revoke with `address(0)`) `cloner` to whitelist EIP-1167 clones of `implementation`.
    function setClonerImplementation(address cloner, address implementation) external onlyOwner {
        clonerImplementation[cloner] = implementation;
        emit SetClonerImplementation(cloner, implementation);
    }

    /// @notice Sets the whitelist status of the EIP-1167 clone the calling trusted cloner deployed with `salt`.
    function setIsCloneWhitelisted(bytes32 salt, bool newIsWhitelisted) external returns (address clone) {
        address implementation = clonerImplementation[msg.sender];
        require(implementation != address(0), NotTrustedCloner());
        clone = Clones.predictDeterministicAddress(implementation, salt, msg.sender);
        _setIsWhitelisted(clone, newIsWhitelisted);
    }

    /// @notice Not allowed to renounce ownership.
    function renounceOwnership() public view override onlyOwner {
        revert NotAllowedToRenounceOwnership();
    }

    /* INTERNAL FUNCTIONS */

    function _setIsWhitelisted(address account, bool newIsWhitelisted) internal {
        require(whitelisted[account] != newIsWhitelisted, AlreadySet());
        whitelisted[account] = newIsWhitelisted;
        emit SetIsWhitelisted(account, newIsWhitelisted);
    }

    /// @notice Check if `account` is whitelisted or handling on behalf of another account.
    function _whitelistedOrHandlingOnBehalf(address account) internal view returns (bool) {
        return whitelisted[account]
            || (isBundlerAdapter[account] && whitelisted[IBundlerAdapter(account).BUNDLER3().initiator()]);
    }
}
