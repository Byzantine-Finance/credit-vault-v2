// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {GateBase} from "../../../src/gate/GateBase.sol";

contract Whitelist_On_One_Gate is Script {
    // Contracts deployed on Ethereum mainnet
    address constant RECEIVE_ASSETS_GATE = 0x71ED3a2be86cd6A97e0b9625392bda34FDf3341c;
    address constant RECEIVE_SHARES_GATE = 0x5351999cA54675607d08003d9113553162bB795D;
    address constant SEND_ASSETS_GATE = 0x80dc268861Cf57D31c52E8cD0467B3d3024512bc;
    address constant SEND_SHARES_GATE = 0x02B38131Bd473554D2CEd77018c18d030C7CE390;

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
     * forge script script/interact/ethereum/Whitelist_On_One_Gate.s.sol \
     * --rpc-url $MAINNET_RPC_URL \
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
     * forge script script/interact/ethereum/Whitelist_On_One_Gate.s.sol \
     * --rpc-url $MAINNET_RPC_URL \
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
