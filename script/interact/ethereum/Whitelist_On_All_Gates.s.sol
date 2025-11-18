// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {ReceiveAssetsGate} from "../../../src/gate/ReceiveAssetsGate.sol";
import {ReceiveSharesGate} from "../../../src/gate/ReceiveSharesGate.sol";
import {SendAssetsGate} from "../../../src/gate/SendAssetsGate.sol";
import {SendSharesGate} from "../../../src/gate/SendSharesGate.sol";

contract Whitelist_On_All_Gates is Script {
    // Contracts deployed on Ethereum mainnet
    address constant RECEIVE_ASSETS_GATE = 0x71ED3a2be86cd6A97e0b9625392bda34FDf3341c;
    address constant RECEIVE_SHARES_GATE = 0x5351999cA54675607d08003d9113553162bB795D;
    address constant SEND_ASSETS_GATE = 0x80dc268861Cf57D31c52E8cD0467B3d3024512bc;
    address constant SEND_SHARES_GATE = 0x02B38131Bd473554D2CEd77018c18d030C7CE390;

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
     * forge script script/interact/ethereum/Whitelist_On_All_Gates.s.sol \
     * --rpc-url $MAINNET_RPC_URL \
     * --private-key $PRIVATE_KEY \
     * --sig "setIsWhitelistedOnAllGates(address, bool)"
     * -- $ACCOUNT $IS_WHITELISTED \
     * --broadcast \
     * -vvv
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
     * forge script script/interact/ethereum/Whitelist_On_All_Gates.s.sol \
     * --rpc-url $MAINNET_RPC_URL \
     * --private-key $PRIVATE_KEY \
     * --sig "setIsWhitelistedBatchOnAllGates(address[], bool[])" \
     * -- $ACCOUNTS $IS_WHITELISTED \
     * --broadcast \
     * -vvv
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
     * forge script script/interact/ethereum/Whitelist_On_All_Gates.s.sol \
     * --rpc-url $MAINNET_RPC_URL \
     * --private-key $PRIVATE_KEY \
     * --sig "setIsBundlerAdapterOnAllGates(address, bool)" \
     * -- $ACCOUNT $IS_BUNDLER_ADAPTER \
     * --broadcast \
     * -vvv
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
