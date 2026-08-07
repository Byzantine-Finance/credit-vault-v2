// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {GateBase} from "../../../src/gate/GateBase.sol";

contract Whitelist_On_One_Gate is Script {
    // Contracts deployed on Base mainnet
    address constant RECEIVE_ASSETS_GATE = 0x306d95052B08Ea93E1706360B50d5FD8Ed719c46;
    address constant RECEIVE_SHARES_GATE = 0xEb83886A9A4029F64D845d0D12E88d8db2F08f42;
    address constant SEND_ASSETS_GATE = 0xc4eF4B97Ec15DEC69Fa1F155Bf59e33636146986;
    address constant SEND_SHARES_GATE = 0x0D1F65D716651807677AAff71Fb60b446d436906;

    // Set the private key of the owner of the gates in the .env file
    uint256 public privateKey = uint256(vm.envBytes32("PRIVATE_KEY"));

    /// @dev Resolve a gate name to its deployed contract.
    ///      Valid names: "receiveAssets", "receiveShares", "sendAssets", "sendShares"
    function _gate(string memory gateName) internal pure returns (GateBase) {
        bytes32 name = keccak256(bytes(gateName));
        if (name == keccak256("receiveAssets")) return GateBase(RECEIVE_ASSETS_GATE);
        if (name == keccak256("receiveShares")) return GateBase(RECEIVE_SHARES_GATE);
        if (name == keccak256("sendAssets")) return GateBase(SEND_ASSETS_GATE);
        if (name == keccak256("sendShares")) return GateBase(SEND_SHARES_GATE);
        revert(string.concat("Unknown gate: ", gateName));
    }

    /**
     * @notice Whitelist an account on a single gate
     * @param gateName The gate to target: "receiveAssets", "receiveShares", "sendAssets" or "sendShares"
     * @param account The account to whitelist
     *
     * forge script script/interact/base/Whitelist_On_One_Gate.s.sol \
     * --rpc-url $BASE_RPC_URL \
     * --private-key $PRIVATE_KEY \
     * --broadcast \
     * --legacy \
     * --sig "setIsWhitelistedOnGate(string, address, bool)" \
     * -vvv \
     * -- $GATE_NAME $ACCOUNT $IS_WHITELISTED \
     */
    function setIsWhitelistedOnGate(string memory gateName, address account, bool isWhitelisted) external {
        vm.startBroadcast(privateKey);

        _gate(gateName).setIsWhitelisted(account, isWhitelisted);

        vm.stopBroadcast();
    }

    /**
     * @notice Whitelist a batch of accounts on a single gate
     * @param gateName The gate to target: "receiveAssets", "receiveShares", "sendAssets" or "sendShares"
     * @param accounts The accounts to whitelist
     * @dev $ACCOUNTS and $IS_WHITELISTED should be an array
     *
     * forge script script/interact/base/Whitelist_On_One_Gate.s.sol \
     * --rpc-url $BASE_RPC_URL \
     * --private-key $PRIVATE_KEY \
     * --broadcast \
     * --legacy \
     * --sig "setIsWhitelistedBatchOnGate(string, address[], bool[])" \
     * -vvv \
     * -- $GATE_NAME $ACCOUNTS $IS_WHITELISTED \
     */
    function setIsWhitelistedBatchOnGate(string memory gateName, address[] memory accounts, bool[] memory isWhitelisted)
        external
    {
        vm.startBroadcast(privateKey);

        _gate(gateName).setIsWhitelistedBatch(accounts, isWhitelisted);

        vm.stopBroadcast();
    }
}
