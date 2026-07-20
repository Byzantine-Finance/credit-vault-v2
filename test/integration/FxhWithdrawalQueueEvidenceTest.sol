// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {ByzantineEurVaultIntegrationTest} from "./ByzantineEurVaultIntegrationTest.sol";
import {IByzantineEurVaultAdapter} from "../../src/adapters/interfaces/IByzantineEurVaultAdapter.sol";
import {ErrorsLib} from "../../src/libraries/ErrorsLib.sol";
import {GateWhitelist} from "../../src/gate/GateWhitelist.sol";
import {IERC20} from "../../src/interfaces/IERC20.sol";

contract FxhWithdrawalQueueEvidenceTest is ByzantineEurVaultIntegrationTest {
    address internal constant DEPLOYED_BYZ_EUR_VAULT = 0x2F99e35Ea811F3cC230B26dfF817604B5D4B6e38;
    address internal constant DEPLOYED_EURC = 0x1aBaEA1f7C830bD89Acc67eC4af516284b1bC33c;
    address internal constant DEPLOYED_CONFIGURED_AAVE_MYT_STRATEGY = 0x4167785e9f3Ecd173Aa4c21Ab6fb1aBB4D5Be050;
    address internal constant DEPLOYED_ATOKEN = 0xAA6e91C82942aeAE040303Bf96c15a6dBcB82CA0;
    address internal constant DEPLOYED_CURATOR = 0x6A85d9E2fEC21f9C9452FC4022abf2a21A462851;
    address internal constant DEPLOYED_RECEIVE_SHARES_GATE = 0x5351999cA54675607d08003d9113553162bB795D;
    address internal constant DEPLOYED_SEND_ASSETS_GATE = 0x80dc268861Cf57D31c52E8cD0467B3d3024512bc;
    address internal constant DEPLOYED_SEND_SHARES_GATE = 0x02B38131Bd473554D2CEd77018c18d030C7CE390;
    address internal constant DEPLOYED_RECEIVE_SHARES_GATE_OWNER = 0xfa61edF2AAF38c103461F7f6493BA36cB16E42Dc;
    address internal constant GATE_ELIGIBLE_HOLDER = 0xbCbB9869BFf5972aA6f86125A49e849D5ddda48B;
    uint256 internal constant PINNED_MAINNET_BLOCK = 25_576_274;
    uint256 internal constant EVIDENCE_ASSETS = 100e6;
    uint256 internal constant FORK_WITHDRAW_ASSETS = 1_000_000_000_000;
    bytes4 internal constant AAVE_NOT_ENOUGH_AVAILABLE_USER_BALANCE_SELECTOR = 0x47bc4b2c;

    function testSourceOnlyControlledByzantineEurAdapterWithdrawShortfallCapturesExactBytes() public {
        vault.deposit(EVIDENCE_ASSETS, address(this));

        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", EVIDENCE_ASSETS);

        vm.prank(allocator);
        vault.setLiquidityAdapterAndData(address(adapter), hex"");

        (bool success, bytes memory revertData) =
            address(vault).call(abi.encodeCall(vault.withdraw, (1, address(this), address(this))));

        assertFalse(
            success, "source-only withdraw should revert on unavailable immediate Byzantine EUR adapter liquidity"
        );
        assertEq(bytes4(revertData), IByzantineEurVaultAdapter.InsufficientIdle.selector, "shortfall selector");
        assertEq(
            revertData,
            abi.encodeWithSelector(IByzantineEurVaultAdapter.InsufficientIdle.selector),
            "shortfall revert data"
        );
        assertEq(revertData.length, 4, "shortfall custom error has selector only");
    }

    function testReceiveAssetsGateControlHasDistinctRevertShape() public {
        vault.deposit(EVIDENCE_ASSETS, address(this));

        GateWhitelist receiveAssetsGate = new GateWhitelist(address(this));
        vm.prank(curator);
        vault.submit(abi.encodeCall(vault.setReceiveAssetsGate, (address(receiveAssetsGate))));
        vault.setReceiveAssetsGate(address(receiveAssetsGate));

        (bool success, bytes memory revertData) =
            address(vault).call(abi.encodeCall(vault.withdraw, (1, address(this), address(this))));

        assertFalse(success, "withdraw should revert before liquidity classification when receiver is gated");
        assertEq(bytes4(revertData), ErrorsLib.CannotReceiveAssets.selector, "gate selector");
        assertEq(revertData, abi.encodeWithSelector(ErrorsLib.CannotReceiveAssets.selector), "gate revert data");
        assertEq(revertData.length, 4, "gate custom error has selector only");
        assertTrue(
            bytes4(revertData) != IByzantineEurVaultAdapter.InsufficientIdle.selector,
            "gate failure must not classify as liquidity shortfall"
        );
    }

    function testPinnedForkCapturesConfiguredAaveMytWithdrawShortfallRevertBytes() public {
        string memory rpcUrl = vm.envString("MAINNET_RPC_URL");
        vm.createSelectFork(rpcUrl, PINNED_MAINNET_BLOCK);

        assertGt(DEPLOYED_BYZ_EUR_VAULT.code.length, 0, "official vault code present at pinned block");
        assertGt(
            DEPLOYED_CONFIGURED_AAVE_MYT_STRATEGY.code.length, 0, "configured strategy code present at pinned block"
        );
        assertEq(vaultAsset(DEPLOYED_BYZ_EUR_VAULT), DEPLOYED_EURC, "official vault asset");
        assertEq(vaultAdapter(DEPLOYED_BYZ_EUR_VAULT, 0), DEPLOYED_CONFIGURED_AAVE_MYT_STRATEGY, "adapter[0]");
        assertEq(
            vaultLiquidityAdapter(DEPLOYED_BYZ_EUR_VAULT),
            DEPLOYED_CONFIGURED_AAVE_MYT_STRATEGY,
            "configured liquidity adapter"
        );
        assertEq(vaultCurator(DEPLOYED_BYZ_EUR_VAULT), DEPLOYED_CURATOR, "curator");
        assertEq(vaultReceiveSharesGate(DEPLOYED_BYZ_EUR_VAULT), DEPLOYED_RECEIVE_SHARES_GATE, "receive shares gate");
        assertEq(vaultReceiveAssetsGate(DEPLOYED_BYZ_EUR_VAULT), address(0), "receive assets gate unset");
        assertEq(vaultSendAssetsGate(DEPLOYED_BYZ_EUR_VAULT), DEPLOYED_SEND_ASSETS_GATE, "send assets gate");
        assertEq(vaultSendSharesGate(DEPLOYED_BYZ_EUR_VAULT), DEPLOYED_SEND_SHARES_GATE, "send shares gate");
        assertTrue(vaultIsAdapter(DEPLOYED_BYZ_EUR_VAULT, DEPLOYED_CONFIGURED_AAVE_MYT_STRATEGY), "strategy registered");

        assertAaveMytStrategyShape(DEPLOYED_CONFIGURED_AAVE_MYT_STRATEGY);

        assertTrue(vaultCanReceiveShares(DEPLOYED_BYZ_EUR_VAULT, GATE_ELIGIBLE_HOLDER), "holder can receive shares");
        assertTrue(vaultCanReceiveAssets(DEPLOYED_BYZ_EUR_VAULT, GATE_ELIGIBLE_HOLDER), "holder can receive assets");
        assertTrue(vaultCanSendShares(DEPLOYED_BYZ_EUR_VAULT, GATE_ELIGIBLE_HOLDER), "holder can send shares");
        assertTrue(vaultCanSendAssets(DEPLOYED_BYZ_EUR_VAULT, GATE_ELIGIBLE_HOLDER), "holder can send assets");

        uint256 idleAssets = IERC20(DEPLOYED_EURC).balanceOf(DEPLOYED_BYZ_EUR_VAULT);
        assertEq(idleAssets, 618_965_074, "pinned vault idle EURC changed");
        assertGt(FORK_WITHDRAW_ASSETS, idleAssets, "withdraw amount must exceed pinned idle EURC");

        uint256 requiredShares = vaultPreviewWithdraw(DEPLOYED_BYZ_EUR_VAULT, FORK_WITHDRAW_ASSETS);
        assertLe(
            requiredShares, vaultBalanceOf(DEPLOYED_BYZ_EUR_VAULT, GATE_ELIGIBLE_HOLDER), "holder shares cover withdraw"
        );

        // Fork-only evidence: vm.prank uses an existing eligible holder to simulate an eth_call sender,
        // not to claim any production authorization path beyond that holder's deployed gate/share state.
        vm.prank(GATE_ELIGIBLE_HOLDER);
        (bool success, bytes memory revertData) = DEPLOYED_BYZ_EUR_VAULT.call(
            abi.encodeWithSignature(
                "withdraw(uint256,address,address)", FORK_WITHDRAW_ASSETS, GATE_ELIGIBLE_HOLDER, GATE_ELIGIBLE_HOLDER
            )
        );

        assertFalse(success, "fork-only holder withdraw should hit deployed Aave/MYT shortfall path");
        assertEq(bytes4(revertData), AAVE_NOT_ENOUGH_AVAILABLE_USER_BALANCE_SELECTOR, "Aave V3 selector");
        assertEq(revertData, hex"47bc4b2c", "Aave V3 NotEnoughAvailableUserBalance raw data");
        assertEq(revertData.length, 4, "Aave V3 no-argument custom error");
        assertTrue(bytes4(revertData) != ErrorsLib.CannotReceiveAssets.selector, "not receive-assets gate");
        assertTrue(bytes4(revertData) != ErrorsLib.CannotSendShares.selector, "not send-shares gate");
        assertTrue(
            bytes4(revertData) != IByzantineEurVaultAdapter.InsufficientIdle.selector, "not source-only idle error"
        );
    }

    function vaultAsset(address target) internal view returns (address result) {
        (bool success, bytes memory data) = target.staticcall(abi.encodeWithSignature("asset()"));
        require(success, "asset query failed");
        result = abi.decode(data, (address));
    }

    function vaultAdapter(address target, uint256 index) internal view returns (address result) {
        (bool success, bytes memory data) = target.staticcall(abi.encodeWithSignature("adapters(uint256)", index));
        require(success, "adapter query failed");
        result = abi.decode(data, (address));
    }

    function vaultIsAdapter(address target, address adapter_) internal view returns (bool result) {
        (bool success, bytes memory data) = target.staticcall(abi.encodeWithSignature("isAdapter(address)", adapter_));
        require(success, "isAdapter query failed");
        result = abi.decode(data, (bool));
    }

    function vaultBalanceOf(address target, address account) internal view returns (uint256 result) {
        (bool success, bytes memory data) = target.staticcall(abi.encodeWithSignature("balanceOf(address)", account));
        require(success, "balanceOf query failed");
        result = abi.decode(data, (uint256));
    }

    function vaultPreviewWithdraw(address target, uint256 assets) internal view returns (uint256 result) {
        (bool success, bytes memory data) =
            target.staticcall(abi.encodeWithSignature("previewWithdraw(uint256)", assets));
        require(success, "previewWithdraw query failed");
        result = abi.decode(data, (uint256));
    }

    function vaultCanReceiveShares(address target, address account) internal view returns (bool result) {
        (bool success, bytes memory data) =
            target.staticcall(abi.encodeWithSignature("canReceiveShares(address)", account));
        require(success, "canReceiveShares query failed");
        result = abi.decode(data, (bool));
    }

    function vaultCanReceiveAssets(address target, address account) internal view returns (bool result) {
        (bool success, bytes memory data) =
            target.staticcall(abi.encodeWithSignature("canReceiveAssets(address)", account));
        require(success, "canReceiveAssets query failed");
        result = abi.decode(data, (bool));
    }

    function vaultCanSendAssets(address target, address account) internal view returns (bool result) {
        (bool success, bytes memory data) =
            target.staticcall(abi.encodeWithSignature("canSendAssets(address)", account));
        require(success, "canSendAssets query failed");
        result = abi.decode(data, (bool));
    }

    function vaultCanSendShares(address target, address account) internal view returns (bool result) {
        (bool success, bytes memory data) =
            target.staticcall(abi.encodeWithSignature("canSendShares(address)", account));
        require(success, "canSendShares query failed");
        result = abi.decode(data, (bool));
    }

    function assertAaveMytStrategyShape(address target) internal view {
        (bool mytSuccess, bytes memory mytData) = target.staticcall(abi.encodeWithSignature("MYT()"));
        assertTrue(mytSuccess, "MYT probe succeeds");
        assertGt(mytData.length, 0, "MYT probe returns data");

        (bool mytAssetSuccess, bytes memory mytAssetData) = target.staticcall(abi.encodeWithSignature("mytAsset()"));
        assertTrue(mytAssetSuccess, "mytAsset probe succeeds");
        assertEq(abi.decode(mytAssetData, (address)), DEPLOYED_EURC, "myt asset");

        (bool aTokenSuccess, bytes memory aTokenData) = target.staticcall(abi.encodeWithSignature("aToken()"));
        assertTrue(aTokenSuccess, "aToken probe succeeds");
        assertEq(abi.decode(aTokenData, (address)), DEPLOYED_ATOKEN, "aToken");

        (bool parentVaultSuccess,) = target.staticcall(abi.encodeWithSignature("parentVault()"));
        assertFalse(parentVaultSuccess, "not Byzantine EUR adapter parentVault ABI");
        (bool eurVaultSuccess,) = target.staticcall(abi.encodeWithSignature("eurVault()"));
        assertFalse(eurVaultSuccess, "not Byzantine EUR adapter eurVault ABI");
    }

    function vaultLiquidityAdapter(address target) internal view returns (address result) {
        (bool success, bytes memory data) = target.staticcall(abi.encodeWithSignature("liquidityAdapter()"));
        require(success, "liquidityAdapter query failed");
        result = abi.decode(data, (address));
    }

    function vaultCurator(address target) internal view returns (address result) {
        (bool success, bytes memory data) = target.staticcall(abi.encodeWithSignature("curator()"));
        require(success, "curator query failed");
        result = abi.decode(data, (address));
    }

    function vaultReceiveSharesGate(address target) internal view returns (address result) {
        (bool success, bytes memory data) = target.staticcall(abi.encodeWithSignature("receiveSharesGate()"));
        require(success, "receiveSharesGate query failed");
        result = abi.decode(data, (address));
    }

    function vaultReceiveAssetsGate(address target) internal view returns (address result) {
        (bool success, bytes memory data) = target.staticcall(abi.encodeWithSignature("receiveAssetsGate()"));
        require(success, "receiveAssetsGate query failed");
        result = abi.decode(data, (address));
    }

    function vaultSendSharesGate(address target) internal view returns (address result) {
        (bool success, bytes memory data) = target.staticcall(abi.encodeWithSignature("sendSharesGate()"));
        require(success, "sendSharesGate query failed");
        result = abi.decode(data, (address));
    }

    function vaultSendAssetsGate(address target) internal view returns (address result) {
        (bool success, bytes memory data) = target.staticcall(abi.encodeWithSignature("sendAssetsGate()"));
        require(success, "sendAssetsGate query failed");
        result = abi.decode(data, (address));
    }
}
