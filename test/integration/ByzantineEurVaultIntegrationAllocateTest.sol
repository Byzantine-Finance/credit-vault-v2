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

        // EURC has moved through the position into the EUR vault; no shares minted yet (batch unsettled)
        address position = adapter.positions(0);
        assertEq(eurc.balanceOf(address(vault)), 0, "vault EURC post-allocate");
        assertEq(eurc.balanceOf(address(adapter)), 0, "adapter EURC post-allocate");
        assertEq(eurc.balanceOf(position), 0, "position EURC forwarded to EUR vault");
        assertEq(eurc.balanceOf(address(eurVault)), assets, "EUR vault EURC post-allocate");
        assertEq(eurVault.balanceOf(position), 0, "position bpEUR pre-settlement");
    }

    function testAllocateOpensPositionOnActiveBatch(uint256 assets) public {
        assets = bound(assets, MIN_TEST_ASSETS, MAX_TEST_ASSETS);

        vault.deposit(assets, address(this));

        uint256 batchId = _activeBatchId();

        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", assets);

        assertEq(adapter.positionsLength(), 1, "one live position");
        EurVaultPosition position = EurVaultPosition(adapter.positions(0));
        assertEq(position.batchId(), batchId, "position batchId");
        assertEq(position.pendingEurc(), assets, "pendingEurc (no fee)");
        assertEq(position.pendingShares(), 0, "deposit position has no pendingShares");
        assertFalse(position.settled(), "position not settled before batch close");
    }

    /* PARENT VAULT ALLOCATION */
    /// @notice `vault.allocate` applies the adapter's returned delta so `caps.allocation` matches `realAssets()`.
    function testAllocateSyncsParentVaultAllocation(uint256 assets) public {
        assets = bound(assets, MIN_TEST_ASSETS, MAX_TEST_ASSETS);
        vault.deposit(assets, address(this));

        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", assets);

        assertEq(adapter.allocation(), adapter.realAssets(), "parent vault allocation matches realAssets");
    }

    function testAllocateMultipleTimesSameBatchAggregatesIntoOnePosition(uint256 a1, uint256 a2) public {
        a1 = bound(a1, MIN_TEST_ASSETS, MAX_TEST_ASSETS / 2);
        a2 = bound(a2, MIN_TEST_ASSETS, MAX_TEST_ASSETS / 2);

        vault.deposit(a1 + a2, address(this));

        uint256 batchId = _activeBatchId();

        vm.startPrank(allocator);
        vault.allocate(address(adapter), hex"", a1);
        vault.allocate(address(adapter), hex"", a2);
        vm.stopPrank();

        // Same batch (no settlement in between): both deposits aggregate into a single position,
        // so the live-position count stays bounded by the number of open batches.
        assertEq(adapter.positionsLength(), 1, "one position per batch");
        EurVaultPosition p = EurVaultPosition(adapter.positions(0));
        assertEq(p.batchId(), batchId, "position batch");
        assertEq(adapter.depositPositionOf(batchId), address(p), "batch maps to the position");
        assertEq(p.pendingEurc(), a1 + a2, "pending amounts accumulate on the single position");
        assertEq(adapter.realAssets(), a1 + a2, "realAssets sums both allocates");
    }

    function testAllocateAcrossDifferentBatchesUsesNextBatchId(uint256 a1, uint256 a2) public {
        a1 = bound(a1, MIN_TEST_ASSETS, MAX_TEST_ASSETS / 2);
        a2 = bound(a2, MIN_TEST_ASSETS, MAX_TEST_ASSETS / 2);

        vault.deposit(a1 + a2, address(this));

        uint256 batchId1 = _activeBatchId();
        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", a1);

        // Move to DNT - per the EUR vault, requests then queue on `nextBatchId`.
        eurVault.setVaultState(IByzantinePrimeEURVault.VaultState.DntInProgress);
        uint256 batchId2 = _activeBatchId();
        assertEq(batchId2, batchId1 + 1, "next batch is current + 1 when DNT in progress");

        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", a2);

        EurVaultPosition p1 = EurVaultPosition(adapter.positions(0));
        EurVaultPosition p2 = EurVaultPosition(adapter.positions(1));
        assertEq(p1.batchId(), batchId1, "p1 on batch1");
        assertEq(p2.batchId(), batchId2, "p2 on batch2");
        assertEq(p1.pendingEurc(), a1, "p1 pending");
        assertEq(p2.pendingEurc(), a2, "p2 pending");
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
        // topic1 (the position address) is not checked: it is derived from the CREATE2 nonce.
        vm.expectEmit(false, true, false, true, address(adapter));
        emit IByzantineEurVaultAdapter.Allocate(address(0), batchId, assets, expectedNet);
        vault.allocate(address(adapter), hex"", assets);
    }

    /* DEPOSIT FEE */
    function testAllocateAppliesDepositFeeToPendingAmount(uint256 assets, uint16 feeBps) public {
        feeBps = uint16(bound(feeBps, 1, 1_000)); // up to 10%
        assets = bound(assets, MIN_TEST_ASSETS, MAX_TEST_ASSETS);
        eurVault.setDepositFeeBps(feeBps);

        vault.deposit(assets, address(this));

        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", assets);

        // pendingEurc should reflect the net assets after the deposit fee (mulDivUp).
        uint256 expectedFee = (assets * feeBps + 9999) / 10_000;
        uint256 expectedNet = assets - expectedFee;
        EurVaultPosition position = EurVaultPosition(adapter.positions(0));
        assertEq(position.pendingEurc(), expectedNet, "pendingEurc reflects fee");
    }

    /// @notice Hedge swap fee only: haircuts the depositor's effective EURC at settlement. The
    ///         adapter ends up with shares for `assets * (1 - swapFeeBps/10000)` worth, the swap-loss
    ///         EURC stays on the EUR vault.
    function testSwapFeeHaircutsDepositEffectiveAssets(uint256 assets, uint16 swapFeeBps) public {
        swapFeeBps = uint16(bound(swapFeeBps, 1, 1_000));
        assets = bound(assets, MIN_TEST_ASSETS, MAX_TEST_ASSETS);
        eurVault.setHedgeSwapFeeBps(swapFeeBps);

        vault.deposit(assets, address(this));
        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", assets);
        _settleAndSweep();

        uint256 expectedEffective = (assets * (10_000 - swapFeeBps)) / 10_000;

        // Adapter holds shares for the EFFECTIVE (post-haircut) amount.
        assertEq(eurVault.balanceOf(address(adapter)), expectedEffective * BPEUR_PER_EURC, "shares = effective * scale");
        // Backing equals the effective amount; swap loss is excluded.
        assertEq(eurVault.totalEurcBacking(), expectedEffective, "backing = effective");
        // Gross EURC stays on the EUR vault contract balance (swap loss + effective backing).
        assertEq(eurc.balanceOf(address(eurVault)), assets, "vault token balance retains gross");
        // realAssets reflects the post-haircut value via convertToAssets at the unchanged PPS.
        assertEq(adapter.realAssets(), expectedEffective, "realAssets = effective");
    }
}
