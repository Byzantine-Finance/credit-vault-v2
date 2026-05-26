// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 [Byzantine Finance]
// The implementation of this contract was inspired by Morpho Vault V2, developed by the Morpho Association in 2025.
pragma solidity ^0.8.0;

import "./ByzantineEurVaultIntegrationTest.sol";

contract ByzantineEurVaultIntegrationDeallocateTest is ByzantineEurVaultIntegrationTest {
    function testDeallocateRevertsWhenAdapterHasNoIdleEurc(uint256 assets) public {
        assets = bound(assets, MIN_TEST_ASSETS, MAX_TEST_ASSETS);

        // Move all funds out of the adapter (allocate -> eurVault), so the adapter has no idle EURC.
        vault.deposit(assets, address(this));
        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", assets);

        // No settlement yet, so there is no claimable EURC to pull either.
        vm.prank(allocator);
        vm.expectRevert(IByzantineEurVaultAdapter.InsufficientIdle.selector);
        vault.deallocate(address(adapter), hex"", assets);
    }

    function testDeallocatePullsClaimableEurcWhenSufficient(uint256 assets) public {
        // Specifically tests `_pullClaimableEurc` inside `deallocate`. Full round-trip with the withdraw
        // settlement routed through the gate-blocked path so the EURC payout lands in claimableEurc.
        assets = bound(assets, MIN_TEST_ASSETS, MAX_TEST_ASSETS);

        vault.deposit(assets, address(this));
        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", assets);

        // Deposit settles on the gate-open path: shares go to adapter.balanceOf directly.
        _settleAdapterBatch();
        uint256 adapterShares = eurVault.balanceOf(address(adapter));
        // First deposit on a 0-supply vault: 1 raw EURC mints BPEUR_PER_EURC raw bpEUR
        assertEq(adapterShares, assets * BPEUR_PER_EURC, "adapter holds shares (scaled 1:1)");

        vm.prank(adapterCurator);
        adapter.requestWithdraw(adapterShares);

        // Withdraw settles on the gate-blocked path so the EURC payout becomes claimable rather than idle.
        _settleAdapterBatchToClaimable();

        // Sanity: nothing idle on the adapter; the EUR vault holds the EURC as claimable.
        assertEq(eurc.balanceOf(address(adapter)), 0, "adapter no idle pre-deallocate");
        assertEq(eurVault.claimableEurc(address(adapter)), assets, "claimable EURC pre-deallocate");

        // `deallocate` must internally pull the claimable EURC, then VaultV2 transfers it home.
        vm.prank(allocator);
        vault.deallocate(address(adapter), hex"", assets);

        assertEq(eurc.balanceOf(address(adapter)), 0, "adapter no idle post-deallocate");
        assertEq(eurc.balanceOf(address(vault)), assets, "parent vault holds EURC post-deallocate");
        assertEq(eurVault.claimableEurc(address(adapter)), 0, "claimable EURC drained");
        assertEq(adapter.allocation(), 0, "vault tracked allocation should be 0");
    }

    function testDeallocateEmitsDeallocateEvent(uint256 assets) public {
        // Generic event coverage; gate-open path keeps the setup minimal.
        assets = bound(assets, MIN_TEST_ASSETS, MAX_TEST_ASSETS);

        vault.deposit(assets, address(this));
        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", assets);

        _settleAdapterBatch();
        uint256 shares = eurVault.balanceOf(address(adapter));
        vm.prank(adapterCurator);
        adapter.requestWithdraw(shares);
        _settleAdapterBatch();

        vm.prank(allocator);
        vm.expectEmit(false, false, false, true, address(adapter));
        emit IByzantineEurVaultAdapter.Deallocate(assets);
        vault.deallocate(address(adapter), hex"", assets);
    }

    function testDeallocateClearsSettledBatchesBefore() public {
        // Two allocate/settle cycles leave stale entries in openBatchIds, then a final claimable-route
        // withdraw exercises the `_pullClaimableEurc` + `_clearSettledBatches` combo inside `deallocate`.
        uint256 amount = 100e6;
        vault.deposit(amount * 2, address(this));

        // First batch (gate-open): shares accumulate on adapter.
        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", amount);
        _settleAdapterBatch();

        // Second batch (gate-open): more shares accumulate.
        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", amount);
        _settleAdapterBatch();

        uint256 shares = eurVault.balanceOf(address(adapter));
        vm.prank(adapterCurator);
        adapter.requestWithdraw(shares);
        _settleAdapterBatchToClaimable(); // route EURC payout to claimable so the pull path is exercised

        // openBatchIds now holds stale entries (the two allocate batches + the requestWithdraw batch).
        assertGt(adapter.openBatchIdsLength(), 0, "expect stale openBatchIds before deallocate");

        uint256 totalEurc = eurVault.claimableEurc(address(adapter));
        assertGt(totalEurc, 0, "claimable EURC must be set up for the pull path to fire");

        vm.prank(allocator);
        vault.deallocate(address(adapter), hex"", totalEurc);

        assertEq(adapter.openBatchIdsLength(), 0, "openBatchIds cleared post-deallocate");
    }

    function testDeallocateMoreThanClaimableReverts(uint256 assets) public {
        // The revert path needs `claimableEurc` to be the ONLY source of EURC on the adapter side, so the
        // adapter's `>= assets` check after `_pullClaimableEurc` fails for `claimable + 1`.
        assets = bound(assets, MIN_TEST_ASSETS + 1, MAX_TEST_ASSETS);

        vault.deposit(assets, address(this));
        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", assets);

        _settleAdapterBatch();
        // Burn only half of the shares so the withdraw payout is `≈ assets/2` (the cap we'll exceed).
        uint256 halfShares = eurVault.balanceOf(address(adapter)) / 2;
        vm.assume(halfShares > 0);
        vm.prank(adapterCurator);
        adapter.requestWithdraw(halfShares);
        _settleAdapterBatchToClaimable(); // payout parked as claimable EURC

        uint256 claimable = eurVault.claimableEurc(address(adapter));
        assertGt(claimable, 0, "claimable EURC must be set up");

        vm.prank(allocator);
        vm.expectRevert(IByzantineEurVaultAdapter.InsufficientIdle.selector);
        vault.deallocate(address(adapter), hex"", claimable + 1);
    }

    function testDeallocateUpdatesAllocationByActualDelta(uint256 assets) public {
        assets = bound(assets, MIN_TEST_ASSETS, MAX_TEST_ASSETS);
        vault.deposit(assets, address(this));

        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", assets);
        _settleAdapterBatch();

        uint256 shares = eurVault.balanceOf(address(adapter));
        vm.prank(adapterCurator);
        adapter.requestWithdraw(shares);
        _settleAdapterBatchToClaimable(); // EURC parked in claimable

        uint256 allocationBefore = adapter.allocation();
        uint256 claimable = eurVault.claimableEurc(address(adapter));

        vm.prank(allocator);
        vault.deallocate(address(adapter), hex"", claimable);

        // Allocation must drop by exactly `claimable` (no yield / loss in this path).
        assertEq(allocationBefore - adapter.allocation(), claimable, "allocation drop == deallocated assets");
    }
}
