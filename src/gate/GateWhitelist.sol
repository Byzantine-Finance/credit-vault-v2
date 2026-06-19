// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2025 [Byzantine Finance]
// The implementation of this contract was inspired by Morpho Vault V2, developed by the Morpho Association in 2025.
pragma solidity ^0.8.0;

import {IReceiveSharesGate, ISendSharesGate, IReceiveAssetsGate, ISendAssetsGate} from "../../src/interfaces/IGate.sol";
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

/// VaultV2 Gate with the following characteristics:
/// - It is a send assets gate, i.e. it checks users who deposit assets to the vault.
/// - It is a receive assets gate, i.e. it checks users who receive assets from the vault.
/// - It is a send shares gate, i.e. it checks users who transfer shares to an address.
/// - It is a receive shares gate, i.e. it checks users who receive shares from an address.
/// - It has a single whitelist for all permissions.
/// - It works with Bundler3.
///   To enable transfers to/from a Bundler3 adapter, set isBundlerAdapter[bundlerAdapter] to true.
///   Only trusted Bundler3 adapters should be added (addresses here
///   https://docs.morpho.org/get-started/resources/addresses/#bundlers)
contract GateWhitelist is IReceiveSharesGate, ISendSharesGate, IReceiveAssetsGate, ISendAssetsGate {
    /* STORAGE */

    address public owner;
    mapping(address => bool) public isBundlerAdapter;
    mapping(address => bool) public whitelisted;
    mapping(address => address) public clonerImplementation;

    /* EVENTS */

    event SetOwner(address oldOwner, address indexed newOwner);
    event SetIsWhitelisted(address indexed account, bool newIsWhitelisted);
    event SetIsBundlerAdapter(address indexed account, bool newIsBundlerAdapter);
    event SetClonerImplementation(address indexed cloner, address indexed implementation);

    /* ERRORS */

    error Unauthorized();
    error ArrayLengthMismatch();
    error NotTrustedCloner();

    /* CONSTRUCTOR */

    constructor(address _owner) {
        owner = _owner;
        emit SetOwner(address(0), _owner);
    }

    /* ROLES FUNCTIONS */

    /// @notice Set the owner of the gate.
    function setOwner(address newOwner) external {
        require(msg.sender == owner, Unauthorized());
        owner = newOwner;
        emit SetOwner(msg.sender, newOwner);
    }

    /// @notice Set who is whitelisted.
    function setIsWhitelisted(address account, bool newIsWhitelisted) external {
        require(msg.sender == owner, Unauthorized());
        _setIsWhitelisted(account, newIsWhitelisted);
    }

    /// @notice Set who is whitelisted in batch.
    function setIsWhitelistedBatch(address[] memory accounts, bool[] memory newIsWhitelisted) external {
        require(msg.sender == owner, Unauthorized());
        require(accounts.length == newIsWhitelisted.length, ArrayLengthMismatch());
        for (uint256 i; i < accounts.length; ++i) {
            _setIsWhitelisted(accounts[i], newIsWhitelisted[i]);
        }
    }

    /// @notice Set who is allowed to handle shares and assets on behalf of another account.
    function setIsBundlerAdapter(address account, bool newIsBundlerAdapter) external {
        require(msg.sender == owner, Unauthorized());
        isBundlerAdapter[account] = newIsBundlerAdapter;
        emit SetIsBundlerAdapter(account, newIsBundlerAdapter);
    }

    /// @notice Allow (or revoke with `address(0)`) `cloner` to whitelist EIP-1167 clones of `implementation`.
    function setClonerImplementation(address cloner, address implementation) external {
        require(msg.sender == owner, Unauthorized());
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

    /* VIEW FUNCTIONS */

    /// @notice Check if `account` can supply assets when a deposit is made.
    function canSendAssets(address account) external view returns (bool) {
        return _whitelistedOrHandlingOnBehalf(account);
    }

    /// @notice Check if `account` can receive assets when a withdrawal is made.
    function canReceiveAssets(address account) external view returns (bool) {
        return _whitelistedOrHandlingOnBehalf(account);
    }

    /// @notice Check if `account` can send shares.
    function canSendShares(address account) external view returns (bool) {
        return _whitelistedOrHandlingOnBehalf(account);
    }

    /// @notice Check if `account` can receive shares.
    function canReceiveShares(address account) external view returns (bool) {
        return _whitelistedOrHandlingOnBehalf(account);
    }

    /* INTERNAL FUNCTIONS */

    function _whitelistedOrHandlingOnBehalf(address account) internal view returns (bool) {
        return whitelisted[account]
            || (isBundlerAdapter[account] && whitelisted[IBundlerAdapter(account).BUNDLER3().initiator()]);
    }

    function _setIsWhitelisted(address account, bool newIsWhitelisted) internal {
        whitelisted[account] = newIsWhitelisted;
        emit SetIsWhitelisted(account, newIsWhitelisted);
    }
}
