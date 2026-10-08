// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ByzantineEurVaultAdapter} from "../../../src/adapters/ByzantineEurVaultAdapter.sol";
import {IByzantineEurVaultAdapterFactory} from "../../../src/adapters/interfaces/IByzantineEurVaultAdapterFactory.sol";
import {IByzantinePrimeEURVault} from "../../../src/interfaces/IByzantinePrimeEURVault.sol";
import {IVaultV2} from "../../../src/interfaces/IVaultV2.sol";

import {Script} from "forge-std/Script.sol";
import {Test} from "forge-std/Test.sol";

/**
 * @notice Script used to deploy a {ByzantineEurVaultAdapter} on Base through the
 *         {ByzantineEurVaultAdapterFactory}.
 *
 * Required environment variables:
 *   PARENT_VAULT    The VaultV2 the adapter is wired to (its asset must be the EUR vault's asset).
 *   EUR_VAULT       The ByzantinePrimeEURVault (bpEUR) the adapter allocates to.
 *
 * Optional environment variables:
 *   ADAPTER_FACTORY The ByzantineEurVaultAdapterFactory to deploy from
 *                   (default: the one in Addresses_Base.json).
 *
 * forge script script/deploy/base/Deploy_Base_ByzantineEurVaultAdapter.s.sol \
 * --rpc-url $BASE_RPC_URL \
 * --private-key $PRIVATE_KEY \
 * --broadcast \
 * --etherscan-api-key $ETHERSCAN_API_KEY \
 * --verify -vv
 *
 * @dev The adapter is deployed by the factory, so if `--verify` does not pick it up, verify it manually:
 *      forge verify-contract <adapter> src/adapters/ByzantineEurVaultAdapter.sol:ByzantineEurVaultAdapter \
 *      --chain base --constructor-args $(cast abi-encode "constructor(address,address)" $PARENT_VAULT $EUR_VAULT)
 */
contract Deploy_Base_ByzantineEurVaultAdapter is Script, Test {
    uint256 internal constant BASE_CHAIN_ID = 8453;

    // ByzantineEurVaultAdapterFactory deployed on Base (see Addresses_Base.json).
    address internal constant DEFAULT_ADAPTER_FACTORY = 0x4c2B9d9a1992C954C8DcC22eae76f5816acc4e7d;

    string internal constant OUTPUT_PATH = "./script/deploy/base/Addresses_ByzantineEurVaultAdapter.json";

    ByzantineEurVaultAdapter public adapter;

    function run() external {
        require(block.chainid == BASE_CHAIN_ID, "not Base");

        address parentVault = vm.envAddress("PARENT_VAULT");
        address eurVault = vm.envAddress("EUR_VAULT");
        IByzantineEurVaultAdapterFactory factory =
            IByzantineEurVaultAdapterFactory(vm.envOr("ADAPTER_FACTORY", DEFAULT_ADAPTER_FACTORY));

        // The factory deploys with a fixed CREATE2 salt: one adapter per (parentVault, eurVault) pair, so a
        // second deployment for the same pair would revert on the create2 collision.
        require(
            factory.byzantineEurVaultAdapter(parentVault, eurVault) == address(0),
            "adapter already deployed for this (parentVault, eurVault) pair"
        );
        // Checked by the adapter constructor too, but fail before spending gas.
        require(IVaultV2(parentVault).asset() == IByzantinePrimeEURVault(eurVault).asset(), "asset mismatch");

        // START RECORDING TRANSACTIONS FOR DEPLOYMENT
        vm.startBroadcast();

        emit log_named_address("Deployer Address", msg.sender);

        adapter = ByzantineEurVaultAdapter(factory.createByzantineEurVaultAdapter(parentVault, eurVault));

        // STOP RECORDING TRANSACTIONS FOR DEPLOYMENT
        vm.stopBroadcast();

        // Sanity check the wiring against the live chain state.
        require(adapter.parentVault() == parentVault, "parentVault mismatch");
        require(adapter.eurVault() == eurVault, "eurVault mismatch");
        require(adapter.factory() == address(factory), "factory mismatch");
        require(factory.isByzantineEurVaultAdapter(address(adapter)), "adapter not registered on the factory");

        _logDeployment(parentVault, eurVault, address(factory));
        _logAndOutputContractAddresses(parentVault, eurVault, address(factory));
    }

    function _logDeployment(address parentVault, address eurVault, address factory) internal {
        emit log_named_address("ByzantineEurVaultAdapterFactory", factory);
        emit log_named_address("ByzantineEurVaultAdapter", address(adapter));
        emit log_named_address("EurVaultPosition implementation", adapter.positionImplementation());
        emit log_named_address("Parent vault", parentVault);
        emit log_named_address("EUR vault", eurVault);
        emit log_named_address("Asset", adapter.asset());
        emit log_named_bytes32("Adapter Id", adapter.adapterId());
        // Cap submissions on the parent vault take the id data, not the id.
        emit log_named_bytes("Adapter Id data", abi.encode("this", address(adapter)));

        emit log("--- NEXT STEPS ---");
        emit log("1. Parent vault curator: addAdapter(adapter), then raise its caps with the id data above.");
        emit log("2. Parent vault curator: setAdapterCurator(...). Parent vault owner: setSkimRecipient(...).");
        emit log("3. Owner of each gate below: setClonerImplementation(adapter, positionImplementation),");
        emit log("   otherwise opening a position reverts with NotTrustedCloner.");

        IByzantinePrimeEURVault v = IByzantinePrimeEURVault(eurVault);
        emit log_named_address("   receiveSharesGate", v.receiveSharesGate());
        emit log_named_address("   sendSharesGate", v.sendSharesGate());
        emit log_named_address("   receiveAssetsGate", v.receiveAssetsGate());
        emit log_named_address("   sendAssetsGate", v.sendAssetsGate());
    }

    function _logAndOutputContractAddresses(address parentVault, address eurVault, address factory) internal {
        // WRITE JSON DATA
        string memory parentObject = "parent object";
        string memory deployedAddresses = "addresses";
        string memory chainInfo = "chainInfo";

        vm.serializeAddress(deployedAddresses, "byzantineEurVaultAdapterFactory", factory);
        vm.serializeAddress(deployedAddresses, "parentVault", parentVault);
        vm.serializeAddress(deployedAddresses, "eurVault", eurVault);
        vm.serializeAddress(deployedAddresses, "positionImplementation", adapter.positionImplementation());
        vm.serializeBytes32(deployedAddresses, "adapterId", adapter.adapterId());
        string memory deployedAddressesOutput =
            vm.serializeAddress(deployedAddresses, "byzantineEurVaultAdapter", address(adapter));

        vm.serializeUint(chainInfo, "deploymentBlock", block.number);
        string memory chainInfoOutput = vm.serializeUint(chainInfo, "chainId", block.chainid);

        // serialize all the data
        vm.serializeString(parentObject, deployedAddresses, deployedAddressesOutput);
        string memory finalJson = vm.serializeString(parentObject, chainInfo, chainInfoOutput);

        vm.writeJson(finalJson, OUTPUT_PATH);
    }
}
