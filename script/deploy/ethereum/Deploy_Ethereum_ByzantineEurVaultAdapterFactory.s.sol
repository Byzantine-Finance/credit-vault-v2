// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";

import {ByzantineEurVaultAdapterFactory} from "../../../src/adapters/ByzantineEurVaultAdapterFactory.sol";

/**
 * @notice Script used for the deployment of the ByzantineEurVaultAdapterFactory on Ethereum mainnet
 * forge script script/deploy/ethereum/Deploy_Ethereum_ByzantineEurVaultAdapterFactory.s.sol \
 * --rpc-url $MAINNET_RPC_URL \
 * --private-key $PRIVATE_KEY \
 * --broadcast \
 * --etherscan-api-key $ETHERSCAN_API_KEY \
 * --verify -vv
 */
contract Deploy_Ethereum_ByzantineEurVaultAdapterFactory is Script {
    string internal constant OUTPUT_PATH = "./script/deploy/ethereum/Addresses_Ethereum.json";

    ByzantineEurVaultAdapterFactory public byzantineEurVaultAdapterFactory;

    function run() external {
        vm.startBroadcast();

        byzantineEurVaultAdapterFactory = new ByzantineEurVaultAdapterFactory();

        vm.stopBroadcast();

        // Store the deployed address in Addresses_Ethereum.json
        vm.writeJson(
            string.concat('"', vm.toString(address(byzantineEurVaultAdapterFactory)), '"'),
            OUTPUT_PATH,
            ".addresses.byzantineEurVaultAdapterFactory"
        );
    }
}
