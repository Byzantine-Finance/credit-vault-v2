// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {VaultV2Factory} from "../../../src/VaultV2Factory.sol";
import {MorphoMarketV1AdapterV2Factory} from "../../../src/adapters/MorphoMarketV1AdapterV2Factory.sol";
import {MorphoVaultV1AdapterFactory} from "../../../src/adapters/MorphoVaultV1AdapterFactory.sol";
import {ERC4626MerklAdapterFactory} from "../../../src/adapters/ERC4626MerklAdapterFactory.sol";
import {CompoundV3AdapterFactory} from "../../../src/adapters/CompoundV3AdapterFactory.sol";

import "forge-std/Script.sol";
import "forge-std/Test.sol";

contract Initial_Deployment_Parser is Script, Test {
    // Factories
    // VaultV2Factory public vaultV2Factory;
    // MorphoMarketV1AdapterV2Factory public morphoMarketV1AdapterV2Factory;
    // MorphoVaultV1AdapterFactory public erc4626AdapterFactory;
    ERC4626MerklAdapterFactory public erc4626MerklAdapterFactory;
    CompoundV3AdapterFactory public compoundV3AdapterFactory;

    function _deployFromScratch() internal {
        // Deploy Factories
        // vaultV2Factory = new VaultV2Factory();
        // morphoMarketV1AdapterV2Factory = new MorphoMarketV1AdapterV2Factory();
        // erc4626AdapterFactory = new MorphoVaultV1AdapterFactory();
        erc4626MerklAdapterFactory = new ERC4626MerklAdapterFactory();
        compoundV3AdapterFactory = new CompoundV3AdapterFactory();
    }

    function _logAndOutputContractAddresses(string memory outputPath) internal {
        // WRITE JSON DATA
        string memory parent_object = "parent object";
        string memory deployed_addresses = "addresses";
        string memory chain_info = "chainInfo";

        // vm.serializeAddress(deployed_addresses, "vaultV2Factory", address(vaultV2Factory));
        vm.serializeAddress(deployed_addresses, "compoundV3AdapterFactory", address(compoundV3AdapterFactory));
        // vm.serializeAddress(deployed_addresses, "morphoMarketV1AdapterV2Factory",
        // address(morphoMarketV1AdapterV2Factory));
        // vm.serializeAddress(deployed_addresses, "erc4626AdapterFactory", address(erc4626AdapterFactory));
        string memory deployed_addresses_output =
            vm.serializeAddress(deployed_addresses, "erc4626MerklAdapterFactory", address(erc4626MerklAdapterFactory));

        vm.serializeUint(chain_info, "deploymentBlock", block.number);
        string memory chain_info_output = vm.serializeUint(chain_info, "chainId", block.chainid);

        // serialize all the data
        vm.serializeString(parent_object, deployed_addresses, deployed_addresses_output);
        string memory finalJson = vm.serializeString(parent_object, chain_info, chain_info_output);

        vm.writeJson(finalJson, outputPath);
    }
}
