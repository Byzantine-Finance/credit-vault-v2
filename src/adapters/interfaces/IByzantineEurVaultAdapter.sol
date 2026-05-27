// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 [Byzantine Finance]
// The implementation of this contract was inspired by Morpho Vault V2, developed by the Morpho Association in 2025.
pragma solidity >=0.5.0;

import {IAdapter} from "../../interfaces/IAdapter.sol";

interface IByzantineEurVaultAdapter is IAdapter {
    /* STRUCTS */

    /// @dev Per-batch accounting state.
    struct BatchAccounting {
        /// @dev EURC sent to the EUR vault for this batch's deposit but not yet
        ///      settled (bpEUR shares minted at the next DNT).
        uint256 pendingDepositEurc;
        /// @dev bpEUR burned for this batch's withdraw but EURC not yet received.
        uint256 pendingWithdrawShares;
        /// @dev Snapshot of (bpEUR balance + claimableShares) at batch open,
        ///      decremented on every burn. Goes below zero when burns exceed the open snapshot.
        int256 sharesSnapshotAtBatch;
        /// @dev Snapshot of (EURC balance + claimableEurc) at batch open,
        ///      decremented on every outgoing EURC transfer (deallocate / requestDeposit).
        ///      Goes below zero when transfers exceed the open snapshot.
        int256 eurcSnapshotAtBatch;
        /// @dev True if the batch is currently tracked in `openBatchIds`.
        bool isOpen;
    }

    /* EVENTS */

    event Allocate(uint256 indexed batchId, uint256 assets, uint256 netAssets);
    event Deallocate(uint256 assets);
    event RequestDeposit(uint256 indexed batchId, uint256 assets, uint256 netAssets);
    event RequestWithdraw(uint256 indexed batchId, uint256 shares);
    event SetAdapterCurator(address indexed newAdapterCurator);
    event SetSkimRecipient(address indexed newSkimRecipient);
    event Skim(address indexed token, uint256 amount);
    event PullClaimableShares(uint256 shares);
    event PullClaimableEurc(uint256 amount);
    event ClearId(uint256 indexed batchId);

    /* ERRORS */

    error NotAuthorized();
    error InvalidData();
    error AssetMismatch();
    error InsufficientIdle();
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
    function batchAccounting(uint256 batchId)
        external
        view
        returns (
            uint256 pendingDepositEurc,
            uint256 pendingWithdrawShares,
            int256 sharesSnapshotAtBatch,
            int256 eurcSnapshotAtBatch,
            bool isOpen
        );
    function openBatchIds(uint256 index) external view returns (uint256);
    function openBatchIdsLength() external view returns (uint256);
    function ids() external view returns (bytes32[] memory);
    function allocation() external view returns (uint256);
    function realAssets() external view returns (uint256);

    function allocate(bytes memory data, uint256 assets, bytes4, address) external returns (bytes32[] memory, int256);
    function deallocate(bytes memory data, uint256 assets, bytes4, address) external returns (bytes32[] memory, int256);
    function requestDeposit(uint256 assets) external;
    function requestWithdraw(uint256 shares) external;
    function setAdapterCurator(address newAdapterCurator) external;
    function setSkimRecipient(address newSkimRecipient) external;
    function skim(address token) external;
    function pullClaimableShares() external;
    function pullClaimableEurc() external;
}
