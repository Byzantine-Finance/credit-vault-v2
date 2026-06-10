// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 [Byzantine Finance]
// The implementation of this contract was inspired by Morpho Vault V2, developed by the Morpho Association in 2025.
pragma solidity >=0.5.0;

import {IAdapter} from "../../interfaces/IAdapter.sol";

interface IByzantineEurVaultAdapter is IAdapter {
    /* EVENTS */

    event Allocate(address indexed position, uint256 indexed batchId, uint256 assets, uint256 netAssets);
    event Deallocate(uint256 assets);
    event RequestDeposit(address indexed position, uint256 indexed batchId, uint256 assets, uint256 netAssets);
    event RequestWithdraw(address indexed position, uint256 indexed batchId, uint256 shares);
    event SweepPosition(address indexed position, uint256 shares, uint256 eurc);
    event SetAdapterCurator(address indexed newAdapterCurator);
    event SetSkimRecipient(address indexed newSkimRecipient);
    event Skim(address indexed token, uint256 amount);

    /* ERRORS */

    error NotAuthorized();
    error InvalidData();
    error AssetMismatch();
    error InsufficientIdle();
    error InsufficientShares();
    error CannotSkimEurc();
    error CannotSkimBpEur();

    /* FUNCTIONS */

    function factory() external view returns (address);
    function parentVault() external view returns (address);
    function eurVault() external view returns (address);
    function asset() external view returns (address);
    function adapterId() external view returns (bytes32);
    function adapterCurator() external view returns (address);
    function skimRecipient() external view returns (address);
    function positionImplementation() external view returns (address);
    function positionNonce() external view returns (uint256);
    function positions(uint256 index) external view returns (address);
    function positionsLength() external view returns (uint256);
    function ids() external view returns (bytes32[] memory);
    function allocation() external view returns (uint256);
    function realAssets() external view returns (uint256);

    function allocate(bytes memory data, uint256 assets, bytes4, address) external returns (bytes32[] memory, int256);
    function deallocate(bytes memory data, uint256 assets, bytes4, address) external returns (bytes32[] memory, int256);
    function requestDeposit(uint256 assets) external;
    function requestWithdraw(uint256 shares) external;
    function sweepSettled(uint256 maxPositions) external;
    function setAdapterCurator(address newAdapterCurator) external;
    function setSkimRecipient(address newSkimRecipient) external;
    function skim(address token) external;
}
