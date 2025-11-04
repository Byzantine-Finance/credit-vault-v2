// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {ReceiveAssetsGate} from "../../../src/gate/ReceiveAssetsGate.sol";
import {ReceiveSharesGate} from "../../../src/gate/ReceiveSharesGate.sol";
import {SendAssetsGate} from "../../../src/gate/SendAssetsGate.sol";
import {SendSharesGate} from "../../../src/gate/SendSharesGate.sol";

/**
 * @notice Script used for the deployment of the four gate contracts on Ethereum
 * forge script script/deploy/ethereum/Deploy_Ethereum_GateWhitelist.s.sol \
 * --rpc-url $MAINNET_RPC_URL \
 * --private-key $PRIVATE_KEY \
 * --broadcast \
 * --etherscan-api-key $ETHERSCAN_API_KEY \
 * --sig "run(address)" <owner> \
 * --verify -vv
 */
contract Deploy_Ethereum_GateWhitelist is Script {
    ReceiveAssetsGate public receiveAssetsGate;
    ReceiveSharesGate public receiveSharesGate;
    SendAssetsGate public sendAssetsGate;
    SendSharesGate public sendSharesGate;

    function run(address owner) external {
        vm.startBroadcast();

        receiveAssetsGate = new ReceiveAssetsGate(owner);
        receiveSharesGate = new ReceiveSharesGate(owner);
        sendAssetsGate = new SendAssetsGate(owner);
        sendSharesGate = new SendSharesGate(owner);

        vm.stopBroadcast();
    }
}
