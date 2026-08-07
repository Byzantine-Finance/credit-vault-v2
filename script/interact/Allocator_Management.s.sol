// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {IVaultV2} from "../../src/interfaces/IVaultV2.sol";
import {ICompoundV3Adapter} from "../../src/adapters/interfaces/ICompoundV3Adapter.sol";
import "../../src/libraries/ConstantsLib.sol";

/**
 * @notice Script for vault allocators to manage the Debt Fund Vault
 * @dev Unless specified otherwise, only the allocators can call the functions
 */
contract Allocator_Management is Script {
    // Private key of the allocator
    uint256 public privateKey = uint256(vm.envBytes32("PRIVATE_KEY"));

    /**
     * @notice Set the max rate of the vault
     * @param vault The Vault V2
     * @param maxRate The max rate to set
     * @dev Max rate cannot be greater than 200% APR (200e16 / 365 days)
     *
     * forge script script/interact/Allocator_Management.s.sol \
     * --sig "setMaxRate(address,uint256)" \
     * --rpc-url $RPC_URL \
     * --private-key $PRIVATE_KEY \
     * --broadcast \
     * -- <vault> <maxRate> \
     * -vvv
     */
    function setMaxRate(IVaultV2 vault, uint256 maxRate) public {
        vm.startBroadcast(privateKey);

        vault.setMaxRate(maxRate);

        vm.stopBroadcast();
    }

    /**
     * @notice Set the liquidity adapter and data of the vault
     * @param vault The Vault V2
     * @param newLiquidityAdapter The address of the new liquidity adapter
     * @param newLiquidityData The data of the new liquidity adapter
     *
     * forge script script/interact/Allocator_Management.s.sol \
     * --sig "setLiquidityAdapterAndData(address,address,bytes)" \
     * --rpc-url $RPC_URL \
     * --private-key $PRIVATE_KEY \
     * --broadcast \
     * -- <vault> <newLiquidityAdapter> <newLiquidityData> \
     * -vvv
     */
    function setLiquidityAdapterAndData(IVaultV2 vault, address newLiquidityAdapter, bytes memory newLiquidityData)
        public
    {
        vm.startBroadcast(privateKey);
        vault.setLiquidityAdapterAndData(newLiquidityAdapter, newLiquidityData);
        vm.stopBroadcast();
    }

    /**
     * @notice Allocate assets to the vault
     * @param vault The Vault V2
     * @param adapter The address of the adapter
     * @param data The data of the adapter
     * @param assets The amount of assets to allocate
     *
     * forge script script/interact/Allocator_Management.s.sol \
     * --sig "allocate(address,bytes,uint256)" \
     * --rpc-url $RPC_URL \
     * --private-key $PRIVATE_KEY \
     * --broadcast \
     * -- <vault> <adapter> <data> <assets> \
     * -vvv
     */
    function allocate(IVaultV2 vault, address adapter, bytes memory data, uint256 assets) public {
        vm.startBroadcast(privateKey);
        vault.allocate(adapter, data, assets);
        vm.stopBroadcast();
    }

    /**
     * @notice Deallocate assets from the vault
     * @param vault The Vault V2
     * @param adapter The address of the adapter
     * @param data The data of the adapter
     * @param assets The amount of assets to deallocate
     * @dev Only the allocators and the sentinels can call this function
     *
     * forge script script/interact/Allocator_Management.s.sol \
     * --sig "deallocate(address,bytes,uint256)" \
     * --rpc-url $RPC_URL \
     * --private-key $PRIVATE_KEY \
     * --broadcast \
     * -- <vault> <adapter> <data> <assets> \
     * -vvv
     */
    function deallocate(IVaultV2 vault, address adapter, bytes memory data, uint256 assets) public {
        vm.startBroadcast(privateKey);
        vault.deallocate(adapter, data, assets);
        vm.stopBroadcast();
    }
}
