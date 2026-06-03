// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AaveStrategy} from "../../../src/adapters/AaveStrategy.sol";
import {IMYTStrategy} from "../../../src/adapters/interfaces/IMYTStrategy.sol";

import {Script} from "forge-std/Script.sol";
import {Test} from "forge-std/Test.sol";

/**
 * @notice Script used to deploy an {AaveStrategy} adapter on Base.
 *
 * Required environment variables:
 *   VAULT                   The VaultV2 the adapter is wired to.
 *   STRATEGY_OWNER          Owner of the strategy (admin functions, kill switch).
 *
 * Optional environment variables (default to the Aave v3 EURC Base market):
 *   MYT_ASSET               Underlying asset supplied to Aave (default: EURC).
 *   ATOKEN                  Corresponding aToken (default: aBasEURC).
 *   POOL_ADDRESSES_PROVIDER Aave PoolAddressesProvider (default: Base v3).
 *   REWARDS_CONTROLLER      Aave RewardsController (default: Base v3).
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
 * forge script script/deploy/base/Deploy_AaveStrategy.s.sol --rpc-url $BASE_RPC_URL --private-key
 * $PRIVATE_KEY --broadcast --etherscan-api-key $ETHERSCAN_API_KEY --verify -vv
 */
contract Deploy_AaveStrategy is Script, Test {
    // Aave v3 EURC Base market defaults.
    address internal constant DEFAULT_MYT_ASSET = 0x60a3E35Cc302bFA44Cb288Bc5a4F316Fdb1adb42; // EURC
    address internal constant DEFAULT_ATOKEN = 0x90DA57E0A6C0d166Bf15764E03b83745Dc90025B; // aBasEURC
    address internal constant DEFAULT_POOL_ADDRESSES_PROVIDER = 0xe20fCBdBfFC4Dd138cE8b2E6FBb6CB49777ad64D;
    address internal constant DEFAULT_REWARDS_CONTROLLER = 0xf9cc4F0D883F1a1eb2c253bdb46c254Ca51E1F44;
    address internal constant DEFAULT_REWARD_TOKEN = 0x4200000000000000000000000000000000000006; // WETH

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

        _logAndOutputContractAddresses("./script/deploy/base/Addresses_AaveStrategy.json", vault);
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
