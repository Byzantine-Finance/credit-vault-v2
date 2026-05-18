// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initial_Deployment_Parser} from "../utils/Initial_Deployment_Parser.s.sol";

/**
 * @notice Script used for the first deployment on Base
 * forge script script/deploy/base/Deploy_Base_From_Scratch.s.sol --rpc-url $BASE_RPC_URL --private-key $PRIVATE_KEY
 * --broadcast --etherscan-api-key $ETHERSCAN_API_KEY --verify -vv
 *
 */
contract Deploy_Base_From_Scratch is Initial_Deployment_Parser {
    function run() external {
        // START RECORDING TRANSACTIONS FOR DEPLOYMENT
        vm.startBroadcast();

        emit log_named_address("Deployer Address", msg.sender);

        _deployFromScratch();

        // STOP RECORDING TRANSACTIONS FOR DEPLOYMENT
        vm.stopBroadcast();

        _logAndOutputContractAddresses("./script/deploy/base/Addresses_Base.json");
    }
}
