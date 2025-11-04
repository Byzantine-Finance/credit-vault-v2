// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {IVaultV2} from "../../src/interfaces/IVaultV2.sol";
import {ICompoundV3Adapter} from "../../src/adapters/interfaces/ICompoundV3Adapter.sol";
import {IERC4626MerklAdapter} from "../../src/adapters/interfaces/IERC4626MerklAdapter.sol";

/**
 * @notice Script for the vault curator to manage the Debt Fund Vault
 * @dev Only the curator can call the `submit` functions. Once the timelock expires, anyone can call the related
 * `setter`
 * function to execute the transaction.
 */
contract Curator_Management is Script {
    // Private key of the curator
    uint256 public privateKey = uint256(vm.envBytes32("PRIVATE_KEY"));

    // Adapter types to set the claimer for
    enum AdapterWithIncentives {
        COMPOUND_V3,
        ERC4626_MERKL
    }

    /**
     * ************** ADAPTERS SETTINGS **************
     */

    /**
     * @notice Submit the transaction to add the adapter of the vault
     * @param vault The Vault V2
     * @param adapter The address of the adapter
     *
     * forge script script/interact/Curator_Management.s.sol \
     * --sig "submitAddAdapter(address,address)" \
     * --rpc-url $RPC_URL \
     * --private-key $PRIVATE_KEY \
     * --broadcast \
     * -- <vault> <adapter> <isAdapter> \
     * -vvv
     */
    function submitAddAdapter(IVaultV2 vault, address adapter) public {
        vm.startBroadcast(privateKey);

        vault.submit(abi.encodeCall(IVaultV2.addAdapter, (adapter)));

        vm.stopBroadcast();
    }

    /**
     * @notice Add the adapter of the vault
     * @param vault The Vault V2
     * @param adapter The address of the adapter
     *
     * forge script script/interact/Curator_Management.s.sol \
     * --sig "addAdapter(address,address)" \
     * --rpc-url $RPC_URL \
     * --private-key $PRIVATE_KEY \
     * --broadcast \
     * -- <vault> <adapter> \
     * -vvv
     */
    function addAdapter(IVaultV2 vault, address adapter) public {
        vm.startBroadcast(privateKey);

        vault.addAdapter(adapter);

        vm.stopBroadcast();
    }

    /**
     * @notice Submit the transaction to remove the adapter of the vault
     * @param vault The Vault V2
     * @param adapter The address of the adapter
     *
     * forge script script/interact/Curator_Management.s.sol \
     * --sig "submitRemoveAdapter(address,address)" \
     * --rpc-url $RPC_URL \
     * --private-key $PRIVATE_KEY \
     * --broadcast \
     * -- <vault> <adapter> \
     * -vvv
     */
    function submitRemoveAdapter(IVaultV2 vault, address adapter) public {
        vm.startBroadcast(privateKey);

        vault.submit(abi.encodeCall(IVaultV2.removeAdapter, (adapter)));

        vm.stopBroadcast();
    }

    /**
     * @notice Remove the adapter of the vault
     * @param vault The Vault V2
     * @param adapter The address of the adapter
     *
     * forge script script/interact/Curator_Management.s.sol \
     * --sig "removeAdapter(address,address)" \
     * --rpc-url $RPC_URL \
     * --private-key $PRIVATE_KEY \
     * --broadcast \
     * -- <vault> <adapter> \
     * -vvv
     */
    function removeAdapter(IVaultV2 vault, address adapter) public {
        vm.startBroadcast(privateKey);

        vault.removeAdapter(adapter);

        vm.stopBroadcast();
    }

    /**
     * @notice Submit the transaction to increase the absolute cap of the vault
     * @param vault The Vault V2
     * @param adapter The address of the adapter
     * @param newAbsoluteCap The new absolute cap to set
     *
     * forge script script/interact/Curator_Management.s.sol \
     * --sig "submitIncreaseAbsoluteCap(address,address,uint256)" \
     * --rpc-url $RPC_URL \
     * --private-key $PRIVATE_KEY \
     * --broadcast \
     * -- <vault> <adapter> <newAbsoluteCap> \
     * -vvv
     */
    function submitIncreaseAbsoluteCap(IVaultV2 vault, address adapter, uint256 newAbsoluteCap) public {
        bytes memory adapterIdData = abi.encode("this", adapter);

        vm.startBroadcast(privateKey);

        vault.submit(abi.encodeCall(IVaultV2.increaseAbsoluteCap, (adapterIdData, newAbsoluteCap)));

        vm.stopBroadcast();
    }

    /**
     * @notice Increase the absolute cap of the vault
     * @param vault The Vault V2
     * @param adapter The address of the adapter
     * @param newAbsoluteCap The new absolute cap to set
     *
     * forge script script/interact/Curator_Management.s.sol \
     * --sig "increaseAbsoluteCap(address,address,uint256)" \
     * --rpc-url $RPC_URL \
     * --private-key $PRIVATE_KEY \
     * --broadcast \
     * -- <vault> <adapter> <newAbsoluteCap> \
     * -vvv
     */
    function increaseAbsoluteCap(IVaultV2 vault, address adapter, uint256 newAbsoluteCap) public {
        bytes memory adapterIdData = abi.encode("this", adapter);

        vm.startBroadcast(privateKey);

        vault.increaseAbsoluteCap(adapterIdData, newAbsoluteCap);

        vm.stopBroadcast();
    }

    /**
     * @notice Submit the transaction to increase the relative cap of the vault
     * @param vault The Vault V2
     * @param adapter The address of the adapter
     * @param newRelativeCap The new relative cap to set
     * @dev New relative cap should be equal or smaller than 1e18 (100%)
     *
     * forge script script/interact/Curator_Management.s.sol \
     * --sig "submitIncreaseRelativeCap(address,address,uint256)" \
     * --rpc-url $RPC_URL \
     * --private-key $PRIVATE_KEY \
     * --broadcast \
     * -- <vault> <adapter> <newRelativeCap> \
     * -vvv
     */
    function submitIncreaseRelativeCap(IVaultV2 vault, address adapter, uint256 newRelativeCap) public {
        bytes memory adapterIdData = abi.encode("this", adapter);

        vm.startBroadcast(privateKey);

        vault.submit(abi.encodeCall(IVaultV2.increaseRelativeCap, (adapterIdData, newRelativeCap)));

        vm.stopBroadcast();
    }

    /**
     * @notice Increase the relative cap of the vault
     * @param vault The Vault V2
     * @param adapter The address of the adapter
     * @param newRelativeCap The new relative cap to set
     * @dev New relative cap should be equal or smaller than 1e18 (100%)
     *
     * forge script script/interact/Curator_Management.s.sol \
     * --sig "increaseRelativeCap(address,address,uint256)" \
     * --rpc-url $RPC_URL \
     * --private-key $PRIVATE_KEY \
     * --broadcast \
     * -- <vault> <adapter> <newRelativeCap> \
     * -vvv
     */
    function increaseRelativeCap(IVaultV2 vault, address adapter, uint256 newRelativeCap) public {
        bytes memory adapterIdData = abi.encode("this", adapter);

        vm.startBroadcast(privateKey);

        vault.increaseRelativeCap(adapterIdData, newRelativeCap);

        vm.stopBroadcast();
    }

    /**
     * @notice Submit the transaction to decrease the absolute cap of the vault
     * @param vault The Vault V2
     * @param adapter The address of the adapter
     * @param newAbsoluteCap The new absolute cap to set
     * @dev Only the curator and the sentinels can call this function
     *
     * forge script script/interact/Curator_Management.s.sol \
     * --sig "decreaseAbsoluteCap(address,address,uint256)" \
     * --rpc-url $RPC_URL \
     * --private-key $PRIVATE_KEY \
     * --broadcast \
     * -- <vault> <adapter> <newAbsoluteCap> \
     * -vvv
     */
    function decreaseAbsoluteCap(IVaultV2 vault, address adapter, uint256 newAbsoluteCap) public {
        bytes memory adapterIdData = abi.encode("this", adapter);

        vm.startBroadcast(privateKey);

        vault.decreaseAbsoluteCap(adapterIdData, newAbsoluteCap);

        vm.stopBroadcast();
    }

    /**
     * @notice Decrease the relative cap of the vault
     * @param vault The Vault V2
     * @param adapter The address of the adapter
     * @param newRelativeCap The new relative cap to set
     * @dev Only the curator and the sentinels can call this function
     *
     * forge script script/interact/Curator_Management.s.sol \
     * --sig "decreaseRelativeCap(address,address,uint256)" \
     * --rpc-url $RPC_URL \
     * --private-key $PRIVATE_KEY \
     * --broadcast \
     * -- <vault> <adapter> <newRelativeCap> \
     * -vvv
     */
    function decreaseRelativeCap(IVaultV2 vault, address adapter, uint256 newRelativeCap) public {
        bytes memory adapterIdData = abi.encode("this", adapter);

        vm.startBroadcast(privateKey);

        vault.decreaseRelativeCap(adapterIdData, newRelativeCap);

        vm.stopBroadcast();
    }

    /**
     * @notice Submit the transaction to set the force deallocate penalty of the vault
     * @param vault The Vault V2
     * @param adapter The address of the adapter
     * @param newForceDeallocatePenalty The new force deallocate penalty to set
     * @dev New force deallocate penalty cannot be greater than 2% (0.02e18)
     *
     * forge script script/interact/Curator_Management.s.sol \
     * --sig "submitSetForceDeallocatePenalty(address,address,uint256)" \
     * --rpc-url $RPC_URL \
     * --private-key $PRIVATE_KEY \
     * --broadcast \
     * -- <vault> <adapter> <newForceDeallocatePenalty> \
     * -vvv
     */
    function submitSetForceDeallocatePenalty(IVaultV2 vault, address adapter, uint256 newForceDeallocatePenalty)
        public
    {
        vm.startBroadcast(privateKey);

        vault.submit(abi.encodeCall(IVaultV2.setForceDeallocatePenalty, (adapter, newForceDeallocatePenalty)));

        vm.stopBroadcast();
    }

    /**
     * @notice Set the force deallocate penalty of the vault
     * @param vault The Vault V2
     * @param adapter The address of the adapter
     * @param newForceDeallocatePenalty The new force deallocate penalty to set
     * @dev New force deallocate penalty cannot be greater than 2% (0.02e18)
     *
     * forge script script/interact/Curator_Management.s.sol \
     * --sig "setForceDeallocatePenalty(address,address,uint256)" \
     * --rpc-url $RPC_URL \
     * --private-key $PRIVATE_KEY \
     * --broadcast \
     * -- <vault> <adapter> <newForceDeallocatePenalty> \
     * -vvv
     */
    function setForceDeallocatePenalty(IVaultV2 vault, address adapter, uint256 newForceDeallocatePenalty) public {
        vm.startBroadcast(privateKey);

        vault.setForceDeallocatePenalty(adapter, newForceDeallocatePenalty);

        vm.stopBroadcast();
    }

    /**
     * @notice Set the claimer of the adapter
     * @param adapterType The type of the adapter
     * @param adapter The address of the adapter
     * @param claimer The address of the claimer
     * @dev AdapterWithIncentives should be passed as a uint8 (0 for COMPOUND_V3, 1 for ERC4626_MERKL)
     * @dev Only the curator can call this function
     *
     * forge script script/interact/Curator_Management.s.sol \
     * --sig "setClaimer(uint8,address,address)" \
     * --rpc-url $RPC_URL \
     * --private-key $PRIVATE_KEY \
     * --broadcast \
     * -- <adapterType> <adapter> <claimer> \
     * -vvv
     */
    function setClaimer(AdapterWithIncentives adapterType, address adapter, address claimer) public {
        vm.startBroadcast(privateKey);

        if (adapterType == AdapterWithIncentives.COMPOUND_V3) {
            ICompoundV3Adapter(adapter).setClaimer(claimer);
        } else if (adapterType == AdapterWithIncentives.ERC4626_MERKL) {
            IERC4626MerklAdapter(adapter).setClaimer(claimer);
        } else {
            revert("Invalid adapter type");
        }

        vm.stopBroadcast();
    }

    /**
     * ************** ADDRESSES SETTINGS **************
     */

    /**
     * @notice Submit the transaction to set the allocator of the vault
     * @param vault The Vault V2
     * @param allocator The address of the allocator
     * @param isAllocator The boolean value to set the allocator
     *
     * forge script script/interact/Curator_Management.s.sol \
     * --sig "submitSetIsAllocator(address,address,bool)" \
     * --rpc-url $RPC_URL \
     * --private-key $PRIVATE_KEY \
     * --broadcast \
     * -- <vault> <allocator> <isAllocator> \
     * -vvv
     */
    function submitSetIsAllocator(IVaultV2 vault, address allocator, bool isAllocator) public {
        vm.startBroadcast(privateKey);

        vault.submit(abi.encodeCall(IVaultV2.setIsAllocator, (allocator, isAllocator)));

        vm.stopBroadcast();
    }

    /**
     * @notice Set the allocator of the vault
     * @param vault The Vault V2
     * @param allocator The address of the allocator
     * @param isAllocator The boolean value to set the allocator
     *
     * forge script script/interact/Curator_Management.s.s\
     * --sig "setIsAllocator(address,address,bool)" \
     * --rpc-url $RPC_URL \
     * --private-key $PRIVATE_KEY \
     * --broadcast \
     * -- <vault> <allocator> <isAllocator> \
     * -vvv
     */
    function setIsAllocator(IVaultV2 vault, address allocator, bool isAllocator) public {
        vm.startBroadcast(privateKey);

        vault.setIsAllocator(allocator, isAllocator);

        vm.stopBroadcast();
    }

    /**
     * @notice Submit the transaction to set the receive shares gate of the vault
     * @param vault The Vault V2
     * @param newReceiveSharesGate The address of the new receive shares gate
     *
     * forge script script/interact/Curator_Management.s.sol \
     * --sig "submitSetReceiveSharesGate(address,address)" \
     * --rpc-url $RPC_URL \
     * --private-key $PRIVATE_KEY \
     * --broadcast \
     * -- <vault> <newReceiveSharesGate> \
     * -vvv
     */
    function submitSetReceiveSharesGate(IVaultV2 vault, address newReceiveSharesGate) public {
        vm.startBroadcast(privateKey);

        vault.submit(abi.encodeCall(IVaultV2.setReceiveSharesGate, (newReceiveSharesGate)));

        vm.stopBroadcast();
    }

    /**
     * @notice Set the receive shares gate of the vault
     * @param vault The Vault V2
     * @param newReceiveSharesGate The address of the new receive shares gate
     *
     * forge script script/interact/Curator_Management.s.sol \
     * --sig "setReceiveSharesGate(address,address)" \
     * --rpc-url $RPC_URL \
     * --private-key $PRIVATE_KEY \
     * --broadcast \
     * -- <vault> <newReceiveSharesGate> \
     * -vvv
     */
    function setReceiveSharesGate(IVaultV2 vault, address newReceiveSharesGate) public {
        vm.startBroadcast(privateKey);

        vault.setReceiveSharesGate(newReceiveSharesGate);

        vm.stopBroadcast();
    }

    /**
     * @notice Submit the transaction to set the send shares gate of the vault
     * @param vault The Vault V2
     * @param newSendSharesGate The address of the new send shares gate
     *
     * forge script script/interact/Curator_Management.s.sol \
     * --sig "submitSetSendSharesGate(address,address)" \
     * --rpc-url $RPC_URL \
     * --private-key $PRIVATE_KEY \
     * --broadcast \
     * -- <vault> <newSendSharesGate> \
     * -vvv
     */
    function submitSetSendSharesGate(IVaultV2 vault, address newSendSharesGate) public {
        vm.startBroadcast(privateKey);

        vault.submit(abi.encodeCall(IVaultV2.setSendSharesGate, (newSendSharesGate)));

        vm.stopBroadcast();
    }

    /**
     * @notice Set the send shares gate of the vault
     * @param vault The Vault V2
     * @param newSendSharesGate The address of the new send shares gate
     *
     * forge script script/interact/Curator_Management.s.sol \
     * --sig "setSendSharesGate(address,address)" \
     * --rpc-url $RPC_URL \
     * --private-key $PRIVATE_KEY \
     * --broadcast \
     * -- <vault> <newSendSharesGate> \
     * -vvv
     */
    function setSendSharesGate(IVaultV2 vault, address newSendSharesGate) public {
        vm.startBroadcast(privateKey);

        vault.setSendSharesGate(newSendSharesGate);

        vm.stopBroadcast();
    }

    /**
     * @notice Submit the transaction to set the receive assets gate of the vault
     * @param vault The Vault V2
     * @param newReceiveAssetsGate The address of the new receive assets gate
     *
     * forge script script/interact/Curator_Management.s.sol \
     * --sig "submitSetReceiveAssetsGate(address,address)" \
     * --rpc-url $RPC_URL \
     * --private-key $PRIVATE_KEY \
     * --broadcast \
     * -- <vault> <newReceiveAssetsGate> \
     * -vvv
     */
    function submitSetReceiveAssetsGate(IVaultV2 vault, address newReceiveAssetsGate) public {
        vm.startBroadcast(privateKey);

        vault.submit(abi.encodeCall(IVaultV2.setReceiveAssetsGate, (newReceiveAssetsGate)));

        vm.stopBroadcast();
    }

    /**
     * @notice Set the receive assets gate of the vault
     * @param vault The Vault V2
     * @param newReceiveAssetsGate The address of the new receive assets gate
     *
     * forge script script/interact/Curator_Management.s.sol \
     * --sig "setReceiveAssetsGate(address,address)" \
     * --rpc-url $RPC_URL \
     * --private-key $PRIVATE_KEY \
     * --broadcast \
     * -- <vault> <newReceiveAssetsGate> \
     * -vvv
     */
    function setReceiveAssetsGate(IVaultV2 vault, address newReceiveAssetsGate) public {
        vm.startBroadcast(privateKey);

        vault.setReceiveAssetsGate(newReceiveAssetsGate);

        vm.stopBroadcast();
    }

    /**
     * @notice Submit the transaction to set the send assets gate of the vault
     * @param vault The Vault V2
     * @param newSendAssetsGate The address of the new send assets gate
     *
     * forge script script/interact/Curator_Management.s.sol \
     * --sig "submitSetSendAssetsGate(address,address)" \
     * --rpc-url $RPC_URL \
     * --private-key $PRIVATE_KEY \
     * --broadcast \
     * -- <vault> <newSendAssetsGate> \
     * -vvv
     */
    function submitSetSendAssetsGate(IVaultV2 vault, address newSendAssetsGate) public {
        vm.startBroadcast(privateKey);

        vault.submit(abi.encodeCall(IVaultV2.setSendAssetsGate, (newSendAssetsGate)));

        vm.stopBroadcast();
    }

    /**
     * @notice Set the send assets gate of the vault
     * @param vault The Vault V2
     * @param newSendAssetsGate The address of the new send assets gate
     *
     * forge script script/interact/Curator_Management.s.sol \
     * --sig "setSendAssetsGate(address,address)" \
     * --rpc-url $RPC_URL \
     * --private-key $PRIVATE_KEY \
     * --broadcast \
     * -- <vault> <newSendAssetsGate> \
     * -vvv
     */
    function setSendAssetsGate(IVaultV2 vault, address newSendAssetsGate) public {
        vm.startBroadcast(privateKey);

        vault.setSendAssetsGate(newSendAssetsGate);

        vm.stopBroadcast();
    }

    /**
     * @notice Submit the transaction to set the adapter registry of the vault
     * @param vault The Vault V2
     * @param newAdapterRegistry The address of the new adapter registry
     *
     * forge script script/interact/Curator_Management.s.sol \
     * --sig "submitSetAdapterRegistry(address,address)" \
     * --rpc-url $RPC_URL \
     * --private-key $PRIVATE_KEY \
     * --broadcast \
     * -- <vault> <newAdapterRegistry> \
     * -vvv
     */
    function submitSetAdapterRegistry(IVaultV2 vault, address newAdapterRegistry) public {
        vm.startBroadcast(privateKey);

        vault.submit(abi.encodeCall(IVaultV2.setAdapterRegistry, (newAdapterRegistry)));

        vm.stopBroadcast();
    }

    /**
     * @notice Set the adapter registry of the vault
     * @param vault The Vault V2
     * @param newAdapterRegistry The address of the new adapter registry
     *
     * forge script script/interact/Curator_Management.s.sol \
     * --sig "setAdapterRegistry(address,address)" \
     * --rpc-url $RPC_URL \
     * --private-key $PRIVATE_KEY \
     * --broadcast \
     * -- <vault> <newAdapterRegistry> \
     * -vvv
     */
    function setAdapterRegistry(IVaultV2 vault, address newAdapterRegistry) public {
        vm.startBroadcast(privateKey);

        vault.setAdapterRegistry(newAdapterRegistry);

        vm.stopBroadcast();
    }

    /**
     * ************** FEES SETTINGS **************
     */

    /**
     * @notice Submit the transaction to set the performance fee recipient of the vault
     * @param vault The Vault V2
     * @param newPerformanceFeeRecipient The new performance fee recipient to set
     *
     * forge script script/interact/Curator_Management.s.sol \
     * --sig "submitSetPerformanceFeeRecipient(address,address)" \
     * --rpc-url $RPC_URL \
     * --private-key $PRIVATE_KEY \
     * --broadcast \
     * -- <vault> <newPerformanceFeeRecipient> \
     * -vvv
     */
    function submitSetPerformanceFeeRecipient(IVaultV2 vault, address newPerformanceFeeRecipient) public {
        vm.startBroadcast(privateKey);

        vault.submit(abi.encodeCall(IVaultV2.setPerformanceFeeRecipient, (newPerformanceFeeRecipient)));

        vm.stopBroadcast();
    }

    /**
     * @notice Set the performance fee recipient of the vault
     * @param vault The Vault V2
     * @param newPerformanceFeeRecipient The new performance fee recipient to set
     *
     * forge script script/interact/Curator_Management.s.sol \
     * --sig "setPerformanceFeeRecipient(address,address)" \
     * --rpc-url $RPC_URL \
     * --private-key $PRIVATE_KEY \
     * --broadcast \
     * -- <vault> <newPerformanceFeeRecipient> \
     * -vvv
     */
    function setPerformanceFeeRecipient(IVaultV2 vault, address newPerformanceFeeRecipient) public {
        vm.startBroadcast(privateKey);

        vault.setPerformanceFeeRecipient(newPerformanceFeeRecipient);

        vm.stopBroadcast();
    }

    /**
     * @notice Submit the transaction to set the management fee recipient of the vault
     * @param vault The Vault V2
     * @param newManagementFeeRecipient The new management fee recipient to set
     *
     * forge script script/interact/Curator_Management.s.sol \
     * --sig "submitSetManagementFeeRecipient(address,address)" \
     * --rpc-url $RPC_URL \
     * --private-key $PRIVATE_KEY \
     * --broadcast \
     * -- <vault> <newManagementFeeRecipient> \
     * -vvv
     */
    function submitSetManagementFeeRecipient(IVaultV2 vault, address newManagementFeeRecipient) public {
        vm.startBroadcast(privateKey);

        vault.submit(abi.encodeCall(IVaultV2.setManagementFeeRecipient, (newManagementFeeRecipient)));

        vm.stopBroadcast();
    }

    /**
     * @notice Set the management fee recipient of the vault
     * @param vault The Vault V2
     * @param newManagementFeeRecipient The new management fee recipient to set
     *
     * forge script script/interact/Curator_Management.s.sol \
     * --sig "setManagementFeeRecipient(address,address)" \
     * --rpc-url $RPC_URL \
     * --private-key $PRIVATE_KEY \
     * --broadcast \
     * -- <vault> <newManagementFeeRecipient> \
     * -vvv
     */
    function setManagementFeeRecipient(IVaultV2 vault, address newManagementFeeRecipient) public {
        vm.startBroadcast(privateKey);

        vault.setManagementFeeRecipient(newManagementFeeRecipient);

        vm.stopBroadcast();
    }

    /**
     * @notice Submit the transaction to set the performance fee of the vault
     * @param vault The Vault V2
     * @param newPerformanceFee The new performance fee to set
     * @dev When setting a performance fee, performanceFeeRecipient must have been set
     * @dev New performance fee cannot be greater than 50% (0.5e18)
     *
     * forge script script/interact/Curator_Management.s.sol \
     * --sig "submitSetPerformanceFee(address,uint256)" \
     * --rpc-url $RPC_URL \
     * --private-key $PRIVATE_KEY \
     * --broadcast \
     * -- <vault> <newPerformanceFee> \
     * -vvv
     */
    function submitSetPerformanceFee(IVaultV2 vault, uint256 newPerformanceFee) public {
        vm.startBroadcast(privateKey);

        vault.submit(abi.encodeCall(IVaultV2.setPerformanceFee, (newPerformanceFee)));

        vm.stopBroadcast();
    }

    /**
     * @notice Set the performance fee of the vault
     * @param vault The Vault V2
     * @param newPerformanceFee The new performance fee to set
     * @dev When setting a performance fee, performanceFeeRecipient must have been set
     * @dev New performance fee cannot be greater than 50% (0.5e18)
     *
     * forge script script/interact/Curator_Management.s.sol \
     * --sig "setPerformanceFee(address,uint256)" \
     * --rpc-url $RPC_URL \
     * --private-key $PRIVATE_KEY \
     * --broadcast \
     * -- <vault> <newPerformanceFee> \
     * -vvv
     */
    function setPerformanceFee(IVaultV2 vault, uint256 newPerformanceFee) public {
        vm.startBroadcast(privateKey);

        vault.setPerformanceFee(newPerformanceFee);

        vm.stopBroadcast();
    }

    /**
     * @notice Submit the transaction to set the management fee of the vault
     * @param vault The Vault V2
     * @param newManagementFee The new management fee to set
     * @dev New management fee cannot be greater than 5% (0.05e18 / 365 days)
     * @dev When setting a management fee, managementFeeRecipient must have been set
     *
     * forge script script/interact/Curator_Management.s.sol \
     * --sig "submitSetManagementFee(address,uint256)" \
     * --rpc-url $RPC_URL \
     * --private-key $PRIVATE_KEY \
     * --broadcast \
     * -- <vault> <newManagementFee> \
     * -vvv
     */
    function submitSetManagementFee(IVaultV2 vault, uint256 newManagementFee) public {
        vm.startBroadcast(privateKey);

        vault.submit(abi.encodeCall(IVaultV2.setManagementFee, (newManagementFee)));

        vm.stopBroadcast();
    }

    /**
     * @notice Set the management fee of the vault
     * @param vault The Vault V2
     * @param newManagementFee The new management fee to set
     * @dev New management fee cannot be greater than 5% (0.05e18 / 365 days)
     * @dev When setting a management fee, managementFeeRecipient must have been set
     *
     * forge script script/interact/Curator_Management.s.sol \
     * --sig "setManagementFee(address,uint256)" \
     * --rpc-url $RPC_URL \
     * --private-key $PRIVATE_KEY \
     * --broadcast \
     * -- <vault> <newManagementFee> \
     * -vvv
     */
    function setManagementFee(IVaultV2 vault, uint256 newManagementFee) public {
        vm.startBroadcast(privateKey);

        vault.setManagementFee(newManagementFee);

        vm.stopBroadcast();
    }

    /**
     * ************** TIMELOCKS SETTINGS **************
     */

    /**
     * @notice Submit the transaction to increase the timelock of the vault
     * @param vault The Vault V2
     * @param functionSignature The selector of the function to increase the timelock
     * @param newDuration The new duration to set
     *
     * forge script script/interact/Curator_Management.s.sol \
     * --sig "submitIncreaseTimelock(address,bytes4,uint256)" \
     * --rpc-url $RPC_URL \
     * --private-key $PRIVATE_KEY \
     * --broadcast \
     * -- <vault> <functionSignature> <newDuration> \
     * -vvv
     */
    function submitIncreaseTimelock(IVaultV2 vault, bytes4 functionSignature, uint256 newDuration) public {
        vm.startBroadcast(privateKey);

        vault.submit(abi.encodeCall(IVaultV2.increaseTimelock, (functionSignature, newDuration)));

        vm.stopBroadcast();
    }

    /**
     * @notice Increase the timelock of the vault
     * @param vault The Vault V2
     * @param functionSignature The selector of the function to increase the timelock
     * @param newDuration The new duration to set
     *
     * forge script script/interact/Curator_Management.s.sol \
     * --sig "increaseTimelock(address,bytes4,uint256)" \
     * --rpc-url $RPC_URL \
     * --private-key $PRIVATE_KEY \
     * --broadcast \
     * -- <vault> <functionSignature> <newDuration> \
     * -vvv
     */
    function increaseTimelock(IVaultV2 vault, bytes4 functionSignature, uint256 newDuration) public {
        vm.startBroadcast(privateKey);

        vault.increaseTimelock(functionSignature, newDuration);

        vm.stopBroadcast();
    }

    /**
     * @notice Submit the transaction to decrease the timelock of the vault
     * @param vault The Vault V2
     * @param functionSignature The selector of the function to decrease the timelock
     * @param newDuration The new duration to set
     *
     * forge script script/interact/Curator_Management.s.sol \
     * --sig "submitDecreaseTimelock(address,bytes4,uint256)" \
     * --rpc-url $RPC_URL \
     * --private-key $PRIVATE_KEY \
     * --broadcast \
     * -- <vault> <functionSignature> <newDuration> \
     * -vvv
     */
    function submitDecreaseTimelock(IVaultV2 vault, bytes4 functionSignature, uint256 newDuration) public {
        vm.startBroadcast(privateKey);

        vault.submit(abi.encodeCall(IVaultV2.decreaseTimelock, (functionSignature, newDuration)));

        vm.stopBroadcast();
    }

    /**
     * @notice Decrease the timelock of the vault
     * @param vault The Vault V2
     * @param functionSignature The selector of the function to decrease the timelock
     * @param newDuration The new duration to set
     *
     * forge script script/interact/Curator_Management.s.sol \
     * --sig "decreaseTimelock(address,bytes4,uint256)" \
     * --rpc-url $RPC_URL \
     * --private-key $PRIVATE_KEY \
     * --broadcast \
     * -- <vault> <functionSignature> <newDuration> \
     * -vvv
     */
    function decreaseTimelock(IVaultV2 vault, bytes4 functionSignature, uint256 newDuration) public {
        vm.startBroadcast(privateKey);

        vault.decreaseTimelock(functionSignature, newDuration);

        vm.stopBroadcast();
    }

    /**
     * @notice Revoke the transaction to submit for a selector
     * @param vault The Vault V2
     * @param data The encoded data that was submitted
     * @dev Only the curator and the sentinels can call this function
     *
     * forge script script/interact/Curator_Management.s.sol \
     * --sig "revoke(address,bytes)" \
     * --rpc-url $RPC_URL \
     * --private-key $PRIVATE_KEY \
     * --broadcast \
     * -- <vault> <data> \
     * -vvv
     */
    function revoke(IVaultV2 vault, bytes memory data) public {
        vm.startBroadcast(privateKey);

        vault.revoke(data);

        vm.stopBroadcast();
    }
}
