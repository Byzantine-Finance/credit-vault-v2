// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 [Byzantine Finance]
// The implementation of this contract was inspired by Morpho Vault V2, developed by the Morpho Association in 2025.
pragma solidity ^0.8.0;

import "./ByzantineEurVaultIntegrationTest.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";

contract ByzantineEurVaultIntegrationSkimTest is ByzantineEurVaultIntegrationTest {
    address internal recipient = makeAddr("recipient");

    function testSkimByzantineEurVault(uint256 assets) public {
        assets = _boundAssets(assets);

        ERC20Mock token = new ERC20Mock(18);

        vm.expectEmit();
        emit IByzantineEurVaultAdapter.SetSkimRecipient(recipient);
        vm.prank(owner);
        adapter.setSkimRecipient(recipient);

        deal(address(token), address(adapter), assets);
        assertEq(token.balanceOf(address(adapter)), assets, "Adapter did not receive tokens");

        vm.expectEmit();
        emit IByzantineEurVaultAdapter.Skim(address(token), assets);
        vm.prank(recipient);
        adapter.skim(address(token));

        // Verify successful skim
        assertEq(token.balanceOf(address(adapter)), 0, "Tokens not skimmed from adapter");
        assertEq(token.balanceOf(recipient), assets, "Recipient did not receive tokens");

        // Verify reverts
        vm.expectRevert(IByzantineEurVaultAdapter.NotAuthorized.selector);
        adapter.skim(address(token));

        vm.expectRevert(IByzantineEurVaultAdapter.NotAuthorized.selector);
        adapter.setSkimRecipient(recipient);

        // The Byzantine adapter blocks both EURC (the underlying asset) and bpEUR (the EUR vault shares).
        vm.expectRevert(IByzantineEurVaultAdapter.CannotSkimEurc.selector);
        vm.prank(recipient);
        adapter.skim(address(eurc));

        vm.expectRevert(IByzantineEurVaultAdapter.CannotSkimBpEur.selector);
        vm.prank(recipient);
        adapter.skim(address(eurVault));
    }

    function _boundAssets(uint256 assets) internal pure returns (uint256) {
        return bound(assets, MIN_TEST_ASSETS, MAX_TEST_ASSETS);
    }
}
