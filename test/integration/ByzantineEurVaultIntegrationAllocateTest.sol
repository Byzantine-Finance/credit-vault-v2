// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 [Byzantine Finance]
// The implementation of this contract was inspired by Morpho Vault V2, developed by the Morpho Association in 2025.
pragma solidity ^0.8.0;

import "./ByzantineEurVaultIntegrationTest.sol";

contract ByzantineEurVaultIntegrationAllocateTest is ByzantineEurVaultIntegrationTest {
    function testAllocateTransfersEurcToEurVault(uint256 assets) public {
        assets = bound(assets, MIN_TEST_ASSETS, MAX_TEST_ASSETS);

        vault.deposit(assets, address(this));

        // before allocate: EURC sits on the parent vault
        assertEq(eurc.balanceOf(address(vault)), assets, "vault EURC pre-allocate");
        assertEq(eurc.balanceOf(address(eurVault)), 0, "EUR vault EURC pre-allocate");

        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", assets);

        // EURC has moved into the EUR vault; no shares minted yet because batch is unsettled
        assertEq(eurc.balanceOf(address(vault)), 0, "vault EURC post-allocate");
        assertEq(eurc.balanceOf(address(adapter)), 0, "adapter EURC post-allocate");
        assertEq(eurc.balanceOf(address(eurVault)), assets, "EUR vault EURC post-allocate");
        assertEq(eurVault.balanceOf(address(adapter)), 0, "adapter bpEUR pre-settlement");
    }

    function testAllocateRecordsPendingDepositAndOpensBatch(uint256 assets) public {
        assets = bound(assets, MIN_TEST_ASSETS, MAX_TEST_ASSETS);

        vault.deposit(assets, address(this));

        uint256 batchId = _activeBatchId();

        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", assets);

        (uint128 pendingDep,,,, bool isOpen) = adapter.batchAccounting(batchId);
        assertEq(pendingDep, assets, "pendingDepositEurc (no fee)");
        assertTrue(isOpen, "batch should be open");
        assertEq(adapter.openBatchIdsLength(), 1, "openBatchIds length");
        assertEq(adapter.openBatchIds(0), batchId, "openBatchIds[0]");
    }

    function testAllocateAppliesDepositFeeToPendingAmount(uint256 assets, uint16 feeBps) public {
        feeBps = uint16(bound(feeBps, 1, 1_000)); // up to 10%
        assets = bound(assets, MIN_TEST_ASSETS, MAX_TEST_ASSETS);
        eurVault.setDepositFeeBps(feeBps);

        vault.deposit(assets, address(this));

        uint256 batchId = _activeBatchId();
        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", assets);

        // pendingDepositEurc should reflect the net assets after the deposit fee (mulDivUp).
        uint256 expectedFee = (assets * feeBps + 9999) / 10_000;
        uint256 expectedNet = assets - expectedFee;
        (uint128 pendingDep,,,,) = adapter.batchAccounting(batchId);
        assertEq(pendingDep, expectedNet, "pendingDepositEurc reflects fee");
    }

    function testAllocateReturnsAllocationDeltaEqualToRealAssetsChange(uint256 assets) public {
        assets = bound(assets, MIN_TEST_ASSETS, MAX_TEST_ASSETS);
        vault.deposit(assets, address(this));

        uint256 realAssetsBefore = adapter.realAssets();

        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", assets);

        // No fee in this test path, so realAssets should equal assets after allocate.
        uint256 realAssetsAfter = adapter.realAssets();
        assertEq(realAssetsAfter - realAssetsBefore, assets, "realAssets delta == assets");
        assertEq(adapter.allocation(), realAssetsAfter, "vault allocation tracks adapter allocation");
    }

    function testAllocateMultipleTimesSameBatchAccumulates(uint256 a1, uint256 a2) public {
        a1 = bound(a1, MIN_TEST_ASSETS, MAX_TEST_ASSETS / 2);
        a2 = bound(a2, MIN_TEST_ASSETS, MAX_TEST_ASSETS / 2);

        vault.deposit(a1 + a2, address(this));

        uint256 batchId = _activeBatchId();

        vm.startPrank(allocator);
        vault.allocate(address(adapter), hex"", a1);
        vault.allocate(address(adapter), hex"", a2);
        vm.stopPrank();

        // Same batch (no settlement between calls), should accumulate exactly once in openBatchIds.
        (uint128 pendingDep,,,,) = adapter.batchAccounting(batchId);
        assertEq(pendingDep, a1 + a2, "pendingDepositEurc accumulates");
        assertEq(adapter.openBatchIdsLength(), 1, "single openBatchId");
    }

    function testAllocateAcrossDifferentBatchesAccumulatesSeparately(uint256 a1, uint256 a2) public {
        a1 = bound(a1, MIN_TEST_ASSETS, MAX_TEST_ASSETS / 2);
        a2 = bound(a2, MIN_TEST_ASSETS, MAX_TEST_ASSETS / 2);

        vault.deposit(a1 + a2, address(this));

        uint256 batchId1 = _activeBatchId();
        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", a1);

        // Move to DNT - per the adapter, deposits then queue on `nextBatchId`.
        eurVault.setVaultState(IByzantinePrimeEURVault.VaultState.DntInProgress);
        uint256 batchId2 = _activeBatchId();
        assertEq(batchId2, batchId1 + 1, "next batch is current + 1 when DNT in progress");

        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", a2);

        (uint128 pending1,,,,) = adapter.batchAccounting(batchId1);
        (uint128 pending2,,,,) = adapter.batchAccounting(batchId2);
        assertEq(pending1, a1, "batch1 pending");
        assertEq(pending2, a2, "batch2 pending");
        assertEq(adapter.openBatchIdsLength(), 2, "two open batches");
    }

    function testAllocateEmitsAllocateEventWithNetAssets(uint256 assets, uint16 feeBps) public {
        feeBps = uint16(bound(feeBps, 0, 500));
        assets = bound(assets, MIN_TEST_ASSETS, MAX_TEST_ASSETS);
        eurVault.setDepositFeeBps(feeBps);

        vault.deposit(assets, address(this));
        uint256 batchId = _activeBatchId();
        uint256 expectedFee = (assets * feeBps + 9999) / 10_000;
        uint256 expectedNet = assets - expectedFee;

        vm.prank(allocator);
        vm.expectEmit(true, false, false, true, address(adapter));
        emit IByzantineEurVaultAdapter.Allocate(batchId, assets, expectedNet);
        vault.allocate(address(adapter), hex"", assets);
    }

    function testRealAssetsConsistentAfterSettlement(uint256 assets) public {
        assets = bound(assets, MIN_TEST_ASSETS, MAX_TEST_ASSETS);

        vault.deposit(assets, address(this));

        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", assets);

        // Before settlement, realAssets counts pending deposit.
        assertEq(adapter.realAssets(), assets, "realAssets before settlement");

        // Settle - mints bpEUR directly to the adapter
        _settleAdapterBatch();

        // After settlement, the pending entry is stale but realAssets still equals `assets`:
        // - claimableShares converted-back are exactly `assets`
        // - pendingDepositEurc[batchId] is still recorded but is skipped because batchId < currentBatchId
        assertEq(adapter.realAssets(), assets, "realAssets after settlement");
    }
}
