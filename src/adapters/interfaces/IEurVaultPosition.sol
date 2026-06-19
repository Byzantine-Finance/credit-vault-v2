// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 [Byzantine Finance]
pragma solidity >=0.5.0;

interface IEurVaultPosition {
    /* ERRORS */

    error NotAdapter();
    error AlreadyInitialized();
    error NotSettled();
    error BatchMismatch();

    /* VIEWS */

    function adapter() external view returns (address);
    function eurVault() external view returns (address);
    function asset() external view returns (address);
    function batchId() external view returns (uint256);
    function pendingEurc() external view returns (uint256);
    function pendingShares() external view returns (uint256);
    function settled() external view returns (bool);
    function value() external view returns (uint256);

    /* FUNCTIONS */

    function initDeposit(uint256 assets) external returns (uint256 batchId_, uint256 netAssets);
    function initWithdraw(uint256 shares) external returns (uint256 batchId_);
    function addDeposit(uint256 assets) external returns (uint256 netAssets);
    function addWithdraw(uint256 shares) external;
    function sweep() external returns (uint256 shares, uint256 eurc);
}
