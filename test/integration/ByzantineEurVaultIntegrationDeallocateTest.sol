// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 [Byzantine Finance]
// The implementation of this contract was inspired by Morpho Vault V2, developed by the Morpho Association in 2025.
pragma solidity ^0.8.0;

import "./ByzantineEurVaultIntegrationTest.sol";

contract ByzantineEurVaultIntegrationDeallocateTest is ByzantineEurVaultIntegrationTest {
    function testDeallocateRevertsWhenAdapterHasNoIdleEurc(uint256 assets) public {
        assets = bound(assets, MIN_TEST_ASSETS, MAX_TEST_ASSETS);

        // Move all funds out of the adapter (allocate -> position -> eurVault), so the adapter has no idle EURC.
        vault.deposit(assets, address(this));
        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", assets);

        // No settlement yet, so there is nothing to sweep home either.
        vm.prank(allocator);
        vm.expectRevert(IByzantineEurVaultAdapter.InsufficientIdle.selector);
        vault.deallocate(address(adapter), hex"", assets);
    }

    function testDeallocateSweepsSettledPositionsWhenSufficient(uint256 assets) public {
        // Specifically tests the `_sweepSettled` inside `deallocate`. Full round-trip with the withdraw
        // settlement routed through the gate-blocked path so the EURC payout lands in claimableEurc
        // under the withdraw position.
        assets = bound(assets, MIN_TEST_ASSETS, MAX_TEST_ASSETS);

        vault.deposit(assets, address(this));
        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", assets);

        // Deposit settles on the gate-open path; the sweep lands the shares on the adapter.
        _settleAndSweep();
        uint256 adapterShares = eurVault.balanceOf(address(adapter));
        // First deposit on a 0-supply vault: 1 raw EURC mints BPEUR_PER_EURC raw bpEUR
        assertEq(adapterShares, assets * BPEUR_PER_EURC, "adapter holds shares (scaled 1:1)");

        vm.prank(adapterCurator);
        adapter.requestWithdraw(adapterShares);

        // Withdraw settles on the gate-blocked path so the EURC payout becomes claimable rather than idle.
        _settleAdapterBatchToClaimable();

        // Sanity: nothing idle on the adapter; the EUR vault holds the EURC as claimable for the position.
        address position = adapter.positions(0);
        assertEq(eurc.balanceOf(address(adapter)), 0, "adapter no idle pre-deallocate");
        assertEq(eurVault.claimableEurc(position), assets, "claimable EURC pre-deallocate");

        // `deallocate` must internally sweep the settled position, then VaultV2 transfers the EURC home.
        vm.prank(allocator);
        vault.deallocate(address(adapter), hex"", assets);

        assertEq(eurc.balanceOf(address(adapter)), 0, "adapter no idle post-deallocate");
        assertEq(eurc.balanceOf(address(vault)), assets, "parent vault holds EURC post-deallocate");
        assertEq(eurVault.claimableEurc(position), 0, "claimable EURC drained");
        assertEq(adapter.positionsLength(), 0, "settled position dropped");
        assertEq(adapter.allocation(), 0, "vault tracked allocation should be 0");
    }

    function testDeallocateEmitsDeallocateEvent(uint256 assets) public {
        // Generic event coverage; gate-open path keeps the setup minimal.
        assets = bound(assets, MIN_TEST_ASSETS, MAX_TEST_ASSETS);

        vault.deposit(assets, address(this));
        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", assets);

        _settleAndSweep();
        uint256 shares = eurVault.balanceOf(address(adapter));
        vm.prank(adapterCurator);
        adapter.requestWithdraw(shares);
        _settleAdapterBatch();

        vm.prank(allocator);
        vm.expectEmit(false, false, false, true, address(adapter));
        emit IByzantineEurVaultAdapter.Deallocate(assets);
        vault.deallocate(address(adapter), hex"", assets);
    }

    function testDeallocateSweepsStalePositionsBefore() public {
        // Two allocate/settle cycles plus a final claimable-route withdraw leave settled positions
        // listed; `deallocate` must sweep them all as a side-effect.
        uint256 amount = 100e6;
        vault.deposit(amount * 2, address(this));

        // First batch (gate-open): shares accumulate on the adapter after the sweep.
        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", amount);
        _settleAndSweep();

        // Second batch (gate-open): more shares accumulate.
        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", amount);
        _settleAndSweep();

        uint256 shares = eurVault.balanceOf(address(adapter));
        vm.prank(adapterCurator);
        adapter.requestWithdraw(shares);
        _settleAdapterBatchToClaimable(); // route EURC payout to claimable so the sweep path is exercised

        // The settled withdraw position is still listed.
        assertGt(adapter.positionsLength(), 0, "expect settled position before deallocate");

        uint256 totalEurc = eurVault.claimableEurc(adapter.positions(0));
        assertGt(totalEurc, 0, "claimable EURC must be set up for the sweep path to fire");

        vm.prank(allocator);
        vault.deallocate(address(adapter), hex"", totalEurc);

        assertEq(adapter.positionsLength(), 0, "positions swept post-deallocate");
    }

    function testDeallocateMoreThanClaimableReverts(uint256 assets) public {
        // The revert path needs the position's `claimableEurc` to be the ONLY source of EURC on the
        // adapter side, so the `>= assets` check after the sweep fails for `claimable + 1`.
        assets = bound(assets, MIN_TEST_ASSETS + 1, MAX_TEST_ASSETS);

        vault.deposit(assets, address(this));
        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", assets);

        _settleAndSweep();
        // Burn only half of the shares so the withdraw payout is `≈ assets/2` (the cap we'll exceed).
        uint256 halfShares = eurVault.balanceOf(address(adapter)) / 2;
        vm.assume(halfShares > 0);
        vm.prank(adapterCurator);
        adapter.requestWithdraw(halfShares);
        _settleAdapterBatchToClaimable(); // payout parked as claimable under the position

        uint256 claimable = eurVault.claimableEurc(adapter.positions(0));
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
        _settleAndSweep();

        uint256 shares = eurVault.balanceOf(address(adapter));
        vm.prank(adapterCurator);
        adapter.requestWithdraw(shares);
        _settleAdapterBatchToClaimable(); // EURC parked in claimable under the position

        uint256 allocationBefore = adapter.allocation();
        uint256 claimable = eurVault.claimableEurc(adapter.positions(0));

        vm.prank(allocator);
        vault.deallocate(address(adapter), hex"", claimable);

        // Allocation must drop by exactly `claimable` (no yield / loss in this path).
        assertEq(allocationBefore - adapter.allocation(), claimable, "allocation drop == deallocated assets");
    }
}
