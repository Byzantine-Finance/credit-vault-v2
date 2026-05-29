// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 [Byzantine Finance]
// The implementation of this contract was inspired by Morpho Vault V2, developed by the Morpho Association in 2025.
pragma solidity ^0.8.0;

import "./ByzantineEurVaultIntegrationTest.sol";

contract ByzantineEurVaultIntegrationDepositTest is ByzantineEurVaultIntegrationTest {
    /// @dev 100 EURC (6 decimals). Used by the fixed-amount tests for clean arithmetic.
    uint256 internal constant ASSETS_100 = 100e6;

    /* ------------------------------------------------------------------ */
    /*  Access control & guards                                           */
    /* ------------------------------------------------------------------ */

    /// @notice Only the adapter curator may call `requestDeposit`.
    function testRequestDepositOnlyAdapterCurator(address invalidCaller) public {
        vm.assume(invalidCaller != adapterCurator);
        vm.expectRevert(IByzantineEurVaultAdapter.NotAuthorized.selector);
        vm.prank(invalidCaller);
        adapter.requestDeposit(1);
    }

    /// @notice `requestDeposit` may only move EURC the adapter actually holds idle — requesting more than
    ///         the idle balance reverts
    function testRequestDepositRevertsWhenInsufficientIdle(uint256 idle, uint256 request) public {
        idle = bound(idle, 0, MAX_TEST_ASSETS - 1);
        request = bound(request, idle + 1, MAX_TEST_ASSETS);
        deal(address(eurc), address(adapter), idle);

        vm.expectRevert(IByzantineEurVaultAdapter.InsufficientIdle.selector);
        vm.prank(adapterCurator);
        adapter.requestDeposit(request);
    }

    /// @notice A zero-asset request reverts at the EUR vault's own `ZeroAssets` guard
    function testRequestDepositZeroAssetsRevertsAtEurVault() public {
        vm.expectRevert(MockByzantinePrimeEURVault.ZeroAssets.selector);
        vm.prank(adapterCurator);
        adapter.requestDeposit(0);
    }

    /* ------------------------------------------------------------------ */
    /*  Core accounting                                                   */
    /* ------------------------------------------------------------------ */

    /// @notice Happy path: idle EURC is transferred to the EUR vault, recorded as a pending deposit on the
    ///         active batch, and that batch is opened. No shares are minted until the next DNT settlement.
    function testRequestDepositTransfersIdleEurcAndOpensBatch(uint256 assets) public {
        assets = bound(assets, MIN_TEST_ASSETS, MAX_TEST_ASSETS);
        deal(address(eurc), address(adapter), assets);
        uint256 batchId = _activeBatchId();

        vm.prank(adapterCurator);
        adapter.requestDeposit(assets);

        // Idle EURC left the adapter for the EUR vault; no shares minted yet (settled at next DNT).
        assertEq(eurc.balanceOf(address(adapter)), 0, "adapter idle drained");
        assertEq(eurc.balanceOf(address(eurVault)), assets, "EUR vault received EURC");
        assertEq(eurVault.balanceOf(address(adapter)), 0, "no bpEUR pre-settlement");

        // Pending deposit recorded against the active batch, batch tracked exactly once.
        (uint128 pendingDep,,,, bool isOpen) = adapter.batchAccounting(batchId);
        assertEq(pendingDep, assets, "pendingDepositEurc == assets (no fee)");
        assertTrue(isOpen, "batch should be open");
        assertEq(adapter.openBatchIdsLength(), 1, "exactly one open batch");
        assertEq(adapter.openBatchIds(0), batchId, "openBatchIds[0]");
    }

    /// @notice `requestDeposit` emits `RequestDeposit(batchId, assets, netAssets)` with the net (post
    ///         deposit-fee) amount, fuzzed across the fee range.
    function testRequestDepositEmitsEventWithNetAssets(uint256 assets, uint16 feeBps) public {
        feeBps = uint16(bound(feeBps, 0, 1_000)); // up to 10%
        assets = bound(assets, MIN_TEST_ASSETS, MAX_TEST_ASSETS);
        eurVault.setDepositFeeBps(feeBps);
        deal(address(eurc), address(adapter), assets);

        uint256 batchId = _activeBatchId();
        uint256 expectedFee = (assets * feeBps + 9_999) / 10_000;
        uint256 expectedNet = assets - expectedFee;

        vm.expectEmit(true, false, false, true, address(adapter));
        emit IByzantineEurVaultAdapter.RequestDeposit(batchId, assets, expectedNet);
        vm.prank(adapterCurator);
        adapter.requestDeposit(assets);
    }

    /// @notice With a deposit fee active, the pending-deposit shadow records the NET amount the EUR vault
    ///         will actually mint shares for, and `realAssets` reflects that net
    function testRequestDepositRecordsNetAfterDepositFee(uint256 assets, uint16 feeBps) public {
        feeBps = uint16(bound(feeBps, 1, 1_000));
        assets = bound(assets, MIN_TEST_ASSETS, MAX_TEST_ASSETS);
        eurVault.setDepositFeeBps(feeBps);
        deal(address(eurc), address(adapter), assets);
        uint256 batchId = _activeBatchId();

        vm.prank(adapterCurator);
        adapter.requestDeposit(assets);

        uint256 expectedFee = (assets * feeBps + 9_999) / 10_000;
        uint256 expectedNet = assets - expectedFee;
        (uint128 pendingDep,,,,) = adapter.batchAccounting(batchId);
        assertEq(pendingDep, expectedNet, "pendingDepositEurc net of deposit fee");
        // Idle is fully gone; value now equals the recoverable net (the fee left the adapter for good).
        assertEq(adapter.realAssets(), expectedNet, "realAssets net of deposit fee");
    }

    /// @notice With no fee, moving idle EURC into a pending deposit is value-neutral: `realAssets` is the
    ///         same before (branch A: idle EURC) and after (branch C: pending deposit).
    function testRequestDepositPreservesRealAssets(uint256 assets) public {
        assets = bound(assets, MIN_TEST_ASSETS, MAX_TEST_ASSETS);
        deal(address(eurc), address(adapter), assets);

        assertEq(adapter.realAssets(), assets, "pre: idle EURC counted via branch (A)");

        vm.prank(adapterCurator);
        adapter.requestDeposit(assets);

        assertEq(adapter.realAssets(), assets, "post: same value, now branch (C) pending deposit");
    }

    /* ------------------------------------------------------------------ */
    /*  Integration paths                                                 */
    /* ------------------------------------------------------------------ */

    /// @notice `requestDeposit` pulls any claimable EURC in before checking the idle balance, so a curator
    ///         can redeploy a gate-blocked withdraw payout that is sitting as `claimableEurc` on the EUR
    ///         vault — even though the adapter holds zero idle EURC at call time.
    function testRequestDepositPullsClaimableEurcFirst(uint256 assets) public {
        assets = bound(assets, MIN_TEST_ASSETS, MAX_TEST_ASSETS);

        // Seed bpEUR, then withdraw on the gate-blocked path so the payout parks as claimableEurc.
        vault.deposit(assets, address(this));
        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", assets);
        _settleAdapterBatch();
        uint256 shares = eurVault.balanceOf(address(adapter));
        vm.prank(adapterCurator);
        adapter.requestWithdraw(shares);
        _settleAdapterBatchToClaimable();

        // Pre-state: nothing idle on the adapter; the full payout sits as claimable on the EUR vault.
        uint256 claimable = eurVault.claimableEurc(address(adapter));
        assertEq(claimable, assets, "claimable EURC == original deposit");
        assertEq(eurc.balanceOf(address(adapter)), 0, "no idle EURC before pull");

        uint256 batchId = _activeBatchId();
        vm.prank(adapterCurator);
        adapter.requestDeposit(claimable); // pulls claimable in, then redeposits it in one shot

        assertEq(eurVault.claimableEurc(address(adapter)), 0, "claimable drained");
        assertEq(eurc.balanceOf(address(adapter)), 0, "pulled EURC redeposited (none left idle)");
        (uint128 pendingDep,,,,) = adapter.batchAccounting(batchId);
        assertEq(pendingDep, claimable, "pending deposit == pulled claimable");
    }

    /// @notice A pending deposit settles into bpEUR at the next DNT,
    ///         and `realAssets` is preserved across the settlement.
    function testRequestDepositSettlesIntoBpEurShares(uint256 assets) public {
        assets = bound(assets, MIN_TEST_ASSETS, MAX_TEST_ASSETS);
        deal(address(eurc), address(adapter), assets);

        vm.prank(adapterCurator);
        adapter.requestDeposit(assets);
        assertEq(adapter.realAssets(), assets, "pre-settlement: value held as pending deposit");

        _settleAdapterBatch(); // gate-open: shares minted directly to the adapter

        // bpEUR minted at parity; the value is now carried by the live position.
        assertEq(eurVault.balanceOf(address(adapter)), assets * BPEUR_PER_EURC, "bpEUR minted at parity");
        assertEq(adapter.realAssets(), assets, "post-settlement: value preserved as bpEUR position");
    }
}
