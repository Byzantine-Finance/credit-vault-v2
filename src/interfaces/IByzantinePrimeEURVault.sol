// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

/// @dev Minimal interface for ByzantinePrimeEURVault.
///      Balances are read via IERC20 separately.
interface IByzantinePrimeEURVault {
    enum VaultState {
        NormalIdle,
        DntInProgress
    }

    /* VIEW */

    function asset() external view returns (address);
    function vaultState() external view returns (VaultState);
    function currentBatchId() external view returns (uint256);
    function nextBatchId() external view returns (uint256);
    function depositFeeBps() external view returns (uint16);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function claimableEurc(address owner) external view returns (uint256);
    function claimableShares(address owner) external view returns (uint256);
    function receiveSharesGate() external view returns (address);
    function sendSharesGate() external view returns (address);
    function receiveAssetsGate() external view returns (address);
    function sendAssetsGate() external view returns (address);

    /* FUNCTIONS */

    function requestDeposit(uint256 assets, address receiver) external;
    function requestWithdraw(uint256 shares, address receiver, address owner) external;
    function claimWithdraw(address receiver) external;
    function claimDepositShares(address receiver) external;
}
