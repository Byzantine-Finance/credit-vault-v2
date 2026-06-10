// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 [Byzantine Finance]
// The implementation of this contract was inspired by Morpho Vault V2, developed by the Morpho Association in 2025.
pragma solidity ^0.8.0;

import "./ByzantineEurVaultIntegrationTest.sol";

/// @notice Position lifecycle across batches: sweep selectivity, gas-bounding and access.
contract ByzantineEurVaultIntegrationBatchTest is ByzantineEurVaultIntegrationTest {
    uint256 internal constant ASSETS_100 = 100e6;
    uint256 internal constant ASSETS_250 = 250e6;

    /// @notice A settled position is swept while a position queued on a later batch stays live.
    /// @dev    Setup builds two positions: batch1 (settled) and batch2 (opened mid-DNT on `nextBatchId`).
    ///         Settling + closing batch1 mints A1's bpEUR to position1; `sweepSettled` must bring it
    ///         home and drop position1 while leaving position2 untouched.
    function testSweepSettledRemovesOnlySettledPositions() public {
        // batch1: allocate A1, then start the DNT so it becomes the locked, in-settlement batch.
        vault.deposit(ASSETS_100 + ASSETS_250, address(this));
        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", ASSETS_100);
        eurVault.executeDnt();

        // batch2: allocate A2 mid-DNT — the position queues on `nextBatchId`.
        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", ASSETS_250);
        assertEq(adapter.positionsLength(), 2, "two live positions before settling");
        address position1 = adapter.positions(0);
        address position2 = adapter.positions(1);

        // Settle + close batch1: A1's bpEUR is minted to position1 and `currentBatchId` advances past it.
        address[] memory r = new address[](1);
        r[0] = position1;
        eurVault.processDepositChunk(r, type(uint256).max);
        eurVault.processWithdrawChunk(r, type(uint256).max);
        eurVault.closeBatch();
        assertEq(eurVault.balanceOf(position1), ASSETS_100 * BPEUR_PER_EURC, "A1 bpEUR now on position1");
        assertTrue(EurVaultPosition(position1).settled(), "position1 settled");
        assertFalse(EurVaultPosition(position2).settled(), "position2 still pending");

        // Permissionless sweep: position1 swept home, position2 survives.
        adapter.sweepSettled(type(uint256).max);

        assertEq(adapter.positionsLength(), 1, "settled position1 dropped");
        assertEq(adapter.positions(0), position2, "position2 survives");
        assertEq(eurVault.balanceOf(address(adapter)), ASSETS_100 * BPEUR_PER_EURC, "A1 bpEUR swept to adapter");
        assertEq(eurVault.balanceOf(position1), 0, "position1 emptied");

        // Sanity: value is coherent — A1 settled into bpEUR on the adapter + A2 still pending.
        assertEq(adapter.realAssets(), ASSETS_100 + ASSETS_250, "realAssets coherent after sweep");
    }

    /// @notice Sweeping when every position is settled empties the tracking array.
    function testSweepSettledEmptiesPositionsWhenAllSettled() public {
        vault.deposit(ASSETS_100, address(this));
        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", ASSETS_100);
        _settleAdapterBatch(); // settles + closes batch1; the position is still listed
        assertEq(adapter.positionsLength(), 1, "position still listed pre-sweep");

        adapter.sweepSettled(type(uint256).max);

        assertEq(adapter.positionsLength(), 0, "positions emptied");
        assertEq(adapter.realAssets(), ASSETS_100, "value carried by the adapter's own balances");
    }

    /// @notice When no position is settled, sweeping is a no-op.
    function testSweepSettledNoOpWhenNothingSettled() public {
        vault.deposit(ASSETS_100, address(this));
        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", ASSETS_100); // queues on batch1, not settled

        adapter.sweepSettled(type(uint256).max);

        assertEq(adapter.positionsLength(), 1, "pending position untouched");
        assertEq(adapter.realAssets(), ASSETS_100, "realAssets unchanged");
    }

    /// @notice `maxPositions` bounds the sweep so it cannot run out of gas; remaining settled
    ///         positions are swept by subsequent calls.
    function testSweepSettledBoundedByMaxPositions() public {
        vault.deposit(ASSETS_100 + ASSETS_250, address(this));
        vm.startPrank(allocator);
        vault.allocate(address(adapter), hex"", ASSETS_100);
        vault.allocate(address(adapter), hex"", ASSETS_250);
        vm.stopPrank();
        _settleAdapterBatch(); // both positions settle in the same batch
        assertEq(adapter.positionsLength(), 2, "two settled positions listed");

        adapter.sweepSettled(1);
        assertEq(adapter.positionsLength(), 1, "only one position swept (bounded)");

        adapter.sweepSettled(1);
        assertEq(adapter.positionsLength(), 0, "second call sweeps the rest");

        assertEq(adapter.realAssets(), ASSETS_100 + ASSETS_250, "value preserved across bounded sweeps");
    }
}
