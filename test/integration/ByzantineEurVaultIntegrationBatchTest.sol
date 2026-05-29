// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 [Byzantine Finance]
// The implementation of this contract was inspired by Morpho Vault V2, developed by the Morpho Association in 2025.
pragma solidity ^0.8.0;

import "./ByzantineEurVaultIntegrationTest.sol";

contract ByzantineEurVaultIntegrationBatchTest is ByzantineEurVaultIntegrationTest {
    uint256 internal constant ASSETS_100 = 100e6;
    uint256 internal constant ASSETS_250 = 250e6;

    /// @notice anyCleared && remaining != 0: a settled batch is cleared while a second batch stays open,
    ///         so the survivor's snapshots are re-anchored to the adapter's current balances.
    /// @dev    Setup builds `openBatchIds = [batch1 (settled), batch2 (still open)]`:
    ///           - allocate A1 opens batch1, then `executeDnt` locks it;
    ///           - allocate A2 mid-DNT opens batch2 on `nextBatchId`;
    ///           - settling + closing batch1 mints A1's bpEUR to the adapter and advances `currentBatchId`.
    ///         A permissionless `pullClaimableShares()` then triggers `_clearSettledBatches`, which drops
    ///         batch1 and re-anchors batch2's snapshots from `(0, 0)` (its at-open value, captured before
    ///         A1 settled) to `(A1 worth of bpEUR, 0)`.
    function testClearSettledBatchesReanchorsRemainingBatchSnapshots() public {
        // batch1: allocate A1, then start the DNT so it becomes the locked, in-settlement batch.
        vault.deposit(ASSETS_100 + ASSETS_250, address(this));
        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", ASSETS_100);
        eurVault.executeDnt();

        // batch2: allocate A2 mid-DNT — the adapter queues it on `nextBatchId`.
        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", ASSETS_250);
        uint256 batch2 = adapter.openBatchIds(1);
        assertEq(adapter.openBatchIdsLength(), 2, "two open batches before clearing");

        // batch2's snapshot is captured at open, BEFORE batch1 settles -> adapter held nothing then.
        {
            (, int128 eurcSnap,, int256 sharesSnap,) = adapter.batchAccounting(batch2);
            assertEq(sharesSnap, int256(0), "batch2 shares snapshot at open == 0");
            assertEq(eurcSnap, int128(0), "batch2 eurc snapshot at open == 0");
        }

        // Settle + close batch1: A1's bpEUR is minted to the adapter and `currentBatchId` advances past it.
        address[] memory r = new address[](1);
        r[0] = address(adapter);
        eurVault.processDepositChunk(r, type(uint256).max);
        eurVault.processWithdrawChunk(r, type(uint256).max);
        eurVault.closeBatch();
        assertEq(eurVault.balanceOf(address(adapter)), ASSETS_100 * BPEUR_PER_EURC, "A1 bpEUR now on adapter");

        // Trigger `_clearSettledBatches` (permissionless). batch1 is dropped; batch2 survives and re-anchors.
        adapter.pullClaimableShares();

        // batch1 popped, batch2 is the sole survivor.
        assertEq(adapter.openBatchIdsLength(), 1, "settled batch1 cleared");
        assertEq(adapter.openBatchIds(0), batch2, "batch2 survives");

        // batch2's snapshots re-anchored to the post-clear baseline; non-snapshot fields untouched.
        (uint128 pendingDep, int128 eurcSnapAfter, uint256 pendingWith, int256 sharesSnapAfter, bool isOpen) =
            adapter.batchAccounting(batch2);
        assertEq(sharesSnapAfter, int256(ASSETS_100 * BPEUR_PER_EURC), "shares snapshot re-anchored to current bpEUR");
        assertEq(eurcSnapAfter, int128(0), "eurc snapshot re-anchored to current idle EURC (0)");
        assertEq(uint256(pendingDep), ASSETS_250, "pending deposit untouched by re-anchor");
        assertEq(pendingWith, 0, "pending withdraw untouched by re-anchor");
        assertTrue(isOpen, "batch2 still open");

        // Sanity: value is coherent — A1 settled into bpEUR (branch B) + A2 still pending (branch C).
        assertEq(adapter.realAssets(), ASSETS_100 + ASSETS_250, "realAssets coherent after re-anchor");
    }

    /// @notice anyCleared && remaining == 0: the only open batch settles, so clearing empties `openBatchIds`
    ///         and the re-anchor loop is skipped (no survivor to re-anchor).
    function testClearSettledBatchesSkipsReanchorWhenNoBatchRemains() public {
        vault.deposit(ASSETS_100, address(this));
        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", ASSETS_100);
        _settleAdapterBatch(); // settles + closes batch1; adapter still lists it in openBatchIds
        assertEq(adapter.openBatchIdsLength(), 1, "batch1 still listed pre-clear");

        uint256 batch1 = adapter.openBatchIds(0);

        // Clearing drops batch1; nothing remains, so the `remaining != 0` guard short-circuits the re-anchor.
        adapter.pullClaimableShares();

        assertEq(adapter.openBatchIdsLength(), 0, "openBatchIds emptied");
        // The cleared batch's storage is fully zeroed by the `delete`.
        (uint128 pendingDep, int128 eurcSnap, uint256 pendingWith, int256 sharesSnap, bool isOpen) =
            adapter.batchAccounting(batch1);
        assertEq(uint256(pendingDep), 0, "cleared batch pendingDeposit zeroed");
        assertEq(eurcSnap, int128(0), "cleared batch eurc snapshot zeroed");
        assertEq(pendingWith, 0, "cleared batch pendingWithdraw zeroed");
        assertEq(sharesSnap, int256(0), "cleared batch shares snapshot zeroed");
        assertFalse(isOpen, "cleared batch no longer open");
    }

    /// @notice !anyCleared: when no batch is settled, clearing is a no-op and the open batch's snapshots are
    ///         left exactly as captured at open — the re-anchor must NOT run.
    /// @dev    Idle EURC is dealt onto the adapter AFTER the batch opened so that, if the re-anchor wrongly
    ///         fired, the eurc snapshot would jump from 0 to that idle amount. Asserting it stays 0 proves
    ///         the `anyCleared` guard held.
    function testClearSettledBatchesSkipsReanchorWhenNothingCleared() public {
        vault.deposit(ASSETS_100, address(this));
        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", ASSETS_100); // opens batch1, snapshot captured as (0, 0)
        uint256 batch1 = adapter.openBatchIds(0);

        // Make the current balance diverge from the at-open snapshot.
        deal(address(eurc), address(adapter), 50e6);

        // No batch has settled (currentBatchId unchanged), so clearing finds nothing to drop.
        adapter.pullClaimableShares();

        assertEq(adapter.openBatchIdsLength(), 1, "batch1 still open (nothing cleared)");
        (, int128 eurcSnap,, int256 sharesSnap, bool isOpen) = adapter.batchAccounting(batch1);
        assertEq(sharesSnap, int256(0), "shares snapshot unchanged (no re-anchor)");
        assertEq(eurcSnap, int128(0), "eurc snapshot unchanged despite 50 EURC idle (no re-anchor)");
        assertTrue(isOpen, "batch1 still open");
    }
}
