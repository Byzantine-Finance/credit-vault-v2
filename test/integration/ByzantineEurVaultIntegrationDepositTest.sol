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

    /// @notice Happy path: idle EURC is transferred to the EUR vault and recorded on a fresh deposit
    ///         position queued on the active batch. No shares are minted until the next DNT settlement.
    function testRequestDepositTransfersIdleEurcAndOpensPosition(uint256 assets) public {
        assets = bound(assets, MIN_TEST_ASSETS, MAX_TEST_ASSETS);
        deal(address(eurc), address(adapter), assets);
        uint256 batchId = _activeBatchId();

        vm.prank(adapterCurator);
        adapter.requestDeposit(assets);

        // Idle EURC left the adapter for the EUR vault; no shares minted yet (settled at next DNT).
        assertEq(eurc.balanceOf(address(adapter)), 0, "adapter idle drained");
        assertEq(eurc.balanceOf(address(eurVault)), assets, "EUR vault received EURC");

        // The request lives in its own position, queued on the active batch.
        assertEq(adapter.positionsLength(), 1, "exactly one live position");
        EurVaultPosition position = EurVaultPosition(adapter.positions(0));
        assertEq(position.batchId(), batchId, "position batchId");
        assertEq(position.pendingEurc(), assets, "pendingEurc == assets (no fee)");
        assertEq(eurVault.balanceOf(address(position)), 0, "no bpEUR pre-settlement");
    }

    /// @notice `requestDeposit` emits `RequestDeposit(position, batchId, assets, netAssets)` with the net
    ///         (post deposit-fee) amount, fuzzed across the fee range.
    function testRequestDepositEmitsEventWithNetAssets(uint256 assets, uint16 feeBps) public {
        feeBps = uint16(bound(feeBps, 0, 1_000)); // up to 10%
        assets = bound(assets, MIN_TEST_ASSETS, MAX_TEST_ASSETS);
        eurVault.setDepositFeeBps(feeBps);
        deal(address(eurc), address(adapter), assets);

        uint256 batchId = _activeBatchId();
        uint256 expectedFee = (assets * feeBps + 9_999) / 10_000;
        uint256 expectedNet = assets - expectedFee;

        // topic1 (the position address) is not checked: it is derived from the CREATE2 nonce.
        vm.expectEmit(false, true, false, true, address(adapter));
        emit IByzantineEurVaultAdapter.RequestDeposit(address(0), batchId, assets, expectedNet);
        vm.prank(adapterCurator);
        adapter.requestDeposit(assets);
    }

    /// @notice With a deposit fee active, the position records the NET amount the EUR vault will
    ///         actually mint shares for, and `realAssets` reflects that net
    function testRequestDepositRecordsNetAfterDepositFee(uint256 assets, uint16 feeBps) public {
        feeBps = uint16(bound(feeBps, 1, 1_000));
        assets = bound(assets, MIN_TEST_ASSETS, MAX_TEST_ASSETS);
        eurVault.setDepositFeeBps(feeBps);
        deal(address(eurc), address(adapter), assets);

        vm.prank(adapterCurator);
        adapter.requestDeposit(assets);

        uint256 expectedFee = (assets * feeBps + 9_999) / 10_000;
        uint256 expectedNet = assets - expectedFee;
        EurVaultPosition position = EurVaultPosition(adapter.positions(0));
        assertEq(position.pendingEurc(), expectedNet, "pendingEurc net of deposit fee");
        // Idle is fully gone; value now equals the recoverable net (the fee left the adapter for good).
        assertEq(adapter.realAssets(), expectedNet, "realAssets net of deposit fee");
    }

    /// @notice With no fee, moving idle EURC into a pending deposit is value-neutral: `realAssets` is the
    ///         same before (idle EURC) and after (pending deposit position).
    function testRequestDepositPreservesRealAssets(uint256 assets) public {
        assets = bound(assets, MIN_TEST_ASSETS, MAX_TEST_ASSETS);
        deal(address(eurc), address(adapter), assets);

        assertEq(adapter.realAssets(), assets, "pre: idle EURC counted directly");

        vm.prank(adapterCurator);
        adapter.requestDeposit(assets);

        assertEq(adapter.realAssets(), assets, "post: same value, now a pending deposit position");
    }

    /* ------------------------------------------------------------------ */
    /*  Integration paths                                                 */
    /* ------------------------------------------------------------------ */

    /// @notice `requestDeposit` sweeps settled positions before checking the idle balance, so a curator
    ///         can redeploy a gate-blocked withdraw payout that is sitting as `claimableEurc` on a
    ///         settled withdraw position — even though the adapter holds zero idle EURC at call time.
    function testRequestDepositSweepsSettledPositionsFirst(uint256 assets) public {
        assets = bound(assets, MIN_TEST_ASSETS, MAX_TEST_ASSETS);

        // Seed bpEUR, then withdraw on the gate-blocked path so the payout parks as claimableEurc
        // under the withdraw position.
        vault.deposit(assets, address(this));
        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", assets);
        _settleAndSweep();
        uint256 shares = eurVault.balanceOf(address(adapter));
        vm.prank(adapterCurator);
        adapter.requestWithdraw(shares);
        _settleAdapterBatchToClaimable();

        // Pre-state: nothing idle on the adapter; the full payout sits as claimable under the position.
        address withdrawPosition = adapter.positions(0);
        uint256 claimable = eurVault.claimableEurc(withdrawPosition);
        assertEq(claimable, assets, "claimable EURC == original deposit");
        assertEq(eurc.balanceOf(address(adapter)), 0, "no idle EURC before sweep");

        uint256 batchId = _activeBatchId();
        vm.prank(adapterCurator);
        adapter.requestDeposit(claimable); // sweeps the settled position, then redeposits in one shot

        assertEq(eurVault.claimableEurc(withdrawPosition), 0, "claimable drained");
        assertEq(eurc.balanceOf(address(adapter)), 0, "swept EURC redeposited (none left idle)");
        // The settled withdraw position was dropped; only the fresh deposit position remains.
        assertEq(adapter.positionsLength(), 1, "one live position (the new deposit)");
        EurVaultPosition position = EurVaultPosition(adapter.positions(0));
        assertEq(position.batchId(), batchId, "new position batchId");
        assertEq(position.pendingEurc(), claimable, "pending deposit == swept claimable");
    }

    /// @notice A pending deposit settles into bpEUR at the next DNT, and `realAssets` is preserved
    ///         across the settlement and the sweep.
    function testRequestDepositSettlesIntoBpEurShares(uint256 assets) public {
        assets = bound(assets, MIN_TEST_ASSETS, MAX_TEST_ASSETS);
        deal(address(eurc), address(adapter), assets);

        vm.prank(adapterCurator);
        adapter.requestDeposit(assets);
        assertEq(adapter.realAssets(), assets, "pre-settlement: value held as pending deposit");

        _settleAdapterBatch(); // gate-open: shares minted directly to the position

        // Value preserved while the bpEUR still sits on the settled position.
        assertEq(adapter.realAssets(), assets, "post-settlement: value carried by the settled position");

        adapter.sweepSettled(type(uint256).max);

        // bpEUR swept home at parity; the value is now carried by the adapter's own balance.
        assertEq(eurVault.balanceOf(address(adapter)), assets * BPEUR_PER_EURC, "bpEUR swept at parity");
        assertEq(adapter.positionsLength(), 0, "settled position dropped");
        assertEq(adapter.realAssets(), assets, "post-sweep: value preserved as bpEUR position");
    }
}
