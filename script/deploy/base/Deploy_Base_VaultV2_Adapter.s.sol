// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../utils/Vault_Adapter_Deployment_Parser.s.sol";

/**
 * @notice Script used for the deployment of a VaultV2
 *
 * forge script script/deploy/base/Deploy_Base_VaultV2_Adapter.s.sol \
 * --sig "deployVaultV2(address)" \
 * --rpc-url $BASE_RPC_URL \
 * --private-key $PRIVATE_KEY \
 * --broadcast \
 * -- <_vaultOwner> \
 * -vvv
 */
contract Deploy_Base_VaultV2_Adapter is Vault_Adapter_Deployment_Parser {
    function deployVaultV2(address _vaultOwner) public {
        // Load factory addresses
        _loadFactoryAddresses(path);

        bytes32 salt = bytes32(block.timestamp);

        // START RECORDING TRANSACTIONS FOR DEPLOYMENT
        vm.startBroadcast(privateKey);

        // Deploy Vault
        vault = IVaultV2(vaultV2Factory.createVaultV2(_vaultOwner, USDC, salt));

        // STOP RECORDING TRANSACTIONS FOR DEPLOYMENT
        vm.stopBroadcast();

        _logAndOutputVaultV2ContractAddresses("./script/deploy/base/Addresses_Base_VaultV2.json");
    }

    /**
     * @notice Script used for the deployment of a Adapter
     *
     * forge script script/deploy/base/Deploy_Base_VaultV2_Adapter.s.sol \
     * --sig "deployAdapter(address,address,uint8)" \
     * --rpc-url $BASE_RPC_URL \
     * --private-key $PRIVATE_KEY \
     * --broadcast \
     * -- <_vault> <_underlyingVault> <_adapterType> \
     * -vvv
     */
    function deployAdapter(address _vault, address _underlyingVault, AdapterType _adapterType) public {
        // Load factory addresses
        _loadFactoryAddresses(path);

        // START RECORDING TRANSACTIONS FOR DEPLOYMENT
        vm.startBroadcast(privateKey);

        // Deploy Adapter
        if (_adapterType == AdapterType.COMPOUND_V3) {
            compoundV3Adapter =
                ICompoundV3Adapter(compoundV3AdapterFactory.createCompoundV3Adapter(_vault, COMET, COMET_REWARDS));
            adapter = address(compoundV3Adapter);
        } else if (_adapterType == AdapterType.ERC4626_MERKL) {
            erc4626MerklAdapter =
                IERC4626MerklAdapter(erc4626MerklAdapterFactory.createERC4626MerklAdapter(_vault, _underlyingVault));
            adapter = address(erc4626MerklAdapter);
        } else if (_adapterType == AdapterType.ERC4626) {
            erc4626Adapter =
                IMorphoVaultV1Adapter(erc4626AdapterFactory.createMorphoVaultV1Adapter(_vault, _underlyingVault));
            adapter = address(erc4626Adapter);
        } else {
            morphoMarketV1Adapter =
                IMorphoMarketV1Adapter(morphoMarketV1AdapterFactory.createMorphoMarketV1Adapter(_vault, _underlyingVault));
            adapter = address(morphoMarketV1Adapter);
        }

        // STOP RECORDING TRANSACTIONS FOR DEPLOYMENT
        vm.stopBroadcast();

        vault = IVaultV2(_vault);
        adapterType = _adapterType;

        _logAndOutputAdapterContractAddresses("./script/deploy/base/Addresses_Base_Adapter.json");
    }
}
