// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 [Byzantine Finance]
pragma solidity ^0.8.0;

import {ByzantineEurVaultIntegrationTest} from "./ByzantineEurVaultIntegrationTest.sol";
import {IEurVaultPosition} from "../../src/adapters/interfaces/IEurVaultPosition.sol";
import {IByzantineEurVaultAdapter} from "../../src/adapters/interfaces/IByzantineEurVaultAdapter.sol";
import {ErrorsLib} from "../../src/libraries/ErrorsLib.sol";

contract FxhWithdrawalQueueRecoveryEvidenceTest is ByzantineEurVaultIntegrationTest {
    uint256 internal constant RECOVERY_ASSETS = 100e6;

    function testControlledSettlementSweepDeallocateThenParentWithdraw() public {
        vault.deposit(RECOVERY_ASSETS, address(this));

        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", RECOVERY_ASSETS);
        _settleAndSweep();

        uint256 adapterShares = eurVault.balanceOf(address(adapter));
        assertEq(adapterShares, RECOVERY_ASSETS * BPEUR_PER_EURC, "adapter holds settled bpEUR");
        assertEq(eurc.balanceOf(address(vault)), 0, "parent vault starts without idle EURC");
        assertEq(eurc.balanceOf(address(adapter)), 0, "adapter starts without idle EURC");

        // Controlled source-only FXH adapter shortfall; PR #24 captures the deployed Aave/MYT selector separately.
        vm.prank(allocator);
        vault.setLiquidityAdapterAndData(address(adapter), hex"");
        (bool preRecoverySuccess, bytes memory preRecoveryRevertData) =
            address(vault).call(abi.encodeCall(vault.withdraw, (1, receiver, address(this))));
        assertFalse(preRecoverySuccess, "parent withdrawal should fail before FXH recovery settles");
        assertEq(bytes4(preRecoveryRevertData), IByzantineEurVaultAdapter.InsufficientIdle.selector, "controlled FXH shortfall selector");

        // Disable automatic deallocation so the final withdrawal proves that explicit parent-idle restoration is required.
        vm.prank(allocator);
        vault.setLiquidityAdapterAndData(address(0), hex"");

        vm.prank(adapterCurator);
        adapter.requestWithdraw(adapterShares);

        assertEq(adapter.positionsLength(), 1, "pending FXH withdrawal position observable");
        address position = adapter.positions(0);
        assertEq(IEurVaultPosition(position).pendingShares(), adapterShares, "pending shares recorded");
        assertFalse(IEurVaultPosition(position).settled(), "position not settled before controlled settlement");

        // Controlled test-double settlement: the mock ByzantinePrimeEURVault faithfully drives the adapter/position
        // claimable path, but this is not a real DNT settlement from the fx-hedge-contract repository.
        _settleAdapterBatchToClaimable();

        assertTrue(IEurVaultPosition(position).settled(), "position settled by controlled fixture");
        assertEq(eurVault.claimableEurc(position), RECOVERY_ASSETS, "controlled settlement produced claimable EURC");
        assertEq(eurc.balanceOf(address(adapter)), 0, "settlement alone has not swept EURC to adapter");
        assertEq(eurc.balanceOf(address(vault)), 0, "settlement alone has not restored parent idle");

        adapter.sweepSettled(type(uint256).max);

        assertEq(adapter.positionsLength(), 0, "settled position swept off adapter queue");
        assertEq(eurVault.claimableEurc(position), 0, "claimable EURC drained from position");
        assertEq(eurc.balanceOf(address(adapter)), RECOVERY_ASSETS, "sweep moved realized EURC to FXH adapter");
        assertEq(eurc.balanceOf(address(vault)), 0, "adapter EURC is not parent-vault idle before deallocate");

        vm.prank(allocator);
        vault.deallocate(address(adapter), hex"", RECOVERY_ASSETS);

        assertEq(eurc.balanceOf(address(adapter)), 0, "deallocate pulled adapter EURC");
        assertEq(eurc.balanceOf(address(vault)), RECOVERY_ASSETS, "parent vault idle restored");
        assertEq(adapter.allocation(), 0, "adapter allocation fully recovered");

        uint256 receiverBalanceBefore = eurc.balanceOf(receiver);
        uint256 ownerSharesBefore = vault.balanceOf(address(this));
        uint256 sharesBurned = vault.withdraw(RECOVERY_ASSETS, receiver, address(this));

        assertEq(sharesBurned, ownerSharesBefore, "withdraw burned all owner vault shares");
        assertEq(vault.balanceOf(address(this)), 0, "owner vault shares burned");
        assertEq(eurc.balanceOf(receiver) - receiverBalanceBefore, RECOVERY_ASSETS, "parent withdrawal paid receiver");
        assertEq(eurc.balanceOf(address(vault)), 0, "parent idle consumed by withdrawal");
    }

    function testAdapterCuratorAndDeallocatorAuthorizationsAreSeparate() public {
        vault.deposit(RECOVERY_ASSETS, address(this));

        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", RECOVERY_ASSETS);
        _settleAndSweep();

        uint256 adapterShares = eurVault.balanceOf(address(adapter));

        vm.prank(allocator);
        vm.expectRevert(IByzantineEurVaultAdapter.NotAuthorized.selector);
        adapter.requestWithdraw(adapterShares);

        vm.prank(adapterCurator);
        adapter.requestWithdraw(adapterShares);
        _settleAdapterBatchToClaimable();
        adapter.sweepSettled(type(uint256).max);

        vm.prank(adapterCurator);
        vm.expectRevert(ErrorsLib.Unauthorized.selector);
        vault.deallocate(address(adapter), hex"", RECOVERY_ASSETS);

        vm.prank(sentinel);
        vault.deallocate(address(adapter), hex"", RECOVERY_ASSETS);
        assertEq(eurc.balanceOf(address(vault)), RECOVERY_ASSETS, "sentinel deallocator restored idle");
    }

    function testPartialControlledSettlementCapsRecoverableAmount() public {
        vault.deposit(RECOVERY_ASSETS, address(this));

        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", RECOVERY_ASSETS);
        _settleAndSweep();

        uint256 halfShares = eurVault.balanceOf(address(adapter)) / 2;
        vm.prank(adapterCurator);
        adapter.requestWithdraw(halfShares);
        _settleAdapterBatchToClaimable();
        adapter.sweepSettled(type(uint256).max);

        uint256 recovered = eurc.balanceOf(address(adapter));
        assertGt(recovered, 0, "partial settlement recovered non-zero EURC");
        assertLt(recovered, RECOVERY_ASSETS, "partial settlement remains distinguishable from full recovery");

        vm.prank(allocator);
        vm.expectRevert(IByzantineEurVaultAdapter.InsufficientIdle.selector);
        vault.deallocate(address(adapter), hex"", recovered + 1);

        vm.prank(allocator);
        vault.deallocate(address(adapter), hex"", recovered);
        assertEq(eurc.balanceOf(address(vault)), recovered, "only realized EURC can become parent idle");
    }
}
