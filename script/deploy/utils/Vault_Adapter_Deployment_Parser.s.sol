// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/Test.sol";

import {ICompoundV3AdapterFactory} from "../../../src/adapters/interfaces/ICompoundV3AdapterFactory.sol";
import {IVaultV2Factory} from "../../../src/interfaces/IVaultV2Factory.sol";
import {IVaultV2} from "../../../src/interfaces/IVaultV2.sol";
import {ICompoundV3Adapter} from "../../../src/adapters/interfaces/ICompoundV3Adapter.sol";
import {IERC4626MerklAdapterFactory} from "../../../src/adapters/interfaces/IERC4626MerklAdapterFactory.sol";
import {IERC4626MerklAdapter} from "../../../src/adapters/interfaces/IERC4626MerklAdapter.sol";
import {IMorphoMarketV1AdapterFactory} from "../../../src/adapters/interfaces/IMorphoMarketV1AdapterFactory.sol";
import {IMorphoMarketV1Adapter} from "../../../src/adapters/interfaces/IMorphoMarketV1Adapter.sol";
import {IMorphoVaultV1AdapterFactory} from "../../../src/adapters/interfaces/IMorphoVaultV1AdapterFactory.sol";
import {IMorphoVaultV1Adapter} from "../../../src/adapters/interfaces/IMorphoVaultV1Adapter.sol";

contract Vault_Adapter_Deployment_Parser is Script, Test {
    // Token Addresses on Base Mainnet
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    // Contract Addresses on Base Mainnet
    address constant COMET = 0xb125E6687d4313864e53df431d5425969c15Eb2F;
    address constant COMET_REWARDS = 0x123964802e6ABabBE1Bc9547D72Ef1B69B00A6b1;

    // Contracts
    IVaultV2Factory public vaultV2Factory;
    IVaultV2 public vault;
    ICompoundV3AdapterFactory public compoundV3AdapterFactory;
    ICompoundV3Adapter public compoundV3Adapter;
    IERC4626MerklAdapterFactory public erc4626MerklAdapterFactory;
    IERC4626MerklAdapter public erc4626MerklAdapter;
    IMorphoMarketV1AdapterFactory public morphoMarketV1AdapterFactory;
    IMorphoMarketV1Adapter public morphoMarketV1Adapter;
    IMorphoVaultV1AdapterFactory public erc4626AdapterFactory;
    IMorphoVaultV1Adapter public erc4626Adapter;

    // Adapter type
    enum AdapterType {
        COMPOUND_V3,
        ERC4626_MERKL,
        ERC4626,
        MORPHO_MARKET_V1
    }

    // For output
    address public adapter;
    AdapterType public adapterType;

    // Load addresses from file
    string internal root = vm.projectRoot();
    string internal path = string.concat(root, "/script/deploy/base/Addresses_Base.json");

    // Fetch Deployer private key
    uint256 public privateKey = uint256(vm.envBytes32("PRIVATE_KEY"));

    function _loadFactoryAddresses(string memory loadPath) internal {
        string memory json = vm.readFile(loadPath);

        vaultV2Factory = IVaultV2Factory(stdJson.readAddress(json, ".addresses.vaultV2Factory"));
        compoundV3AdapterFactory =
            ICompoundV3AdapterFactory(stdJson.readAddress(json, ".addresses.compoundV3AdapterFactory"));
        erc4626MerklAdapterFactory =
            IERC4626MerklAdapterFactory(stdJson.readAddress(json, ".addresses.erc4626MerklAdapterFactory"));
        morphoMarketV1AdapterFactory =
            IMorphoMarketV1AdapterFactory(stdJson.readAddress(json, ".addresses.morphoMarketV1AdapterFactory"));
        erc4626AdapterFactory =
            IMorphoVaultV1AdapterFactory(stdJson.readAddress(json, ".addresses.erc4626AdapterFactory"));
    }

    function _logAndOutputVaultV2ContractAddresses(string memory outputPath) internal {
        // WRITE JSON DATA
        string memory parent_object = "parent object";
        string memory deployed_addresses = "addresses";
        string memory chain_info = "chainInfo";

        string memory deployed_addresses_output = vm.serializeAddress(deployed_addresses, "vault", address(vault));

        vm.serializeUint(chain_info, "deploymentBlock", block.number);
        string memory chain_info_output = vm.serializeUint(chain_info, "chainId", block.chainid);

        // serialize all the data
        vm.serializeString(parent_object, deployed_addresses, deployed_addresses_output);
        string memory finalJson = vm.serializeString(parent_object, chain_info, chain_info_output);

        vm.writeJson(finalJson, outputPath);
    }

    function _logAndOutputAdapterContractAddresses(string memory outputPath) internal {
        // WRITE JSON DATA
        string memory parent_object = "parent object";
        string memory deployed_addresses = "addresses";
        string memory chain_info = "chainInfo";

        vm.serializeAddress(deployed_addresses, "vault", address(vault));
        vm.serializeUint(deployed_addresses, "adapterType", uint8(adapterType));
        string memory deployed_addresses_output = vm.serializeAddress(deployed_addresses, "adapter", adapter);

        vm.serializeUint(chain_info, "deploymentBlock", block.number);
        string memory chain_info_output = vm.serializeUint(chain_info, "chainId", block.chainid);

        // serialize all the data
        vm.serializeString(parent_object, deployed_addresses, deployed_addresses_output);
        string memory finalJson = vm.serializeString(parent_object, chain_info, chain_info_output);

        vm.writeJson(finalJson, outputPath);
    }
}
