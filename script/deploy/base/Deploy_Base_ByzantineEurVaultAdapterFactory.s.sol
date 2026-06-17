// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";

import {ByzantineEurVaultAdapterFactory} from "../../../src/adapters/ByzantineEurVaultAdapterFactory.sol";

/**
 * @notice Script used for the deployment of the ByzantineEurVaultAdapterFactory on Base
 * forge script script/deploy/base/Deploy_Base_ByzantineEurVaultAdapterFactory.s.sol \
 * --rpc-url $BASE_RPC_URL \
 * --private-key $PRIVATE_KEY \
 * --broadcast \
 * --etherscan-api-key $ETHERSCAN_API_KEY \
 * --verify -vv
 */
contract Deploy_Base_ByzantineEurVaultAdapterFactory is Script {
    string internal constant OUTPUT_PATH = "./script/deploy/base/Addresses_Base.json";

    ByzantineEurVaultAdapterFactory public byzantineEurVaultAdapterFactory;

    function run() external {
        vm.startBroadcast();

        byzantineEurVaultAdapterFactory = new ByzantineEurVaultAdapterFactory();

        vm.stopBroadcast();

        // Store the deployed address in Addresses_Base.json
        vm.writeJson(
            string.concat('"', vm.toString(address(byzantineEurVaultAdapterFactory)), '"'),
            OUTPUT_PATH,
            ".addresses.byzantineEurVaultAdapterFactory"
        );
    }
}
