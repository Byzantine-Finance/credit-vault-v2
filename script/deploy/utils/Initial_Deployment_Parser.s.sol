// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC4626MerklAdapterFactory} from "../../../src/adapters/ERC4626MerklAdapterFactory.sol";
import {CompoundV3AdapterFactory} from "../../../src/adapters/CompoundV3AdapterFactory.sol";

import {Script} from "forge-std/Script.sol";
import {Test} from "forge-std/Test.sol";

contract Initial_Deployment_Parser is Script, Test {
    ERC4626MerklAdapterFactory public erc4626MerklAdapterFactory;
    CompoundV3AdapterFactory public compoundV3AdapterFactory;

    function _deployFromScratch() internal {
        erc4626MerklAdapterFactory = new ERC4626MerklAdapterFactory();
        compoundV3AdapterFactory = new CompoundV3AdapterFactory();
    }

    function _logAndOutputContractAddresses(string memory outputPath) internal {
        // WRITE JSON DATA
        string memory parentObject = "parent object";
        string memory deployedAddresses = "addresses";
        string memory chainInfo = "chainInfo";

        vm.serializeAddress(deployedAddresses, "compoundV3AdapterFactory", address(compoundV3AdapterFactory));
        string memory deployedAddressesOutput =
            vm.serializeAddress(deployedAddresses, "erc4626MerklAdapterFactory", address(erc4626MerklAdapterFactory));

        vm.serializeUint(chainInfo, "deploymentBlock", block.number);
        string memory chainInfoOutput = vm.serializeUint(chainInfo, "chainId", block.chainid);

        // serialize all the data
        vm.serializeString(parentObject, deployedAddresses, deployedAddressesOutput);
        string memory finalJson = vm.serializeString(parentObject, chainInfo, chainInfoOutput);

        vm.writeJson(finalJson, outputPath);
    }
}
