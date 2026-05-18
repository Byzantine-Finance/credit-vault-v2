// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";

import {GateWhitelist} from "../../../src/gate/GateWhitelist.sol";

/**
 * @notice Script used for the deployment of the GateWhitelist on Base
 * forge script script/deploy/base/Deploy_Base_GateWhitelist.s.sol \
 * --rpc-url $BASE_RPC_URL \
 * --private-key $PRIVATE_KEY \
 * --broadcast \
 * --etherscan-api-key $ETHERSCAN_API_KEY \
 * --sig "run(address)" <owner> \
 * --verify -vv
 */
contract Deploy_Base_GateWhitelist is Script {
    GateWhitelist public gateWhitelist;

    function run(address owner) external {
        vm.startBroadcast();

        gateWhitelist = new GateWhitelist(owner);

        vm.stopBroadcast();
    }
}
