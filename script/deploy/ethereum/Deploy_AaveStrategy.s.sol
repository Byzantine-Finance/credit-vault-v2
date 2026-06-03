// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AaveStrategy} from "../../../src/adapters/AaveStrategy.sol";
import {IMYTStrategy} from "../../../src/adapters/interfaces/IMYTStrategy.sol";

import {Script} from "forge-std/Script.sol";
import {Test} from "forge-std/Test.sol";

/**
 * @notice Script used to deploy an {AaveStrategy} adapter on Ethereum mainnet.
 *
 * Required environment variables:
 *   VAULT                   The VaultV2 the adapter is wired to.
 *   STRATEGY_OWNER          Owner of the strategy (admin functions, kill switch).
 *
 * Optional environment variables (default to the Aave v3 EURC mainnet market):
 *   MYT_ASSET               Underlying asset supplied to Aave (default: EURC).
 *   ATOKEN                  Corresponding aToken (default: aEthEURC).
 *   POOL_ADDRESSES_PROVIDER Aave PoolAddressesProvider (default: mainnet v3).
 *   REWARDS_CONTROLLER      Aave RewardsController (default: mainnet v3).
 *   REWARD_TOKEN            Reward token to claim and swap (default: WETH).
 *   STRATEGY_NAME           Strategy name (default: "Aave EURC Strategy").
 *   STRATEGY_PROTOCOL       Protocol label (default: "Aave v3").
 *   RISK_CLASS              0 = LOW, 1 = MEDIUM, 2 = HIGH (default: 0).
 *   CAP                     Strategy cap (default: uint256 max).
 *   GLOBAL_CAP              Global cap (default: uint256 max).
 *   ESTIMATED_YIELD         Estimated yield (default: 0).
 *   ADDITIONAL_INCENTIVES   Whether the market pays incentives (default: false).
 *   SLIPPAGE_BPS            Withdraw slippage in BPS, must be < 5000 (default: 50).
 *
 * forge script script/deploy/ethereum/Deploy_AaveStrategy.s.sol --rpc-url $MAINNET_RPC_URL --private-key
 * $PRIVATE_KEY --broadcast --etherscan-api-key $ETHERSCAN_API_KEY --verify -vv
 */
contract Deploy_AaveStrategy is Script, Test {
    // Aave v3 EURC mainnet market defaults.
    address internal constant DEFAULT_MYT_ASSET = 0x1aBaEA1f7C830bD89Acc67eC4af516284b1bC33c; // EURC
    address internal constant DEFAULT_ATOKEN = 0xAA6e91C82942aeAE040303Bf96c15a6dBcB82CA0; // aEthEURC
    address internal constant DEFAULT_POOL_ADDRESSES_PROVIDER = 0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e;
    address internal constant DEFAULT_REWARDS_CONTROLLER = 0x8164Cc65827dcFe994AB23944CBC90e0aa80bFcb;
    address internal constant DEFAULT_REWARD_TOKEN = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2; // WETH

    AaveStrategy public aaveStrategy;

    function run() external {
        address vault = vm.envAddress("VAULT");
        address strategyOwner = vm.envAddress("STRATEGY_OWNER");

        address mytAsset = vm.envOr("MYT_ASSET", DEFAULT_MYT_ASSET);
        address aToken = vm.envOr("ATOKEN", DEFAULT_ATOKEN);
        address poolAddressesProvider = vm.envOr("POOL_ADDRESSES_PROVIDER", DEFAULT_POOL_ADDRESSES_PROVIDER);
        address rewardsController = vm.envOr("REWARDS_CONTROLLER", DEFAULT_REWARDS_CONTROLLER);
        address rewardToken = vm.envOr("REWARD_TOKEN", DEFAULT_REWARD_TOKEN);

        IMYTStrategy.StrategyParams memory params = IMYTStrategy.StrategyParams({
            owner: strategyOwner,
            name: vm.envOr("STRATEGY_NAME", string("Aave EURC Strategy")),
            protocol: vm.envOr("STRATEGY_PROTOCOL", string("Aave v3")),
            riskClass: IMYTStrategy.RiskClass(vm.envOr("RISK_CLASS", uint256(0))),
            cap: vm.envOr("CAP", type(uint256).max),
            globalCap: vm.envOr("GLOBAL_CAP", type(uint256).max),
            estimatedYield: vm.envOr("ESTIMATED_YIELD", uint256(0)),
            additionalIncentives: vm.envOr("ADDITIONAL_INCENTIVES", false),
            slippageBPS: vm.envOr("SLIPPAGE_BPS", uint256(50))
        });

        // START RECORDING TRANSACTIONS FOR DEPLOYMENT
        vm.startBroadcast();

        emit log_named_address("Deployer Address", msg.sender);

        aaveStrategy =
            new AaveStrategy(vault, params, mytAsset, aToken, poolAddressesProvider, rewardsController, rewardToken);

        // STOP RECORDING TRANSACTIONS FOR DEPLOYMENT
        vm.stopBroadcast();

        // Sanity check the wiring against the live chain state.
        require(aaveStrategy.MYT().asset() == mytAsset, "vault asset mismatch");

        emit log_named_address("AaveStrategy", address(aaveStrategy));
        emit log_named_bytes32("Adapter Id", aaveStrategy.adapterId());
    }

    function _logAndOutputContractAddresses(string memory outputPath, address vault) internal {
        // WRITE JSON DATA
        string memory parentObject = "parent object";
        string memory deployedAddresses = "addresses";
        string memory chainInfo = "chainInfo";

        vm.serializeAddress(deployedAddresses, "vault", vault);
        vm.serializeBytes32(deployedAddresses, "adapterId", aaveStrategy.adapterId());
        string memory deployedAddressesOutput =
            vm.serializeAddress(deployedAddresses, "aaveStrategy", address(aaveStrategy));

        vm.serializeUint(chainInfo, "deploymentBlock", block.number);
        string memory chainInfoOutput = vm.serializeUint(chainInfo, "chainId", block.chainid);

        // serialize all the data
        vm.serializeString(parentObject, deployedAddresses, deployedAddressesOutput);
        string memory finalJson = vm.serializeString(parentObject, chainInfo, chainInfoOutput);

        vm.writeJson(finalJson, outputPath);
    }
}
