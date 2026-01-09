// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {ReceiveAssetsGate} from "../../../src/gate/ReceiveAssetsGate.sol";
import {ReceiveSharesGate} from "../../../src/gate/ReceiveSharesGate.sol";
import {SendAssetsGate} from "../../../src/gate/SendAssetsGate.sol";
import {SendSharesGate} from "../../../src/gate/SendSharesGate.sol";

contract Whitelist_On_All_Gates is Script {
    // Contracts deployed on Base mainnet
    address constant RECEIVE_ASSETS_GATE = 0x306d95052B08Ea93E1706360B50d5FD8Ed719c46;
    address constant RECEIVE_SHARES_GATE = 0xEb83886A9A4029F64D845d0D12E88d8db2F08f42;
    address constant SEND_ASSETS_GATE = 0xc4eF4B97Ec15DEC69Fa1F155Bf59e33636146986;
    address constant SEND_SHARES_GATE = 0x0D1F65D716651807677AAff71Fb60b446d436906;

    // Gate contracts
    ReceiveAssetsGate public receiveAssetsGate;
    ReceiveSharesGate public receiveSharesGate;
    SendAssetsGate public sendAssetsGate;
    SendSharesGate public sendSharesGate;

    // Set the private key of the owner of the gates in the .env file
    uint256 public privateKey = uint256(vm.envBytes32("PRIVATE_KEY"));

    function setUp() external {
        receiveAssetsGate = ReceiveAssetsGate(RECEIVE_ASSETS_GATE);
        receiveSharesGate = ReceiveSharesGate(RECEIVE_SHARES_GATE);
        sendAssetsGate = SendAssetsGate(SEND_ASSETS_GATE);
        sendSharesGate = SendSharesGate(SEND_SHARES_GATE);
    }

    /**
     * @notice Whitelist an account on all gates
     * @param account The account to whitelist
     *
     * forge script script/interact/base/Whitelist_On_All_Gates.s.sol \
     * --rpc-url $BASE_RPC_URL \
     * --private-key $PRIVATE_KEY \
     * --broadcast \
     * --legacy \
     * --sig "setIsWhitelistedOnAllGates(address, bool)" \
     * -vvv \
     * -- $ACCOUNT $IS_WHITELISTED \
     */
    function setIsWhitelistedOnAllGates(address account, bool isWhitelisted) external {
        vm.startBroadcast(privateKey);

        receiveAssetsGate.setIsWhitelisted(account, isWhitelisted);
        receiveSharesGate.setIsWhitelisted(account, isWhitelisted);
        sendAssetsGate.setIsWhitelisted(account, isWhitelisted);
        sendSharesGate.setIsWhitelisted(account, isWhitelisted);

        vm.stopBroadcast();
    }

    /**
     * @notice Whitelist a batch of accounts on all gates
     * @param accounts The accounts to whitelist
     * @dev $ACCOUNTS and $IS_WHITELISTED should be an array
     *
     * forge script script/interact/base/Whitelist_On_All_Gates.s.sol \
     * --rpc-url $BASE_RPC_URL \
     * --private-key $PRIVATE_KEY \
     * --broadcast \
     * --legacy \
     * --sig "setIsWhitelistedBatchOnAllGates(address[], bool[])" \
     * -vvv
     * -- $ACCOUNTS $IS_WHITELISTED \
     */
    function setIsWhitelistedBatchOnAllGates(address[] memory accounts, bool[] memory isWhitelisted) external {
        vm.startBroadcast(privateKey);

        receiveAssetsGate.setIsWhitelistedBatch(accounts, isWhitelisted);
        receiveSharesGate.setIsWhitelistedBatch(accounts, isWhitelisted);
        sendAssetsGate.setIsWhitelistedBatch(accounts, isWhitelisted);
        sendSharesGate.setIsWhitelistedBatch(accounts, isWhitelisted);

        vm.stopBroadcast();
    }

    /**
     * @notice Set who is allowed to handle shares and assets on behalf of another account on all gates
     * @param account The account to set the bundler adapter for
     * @param isBundlerAdapter Whether the account is a bundler adapter
     *
     * forge script script/interact/base/Whitelist_On_All_Gates.s.sol \
     * --rpc-url $BASE_RPC_URL \
     * --private-key $PRIVATE_KEY \
     * --broadcast \
     * --legacy \
     * --sig "setIsBundlerAdapterOnAllGates(address, bool)" \
     * -vvv
     * -- $ACCOUNT $IS_BUNDLER_ADAPTER \
     */
    function setIsBundlerAdapterOnAllGates(address account, bool isBundlerAdapter) external {
        vm.startBroadcast(privateKey);

        receiveAssetsGate.setIsBundlerAdapter(account, isBundlerAdapter);
        receiveSharesGate.setIsBundlerAdapter(account, isBundlerAdapter);
        sendAssetsGate.setIsBundlerAdapter(account, isBundlerAdapter);
        sendSharesGate.setIsBundlerAdapter(account, isBundlerAdapter);

        vm.stopBroadcast();
    }
}
