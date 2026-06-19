// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 [Byzantine Finance]
// The implementation of this contract was inspired by Morpho Vault V2, developed by the Morpho Association in 2025.
pragma solidity ^0.8.0;

import "./ByzantineEurVaultIntegrationTest.sol";
import {ByzantineEurVaultAdapter} from "../../src/adapters/ByzantineEurVaultAdapter.sol";
import {IVaultV2} from "../../src/interfaces/IVaultV2.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";

contract ByzantineEurVaultIntegrationRevertTest is ByzantineEurVaultIntegrationTest {
    function testAllocateOnlyParentVault(address invalidCaller, uint256 assets) public {
        vm.assume(invalidCaller != address(vault));
        assets = bound(assets, 0, MAX_TEST_ASSETS);
        vm.expectRevert(IByzantineEurVaultAdapter.NotAuthorized.selector);
        vm.prank(invalidCaller);
        adapter.allocate(hex"", assets, bytes4(0), address(0));
    }

    function testDeallocateOnlyParentVault(address invalidCaller, uint256 assets) public {
        vm.assume(invalidCaller != address(vault));
        assets = bound(assets, 0, MAX_TEST_ASSETS);
        vm.expectRevert(IByzantineEurVaultAdapter.NotAuthorized.selector);
        vm.prank(invalidCaller);
        adapter.deallocate(hex"", assets, bytes4(0), address(0));
    }

    function testAllocateInvalidData(bytes memory data) public {
        vm.assume(data.length > 0);
        vm.expectRevert(IByzantineEurVaultAdapter.InvalidData.selector);
        vm.prank(address(vault));
        adapter.allocate(data, 0, bytes4(0), address(0));
    }

    function testDeallocateInvalidData(bytes memory data) public {
        vm.assume(data.length > 0);
        vm.expectRevert(IByzantineEurVaultAdapter.InvalidData.selector);
        vm.prank(address(vault));
        adapter.deallocate(data, 0, bytes4(0), address(0));
    }

    function testConstructorAssetMismatchReverts() public {
        // Build a parent vault whose underlying does NOT match the EUR vault's asset (EURC).
        ERC20Mock otherToken = new ERC20Mock(18);
        IVaultV2 otherVault = IVaultV2(vaultFactory.createVaultV2(owner, address(otherToken), bytes32(0)));

        vm.expectRevert(IByzantineEurVaultAdapter.AssetMismatch.selector);
        new ByzantineEurVaultAdapter(address(otherVault), address(eurVault));
    }

    function testIdsLengthOneAndStable() public view {
        bytes32[] memory ids = adapter.ids();
        assertEq(ids.length, 1, "single id");
        assertEq(ids[0], adapter.adapterId(), "id == adapterId");
    }
}
