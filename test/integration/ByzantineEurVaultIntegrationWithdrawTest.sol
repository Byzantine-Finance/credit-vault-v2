// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 [Byzantine Finance]
// The implementation of this contract was inspired by Morpho Vault V2, developed by the Morpho Association in 2025.
pragma solidity ^0.8.0;

import "./ByzantineEurVaultIntegrationTest.sol";
import {ByzantineEurVaultAdapter} from "../../src/adapters/ByzantineEurVaultAdapter.sol";

contract ByzantineEurVaultIntegrationWithdrawTest is ByzantineEurVaultIntegrationTest {
    /* requestWithdraw ACCESS CONTROL */

    function testRequestWithdrawOnlyAdapterCurator(address invalidCaller) public {
        vm.assume(invalidCaller != adapterCurator);
        vm.expectRevert(IByzantineEurVaultAdapter.NotAuthorized.selector);
        vm.prank(invalidCaller);
        adapter.requestWithdraw(1);
    }

    function testRequestWithdrawZeroSharesRevertsAtEurVault() public {
        vm.prank(adapterCurator);
        vm.expectRevert(MockByzantinePrimeEURVault.ZeroShares.selector);
        adapter.requestWithdraw(0);
    }

    /* setAdapterCurator ACCESS CONTROL & STATE */

    function testSetAdapterCuratorOnlyVaultCurator(address invalidCaller, address newAdapterCurator) public {
        vm.assume(invalidCaller != curator);
        vm.expectRevert(IByzantineEurVaultAdapter.NotAuthorized.selector);
        vm.prank(invalidCaller);
        adapter.setAdapterCurator(newAdapterCurator);
    }

    function testSetAdapterCuratorEmitsAndStores(address newAdapterCurator) public {
        vm.expectEmit(true, false, false, false, address(adapter));
        emit IByzantineEurVaultAdapter.SetAdapterCurator(newAdapterCurator);
        vm.prank(curator);
        adapter.setAdapterCurator(newAdapterCurator);
        assertEq(adapter.adapterCurator(), newAdapterCurator, "adapterCurator stored");
    }

    /* ROLE ROTATION SEMANTICS */

    function testRotatingAdapterCuratorRevokesPreviousCurator(address newAdapterCurator) public {
        vm.assume(newAdapterCurator != adapterCurator);
        vm.assume(newAdapterCurator != address(0));

        vm.prank(curator);
        adapter.setAdapterCurator(newAdapterCurator);

        // Previous adapter curator must no longer be able to call requestWithdraw.
        vm.expectRevert(IByzantineEurVaultAdapter.NotAuthorized.selector);
        vm.prank(adapterCurator);
        adapter.requestWithdraw(1);
    }

    function testRotatingAdapterCuratorActivatesNewCurator(uint256 assets, address newAdapterCurator) public {
        assets = bound(assets, MIN_TEST_ASSETS, MAX_TEST_ASSETS);
        vm.assume(newAdapterCurator != adapterCurator);
        vm.assume(newAdapterCurator != address(0));

        // Set up bpEUR on the adapter via the gate-open path so we can call requestWithdraw immediately.
        vault.deposit(assets, address(this));
        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", assets);
        _settleAdapterBatch();
        uint256 shares = eurVault.balanceOf(address(adapter));

        // Rotate the curator.
        vm.prank(curator);
        adapter.setAdapterCurator(newAdapterCurator);

        // The new curator can call requestWithdraw.
        vm.prank(newAdapterCurator);
        adapter.requestWithdraw(shares);
        assertEq(eurVault.balanceOf(address(adapter)), 0, "shares burned via new curator");
    }

    /* requestWithdraw HAPPY PATH & SEMANTICS */

    function testRequestWithdrawBurnsSharesAndQueuesPayout(uint256 assets) public {
        assets = bound(assets, MIN_TEST_ASSETS, MAX_TEST_ASSETS);

        vault.deposit(assets, address(this));
        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", assets);
        _settleAdapterBatch(); // gate-open: shares on adapter directly

        uint256 shares = eurVault.balanceOf(address(adapter));
        uint256 batchId = _activeBatchId();

        vm.prank(adapterCurator);
        adapter.requestWithdraw(shares);

        // Shares burned immediately.
        assertEq(eurVault.balanceOf(address(adapter)), 0, "shares burned");
        // Pending withdraw recorded against the active batch.
        (, uint256 pendingWith,,, bool isOpen) = adapter.batchAccounting(batchId);
        assertEq(pendingWith, shares, "pendingWithdrawShares");
        assertTrue(isOpen, "batch should be open");
    }

    function testRequestWithdrawEmitsEvent(uint256 assets) public {
        assets = bound(assets, MIN_TEST_ASSETS, MAX_TEST_ASSETS);

        vault.deposit(assets, address(this));
        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", assets);
        _settleAdapterBatch();

        uint256 shares = eurVault.balanceOf(address(adapter));
        uint256 batchId = _activeBatchId();

        vm.expectEmit(true, false, false, true, address(adapter));
        emit IByzantineEurVaultAdapter.RequestWithdraw(batchId, shares);
        vm.prank(adapterCurator);
        adapter.requestWithdraw(shares);
    }

    function testRequestWithdrawPullsClaimableSharesFirst(uint256 assets) public {
        // Specifically tests the adapter's `_pullClaimableShares` invocation inside `requestWithdraw`:
        // when shares are gate-blocked into `claimableShares`, the adapter must pull them in before burning.
        assets = bound(assets, MIN_TEST_ASSETS, MAX_TEST_ASSETS);
        vault.deposit(assets, address(this));
        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", assets);
        _settleAdapterBatchToClaimable(); // gate-blocked path: shares stay as claimable

        // Pre-state: nothing on adapter; everything sitting on the EUR vault as claimable.
        assertGt(eurVault.claimableShares(address(adapter)), 0, "should have claimable shares");
        assertEq(eurVault.balanceOf(address(adapter)), 0, "no adapter shares before pull");

        uint256 claimable = eurVault.claimableShares(address(adapter));
        vm.prank(adapterCurator);
        adapter.requestWithdraw(claimable); // adapter pulls then burns in one shot

        assertEq(eurVault.balanceOf(address(adapter)), 0, "shares pulled and burned");
        assertEq(eurVault.claimableShares(address(adapter)), 0, "claimable shares drained");
    }

    function testRequestWithdrawRealAssetsPreservesValueBeforeAndAfterSettlement(uint256 assets) public {
        assets = bound(assets, MIN_TEST_ASSETS, MAX_TEST_ASSETS);
        vault.deposit(assets, address(this));
        vm.prank(allocator);
        vault.allocate(address(adapter), hex"", assets);
        _settleAdapterBatch();

        uint256 realAssetsBefore = adapter.realAssets();
        uint256 shares = eurVault.balanceOf(address(adapter));

        vm.prank(adapterCurator);
        adapter.requestWithdraw(shares);

        // realAssets must not change just from queuing a withdrawal (shares -> pendingWithdrawShares value).
        assertApproxEqAbs(adapter.realAssets(), realAssetsBefore, 1, "realAssets unchanged on request");

        _settleAdapterBatch();
        // After settlement, the EURC is sitting idle on the adapter (gate-open path) - realAssets must still match.
        assertApproxEqAbs(adapter.realAssets(), realAssetsBefore, 1, "realAssets unchanged on settlement");
    }
}
