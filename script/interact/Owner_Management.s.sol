// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {IVaultV2} from "../../src/interfaces/IVaultV2.sol";
import {ICompoundV3Adapter} from "../../src/adapters/interfaces/ICompoundV3Adapter.sol";
import "../../src/libraries/ConstantsLib.sol";

/**
 * @notice Script for vault owner to manage the Debt Fund Vault
 * @dev Only the owner can call the functions
 */
contract Owner_Management is Script {
    // Private key of the owner
    uint256 public privateKey = uint256(vm.envBytes32("PRIVATE_KEY"));

    /**
     * @notice Set the owner of the vault
     * @param vault The Vault V2
     * @param owner The address of the owner
     * @dev Can only have one owner
     *
     * forge script script/interact/Owner_Management.s.sol \
     * --sig "setOwner(address,address)" \
     * --rpc-url $RPC_URL \
     * --private-key $PRIVATE_KEY \
     * --broadcast \
     * -- <vault> <owner> \
     * -vvv
     */
    function setOwner(IVaultV2 vault, address owner) public {
        vm.startBroadcast(privateKey);
        vault.setOwner(owner);
        vm.stopBroadcast();
    }

    /**
     * @notice Set the curator of the vault
     * @param vault The Vault V2
     * @param curator The address of the curator
     * @dev Can only have one curator
     *
     * forge script script/interact/Owner_Management.s.sol \
     * --sig "setCurator(address,address)" \
     * --rpc-url $RPC_URL \
     * --private-key $PRIVATE_KEY \
     * --broadcast \
     * -- <vault> <curator> \
     * -vvv
     */
    function setCurator(IVaultV2 vault, address curator) public {
        vm.startBroadcast(privateKey);

        vault.setCurator(curator);

        vm.stopBroadcast();
    }

    /**
     * @notice Set or unset the sentinel of the vault
     * @param vault The Vault V2
     * @param sentinel The address of the sentinel
     * @param isSentinel The boolean value to set the sentinel
     * @dev Can have multiple sentinels
     *
     * forge script script/interact/Owner_Management.s.sol \
     * --sig "setIsSentinel(address,address,bool)" \
     * --rpc-url $RPC_URL \
     * --private-key $PRIVATE_KEY \
     * --broadcast \
     * -- <vault> <sentinel> <isSentinel> \
     * -vvv
     */
    function setIsSentinel(IVaultV2 vault, address sentinel, bool isSentinel) public {
        vm.startBroadcast(privateKey);

        vault.setIsSentinel(sentinel, isSentinel);

        vm.stopBroadcast();
    }

    /**
     * @notice Set the name of the vault
     * @param vault The Vault V2
     * @param name The name of the vault
     *
     * forge script script/interact/Owner_Management.s.sol \
     * --sig "setName(address,string)" \
     * --rpc-url $RPC_URL \
     * --private-key $PRIVATE_KEY \
     * --broadcast \
     * -- <vault> <name> \
     * -vvv
     */
    function setName(IVaultV2 vault, string memory name) public {
        vm.startBroadcast(privateKey);
        vault.setName(name);
        vm.stopBroadcast();
    }

    /**
     * @notice Set the symbol of the vault
     * @param vault The Vault V2
     * @param symbol The symbol of the vault
     *
     * forge script script/interact/Owner_Management.s.sol \
     * --sig "setSymbol(address,string)" \
     * --rpc-url $RPC_URL \
     * --private-key $PRIVATE_KEY \
     * --broadcast \
     * -- <vault> <symbol> \
     * -vvv
     */
    function setSymbol(IVaultV2 vault, string memory symbol) public {
        vm.startBroadcast(privateKey);
        vault.setSymbol(symbol);
        vm.stopBroadcast();
    }
}
