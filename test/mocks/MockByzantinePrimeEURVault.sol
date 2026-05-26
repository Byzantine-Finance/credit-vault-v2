// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 [Byzantine Finance]
pragma solidity ^0.8.0;

import {ERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IByzantinePrimeEURVault} from "../../src/interfaces/IByzantinePrimeEURVault.sol";

/// @title MockByzantinePrimeEURVault
/// @notice Mock implementation of an async EUR vault used by ByzantineEurVaultAdapter.
/// @dev Models the real two-phase finalize flow:
///      1. `executeDnt` snapshots NAV / supply and transitions to `DntInProgress` (mirrors
///         `executeDailyNetTransfer`).
///      2. `processDepositChunk` / `processWithdrawChunk` settle tickets WITHOUT closing the batch (mirror
///         `_processDepositTicketsChunk` / `_processWithdrawTicketsChunk` — chunked finalize).
///      3. `closeBatch` advances `currentBatchId` and returns to `NormalIdle` (mirrors
///         `_closeBatchAndUnlock`).
/// @dev Two global gate flags (`receiveSharesBlocked` / `receiveAssetsBlocked`) to simulate gate-blocked scenarios.
/// @dev `setShareRate` lets tests simulate yield / loss without changing supply (only affects holders outside
///      the locked DNT snapshot window).
contract MockByzantinePrimeEURVault is ERC20, IByzantinePrimeEURVault {
    /// @dev Custom errors
    error ZeroAssets();
    error ZeroShares();

    /// @dev Mirrors the real ByzantinePrimeEURVault: bpEUR has 18 decimals, EURC has 6.
    uint256 private constant ONE_SHARE = 1e18;
    uint256 private constant ONE_STABLE = 1e6;

    address public immutable underlying;
    uint16 internal _depositFeeBps;
    VaultState public override vaultState;
    uint256 public override currentBatchId = 1;

    /// @dev Total EURC the vault recognizes as backing the outstanding bpEUR supply.
    ///      Differs from `IERC20(underlying).balanceOf(address(this))` because it excludes:
    ///      - per-batch queued deposits (not yet minted into shares),
    ///      - per-batch already-burned shares' future payouts (still owed),
    ///      - collected fees.
    uint256 public totalEurcBacking;

    /// @dev Per-batch aggregate of net EURC queued by `requestDeposit` (after deposit fee).
    mapping(uint256 batchId => uint256) public batchDepositEurc;

    /// @dev Per-(batch, receiver) breakdown of `batchDepositEurc`.
    mapping(uint256 batchId => mapping(address receiver => uint256)) public batchUserDeposit;

    /// @dev Per-batch aggregate of bpEUR burned at `requestWithdraw` time, awaiting EURC payout.
    mapping(uint256 batchId => uint256) public batchWithdrawShares;

    /// @dev Per-(batch, receiver) breakdown of `batchWithdrawShares`.
    mapping(uint256 batchId => mapping(address receiver => uint256)) public batchUserWithdraw;

    /// @dev Gate-blocked deposit settlements park the minted bpEUR here (keyed by receiver). Drained by
    ///      `claimDepositShares(receiver)`. Mirrors the real vault's `claimableShares[owner]`.
    mapping(address owner => uint256) internal _claimableShares;

    /// @dev Gate-blocked withdraw settlements park the EURC payout here (keyed by receiver). Drained by
    ///      `claimWithdraw(receiver)`. Mirrors the real vault's `claimableEurc[owner]`.
    mapping(address owner => uint256) internal _claimableEurc;

    /// @dev Gate flags. When `true`, settlement parks the relevant asset into the matching `claimable*`
    ///      mapping instead of transferring directly to the receiver.
    /// @dev Simply toggle the global gate flags to simulate gate-blocked scenarios.
    bool public receiveSharesBlocked;
    bool public receiveAssetsBlocked;

    /// @dev DNT snapshot, populated by `executeDnt` and cleared by `closeBatch`. Mirrors the real vault's
    ///      `dntNavEffEurc` / `dntSupplyPreBatch`. `_dntBatchId == 0` means "no snapshot active"
    uint256 internal _dntNavSnapshot;
    uint256 internal _dntSupplySnapshot;
    uint256 internal _dntBatchId;

    constructor(address asset_, uint16 depositFeeBps_) ERC20("Byzantine Prime EUR", "bpEUR") {
        underlying = asset_;
        _depositFeeBps = depositFeeBps_;
    }

    /* VIEW FUNCTIONS */

    function asset() external view override returns (address) {
        return underlying;
    }

    function depositFeeBps() external view override returns (uint16) {
        return _depositFeeBps;
    }

    function nextBatchId() external view override returns (uint256) {
        return currentBatchId + 1;
    }

    function claimableShares(address owner) external view override returns (uint256) {
        return _claimableShares[owner];
    }

    function claimableEurc(address owner) external view override returns (uint256) {
        return _claimableEurc[owner];
    }

    /// @dev When a DNT snapshot is active, conversions read the locked NAV/supply so
    ///      PPS quotes are stable across chunked finalization — exactly like the real vault's
    ///      `_conversionSupplyForPps`. Outside DNT, they use live state.
    function convertToAssets(uint256 shares) public view override returns (uint256) {
        if (_dntBatchId != 0) {
            if (_dntSupplySnapshot == 0) return (shares * ONE_STABLE) / ONE_SHARE;
            return (shares * _dntNavSnapshot) / _dntSupplySnapshot;
        }
        uint256 supply = totalSupply();
        if (supply == 0) return (shares * ONE_STABLE) / ONE_SHARE;
        return (shares * totalEurcBacking) / supply;
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        if (_dntBatchId != 0) {
            if (_dntSupplySnapshot == 0 || _dntNavSnapshot == 0) return (assets * ONE_SHARE) / ONE_STABLE;
            return (assets * _dntSupplySnapshot) / _dntNavSnapshot;
        }
        uint256 supply = totalSupply();
        if (supply == 0 || totalEurcBacking == 0) return (assets * ONE_SHARE) / ONE_STABLE;
        return (assets * supply) / totalEurcBacking;
    }

    /* EXTERNAL FUNCTIONS */

    /// @dev pulls `assets` of EURC, applies the deposit fee (mulDivUp), queues net for the active batch.
    ///      Active batch matches the adapter's `_activeBatchId`: currentBatchId when idle, nextBatchId in DNT.
    function requestDeposit(uint256 assets, address receiver) external override {
        if (assets == 0) revert ZeroAssets();
        IERC20(underlying).transferFrom(msg.sender, address(this), assets);
        uint256 fee = _mulDivUp(assets, _depositFeeBps, 10_000);
        uint256 net = assets - fee;
        uint256 batchId = _targetBatchId();
        batchDepositEurc[batchId] += net;
        batchUserDeposit[batchId][receiver] += net;
        // fees stay on the vault but are excluded from `totalEurcBacking`.
    }

    /// @dev burns `shares` from `owner` immediately and records the queued payout for `receiver`.
    ///      Note: in the real vault, share price is preserved because the future EURC owed is locked at settlement.
    ///      We faithfully reproduce that by not decreasing `totalEurcBacking` here; payouts come out of backing
    ///      at settlement time.
    function requestWithdraw(uint256 shares, address receiver, address owner) external override {
        if (shares == 0) revert ZeroShares();
        if (owner != msg.sender) {
            uint256 allowed = allowance(owner, msg.sender);
            if (allowed != type(uint256).max) _approve(owner, msg.sender, allowed - shares);
        }
        _burn(owner, shares);
        uint256 batchId = _targetBatchId();
        batchWithdrawShares[batchId] += shares;
        batchUserWithdraw[batchId][receiver] += shares;
    }

    function claimDepositShares(address receiver) external override {
        uint256 amount = _claimableShares[receiver];
        require(amount > 0, "nothing claimable");
        _claimableShares[receiver] = 0;
        _transfer(address(this), receiver, amount);
    }

    function claimWithdraw(address receiver) external override {
        uint256 amount = _claimableEurc[receiver];
        require(amount > 0, "nothing claimable");
        _claimableEurc[receiver] = 0;
        IERC20(underlying).transfer(receiver, amount);
    }

    /* FX HEDGING FUNCTIONS */

    /// @dev Mirrors `executeDailyNetTransfer`'s state effects: transitions to `DntInProgress` and
    ///      locks the NAV / supply-pre-batch snapshot so `convertToAssets` returns stable values across
    ///      chunked finalize. `supplyPreBatch` includes shares that were burned at request time.
    function executeDnt() external {
        require(vaultState == VaultState.NormalIdle, "DNT in progress");
        uint256 batchId = currentBatchId;
        _dntNavSnapshot = totalEurcBacking;
        _dntSupplySnapshot = totalSupply() + batchWithdrawShares[batchId];
        _dntBatchId = batchId;
        vaultState = VaultState.DntInProgress;
    }

    /// @dev Mirrors `_processDepositTicketsChunk`: mints bpEUR using the locked snapshot WITHOUT
    ///      closing the batch. Per-receiver routing matches the real vault's gate logic — when
    ///      `receiveSharesBlocked[rec]` is `true`, shares are minted to this contract and credited as
    ///      `claimableShares[rec]`; otherwise they are minted directly to the receiver.
    function processDepositChunk(address[] calldata receivers, uint256 maxTickets) external {
        require(vaultState == VaultState.DntInProgress, "no DNT");
        uint256 batchId = _dntBatchId;
        uint256 processed = 0;
        for (uint256 i; i < receivers.length && processed < maxTickets; ++i) {
            address rec = receivers[i];
            uint256 net = batchUserDeposit[batchId][rec];
            if (net == 0) continue;
            // Shares minted using locked snapshot
            uint256 sharesToMint =
                _dntSupplySnapshot == 0 ? (net * ONE_SHARE) / ONE_STABLE : (net * _dntSupplySnapshot) / _dntNavSnapshot;
            if (receiveSharesBlocked) {
                _mint(address(this), sharesToMint);
                _claimableShares[rec] += sharesToMint;
            } else {
                _mint(rec, sharesToMint);
            }
            totalEurcBacking += net;
            batchDepositEurc[batchId] -= net;
            delete batchUserDeposit[batchId][rec];
            ++processed;
        }
    }

    /// @dev Mirrors `_processWithdrawTicketsChunk`: pays EURC out using the locked snapshot
    ///      WITHOUT closing the batch. The shares were already burned at `requestWithdraw` time; this call
    ///      only releases the matching EURC payout. Per-receiver routing mirrors the share path: blocked
    ///      receivers get the EURC parked in `claimableEurc`, the rest get it transferred directly.
    function processWithdrawChunk(address[] calldata receivers, uint256 maxTickets) external {
        require(vaultState == VaultState.DntInProgress, "no DNT");
        uint256 batchId = _dntBatchId;
        uint256 supplyAtBurn = _dntSupplySnapshot;
        uint256 processed = 0;
        for (uint256 i; i < receivers.length && processed < maxTickets; ++i) {
            address rec = receivers[i];
            uint256 userShares = batchUserWithdraw[batchId][rec];
            if (userShares == 0) continue;
            uint256 owed = supplyAtBurn == 0 ? 0 : (userShares * _dntNavSnapshot) / supplyAtBurn;
            if (receiveAssetsBlocked) {
                _claimableEurc[rec] += owed;
            } else {
                IERC20(underlying).transfer(rec, owed);
            }
            totalEurcBacking -= owed;
            batchWithdrawShares[batchId] -= userShares;
            delete batchUserWithdraw[batchId][rec];
            ++processed;
        }
    }

    /// @dev Mirrors `_closeBatchAndUnlock`: bumps `currentBatchId`, returns to `NormalIdle`,
    ///      clears the snapshot. Requires all ticket aggregates for the active batch to be drained.
    function closeBatch() external {
        require(vaultState == VaultState.DntInProgress, "no DNT");
        uint256 batchId = _dntBatchId;
        require(batchDepositEurc[batchId] == 0, "deposits not finalized");
        require(batchWithdrawShares[batchId] == 0, "withdraws not finalized");
        currentBatchId = batchId + 1;
        vaultState = VaultState.NormalIdle;
        _dntNavSnapshot = 0;
        _dntSupplySnapshot = 0;
        _dntBatchId = 0;
    }

    /* GATE SIMULATION */

    /// @dev Simulate gate-blocked scenario for shares
    function setReceiveSharesBlocked(bool blocked) external {
        receiveSharesBlocked = blocked;
    }

    /// @dev Simulate gate-blocked scenario for assets
    function setReceiveAssetsBlocked(bool blocked) external {
        receiveAssetsBlocked = blocked;
    }

    /// @dev Low-level state-only toggle. Does NOT populate the DNT snapshot — use `executeDnt` for that.
    ///      Useful when a test only needs the `_activeBatchId` selector to switch to `nextBatchId`.
    function setVaultState(VaultState s) external {
        vaultState = s;
    }

    /// @dev tweaks the share price by directly adjusting the backing (yield = positive delta, loss = negative).
    ///      Only affects existing holders; queued batch state is not impacted.
    function setShareRate(int256 backingDelta) external {
        if (backingDelta >= 0) {
            totalEurcBacking += uint256(backingDelta);
        } else {
            totalEurcBacking -= uint256(-backingDelta);
        }
    }

    /// @dev Set the deposit fee basis points
    function setDepositFeeBps(uint16 bps) external {
        _depositFeeBps = bps;
    }

    /* INTERNAL FUNCTIONS */

    function _targetBatchId() internal view returns (uint256) {
        return vaultState == VaultState.NormalIdle ? currentBatchId : currentBatchId + 1;
    }

    function _mulDivUp(uint256 x, uint256 y, uint256 d) internal pure returns (uint256) {
        return (x * y + (d - 1)) / d;
    }
}
