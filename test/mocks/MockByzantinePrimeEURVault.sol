// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 [Byzantine Finance]
pragma solidity ^0.8.0;

import {ERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IByzantinePrimeEURVault} from "../../src/interfaces/IByzantinePrimeEURVault.sol";
import {IReceiveSharesGate, ISendSharesGate, IReceiveAssetsGate, ISendAssetsGate} from "../../src/interfaces/IGate.sol";

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

    /// @dev Gate errors, mirroring the real vault's.
    error SendAssetsBlocked();
    error ReceiveSharesBlocked();
    error SendSharesBlocked();
    error ReceiveAssetsBlocked();
    error CannotSendShares();
    error CannotReceiveShares();

    /// @dev Mirrors the real ByzantinePrimeEURVault: bpEUR has 18 decimals, EURC has 6.
    uint256 private constant ONE_SHARE = 1e18;
    uint256 private constant ONE_STABLE = 1e6;

    /// @dev The asset that the vault holds and manages.
    address public immutable asset;

    /// @dev Deposit fee in basis points, applied at request time.
    uint16 internal _depositFeeBps;
    /// @dev Withdraw fee in basis points, applied at settlement on the gross PPS-derived payout.
    uint16 internal _withdrawFeeBps;
    /// @dev Hedge swap fee in basis points, applied as a FLAT HAIRCUT on every deposit and
    ///      withdrawal at settlement.
    /// @dev Simplification vs real: the real vault charges this fee ONLY on the unmatched net flow
    ///      within a batch (matched deposits/withdrawals pay nothing).
    ///      This mock applies the haircut flatly to every ticket.
    ///      It thus OVER-charges relative to the real when deposits and withdrawals offset within a batch.
    uint16 internal _hedgeSwapFeeBps;

    /// @dev The state of the vault.
    VaultState public override vaultState;
    /// @dev The current batch id.
    uint256 public override currentBatchId = 1;

    /// @dev Total EURC the vault recognizes as backing the outstanding bpEUR supply.
    ///      Differs from `IERC20(asset).balanceOf(address(this))` because it excludes:
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

    /// @dev Gate-blocked deposit settlements park the minted bpEUR here.
    ///      For simplicity, we assume `owner == receiver` in every test scenario.
    mapping(address receiver => uint256) internal _claimableShares;

    /// @dev Gate-blocked withdraw settlements park the EURC payout here.
    ///      For simplicity, we assume `owner == receiver` in every test scenario.
    mapping(address receiver => uint256) internal _claimableEurc;

    /// @dev Gate flags. When `true`, settlement parks the relevant asset into the matching `claimable*`
    ///      mapping instead of transferring directly to the receiver.
    bool public receiveSharesBlocked;
    bool public receiveAssetsBlocked;

    /// @dev Gate addresses mirroring the real vault's storage. `address(0)` = gateless (default).
    address public receiveSharesGate;
    address public sendSharesGate;
    address public receiveAssetsGate;
    address public sendAssetsGate;

    /// @dev DNT snapshot, populated by `executeDnt` and cleared by `closeBatch`. Mirrors the real vault's
    ///      `dntNavEffEurc` / `dntSupplyPreBatch`. `_dntBatchId == 0` means "no snapshot active"
    uint256 internal _dntNavSnapshot;
    uint256 internal _dntSupplySnapshot;
    uint256 internal _dntBatchId;

    /* CONSTRUCTOR */

    constructor(address asset_, uint16 depositFeeBps_) ERC20("Byzantine Prime EUR", "bpEUR") {
        asset = asset_;
        _depositFeeBps = depositFeeBps_;
    }

    /* VIEW FUNCTIONS */

    function depositFeeBps() external view override returns (uint16) {
        return _depositFeeBps;
    }

    /// @dev Not on `IByzantinePrimeEURVault` (the adapter does not read this directly), but exposed
    ///      so tests can fuzz / assert against it.
    function withdrawFeeBps() external view returns (uint16) {
        return _withdrawFeeBps;
    }

    /// @dev Not on `IByzantinePrimeEURVault`. Exposed for tests to fuzz / assert against.
    function hedgeSwapFeeBps() external view returns (uint16) {
        return _hedgeSwapFeeBps;
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

    /// @dev Mirrors the real vault's gate checks: `address(0)` = gateless.
    function canReceiveShares(address receiver) public view returns (bool) {
        address gate = receiveSharesGate;
        if (gate == address(0)) return true;
        return IReceiveSharesGate(gate).canReceiveShares(receiver);
    }

    function canSendShares(address sender) public view returns (bool) {
        address gate = sendSharesGate;
        if (gate == address(0)) return true;
        return ISendSharesGate(gate).canSendShares(sender);
    }

    function canReceiveAssets(address receiver) public view returns (bool) {
        address gate = receiveAssetsGate;
        if (gate == address(0)) return true;
        return IReceiveAssetsGate(gate).canReceiveAssets(receiver);
    }

    function canSendAssets(address sender) public view returns (bool) {
        address gate = sendAssetsGate;
        if (gate == address(0)) return true;
        return ISendAssetsGate(gate).canSendAssets(sender);
    }

    /// @dev When a DNT snapshot is active, conversions read the locked NAV/supply so
    ///      PPS quotes are stable across chunked finalization
    function convertToAssets(uint256 shares) public view override returns (uint256) {
        uint256 supply = _conversionSupply();
        if (supply == 0) return (shares * ONE_STABLE) / ONE_SHARE;
        uint256 nav = _dntBatchId != 0 ? _dntNavSnapshot : totalEurcBacking;
        return (shares * nav) / supply;
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        uint256 supply = _conversionSupply();
        uint256 nav = _dntBatchId != 0 ? _dntNavSnapshot : totalEurcBacking;
        if (supply == 0 || nav == 0) return (assets * ONE_SHARE) / ONE_STABLE;
        return (assets * supply) / nav;
    }

    /* EXTERNAL FUNCTIONS */

    /// @dev pulls `assets` of EURC, applies the deposit fee (mulDivUp), queues net for the active batch.
    ///      Active batch matches the adapter's `_activeBatchId`: currentBatchId when idle, nextBatchId in DNT.
    function requestDeposit(uint256 assets, address receiver) external override {
        if (assets == 0) revert ZeroAssets();
        if (!canSendAssets(msg.sender)) revert SendAssetsBlocked();
        if (!canReceiveShares(receiver)) revert ReceiveSharesBlocked();
        IERC20(asset).transferFrom(msg.sender, address(this), assets);
        uint256 fee = _mulDivUp(assets, _depositFeeBps, 10_000);
        uint256 net = assets - fee;
        uint256 batchId = _targetBatchId();
        batchDepositEurc[batchId] += net;
        batchUserDeposit[batchId][receiver] += net;
        // fees stay on the vault but are excluded from `totalEurcBacking`.
    }

    /// @dev burns `shares` from `owner` immediately and records the queued payout for `receiver`.
    function requestWithdraw(uint256 shares, address receiver, address owner) external override {
        if (shares == 0) revert ZeroShares();
        if (!canSendShares(owner)) revert SendSharesBlocked();
        if (!canReceiveAssets(receiver)) revert ReceiveAssetsBlocked();
        if (owner != msg.sender) {
            uint256 allowed = allowance(owner, msg.sender);
            if (allowed != type(uint256).max) _approve(owner, msg.sender, allowed - shares);
        }
        _burn(owner, shares);
        uint256 batchId = _targetBatchId();
        batchWithdrawShares[batchId] += shares;
        batchUserWithdraw[batchId][receiver] += shares;
    }

    /// @dev Mirrors the real vault: claims `msg.sender`'s claimable shares and sends them to `receiver`.
    function claimDepositShares(address receiver) external override {
        if (!canReceiveShares(receiver)) revert ReceiveSharesBlocked();
        uint256 amount = _claimableShares[msg.sender];
        require(amount > 0, "nothing claimable");
        _claimableShares[msg.sender] = 0;
        _transfer(address(this), receiver, amount);
    }

    /// @dev Mirrors the real vault: claims `msg.sender`'s claimable EURC and sends it to `receiver`.
    function claimWithdraw(address receiver) external override {
        if (!canReceiveAssets(receiver)) revert ReceiveAssetsBlocked();
        uint256 amount = _claimableEurc[msg.sender];
        require(amount > 0, "nothing claimable");
        _claimableEurc[msg.sender] = 0;
        IERC20(asset).transfer(receiver, amount);
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
    /// @dev Swap fee (`_hedgeSwapFeeBps`) is applied as a flat haircut on every deposit:
    ///      `effectiveAssets = net * (10_000 - feeBps) / 10_000`.
    function processDepositChunk(address[] calldata receivers, uint256 maxTickets) external {
        require(vaultState == VaultState.DntInProgress, "no DNT");
        uint256 batchId = _dntBatchId;
        uint256 swapFee = _hedgeSwapFeeBps;
        uint256 processed = 0;
        for (uint256 i; i < receivers.length && processed < maxTickets; ++i) {
            address rec = receivers[i];
            uint256 net = batchUserDeposit[batchId][rec];
            if (net == 0) continue;
            uint256 effectiveAssets = swapFee == 0 ? net : (net * (10_000 - swapFee)) / 10_000;
            uint256 sharesToMint = _dntSupplySnapshot == 0
                ? (effectiveAssets * ONE_SHARE) / ONE_STABLE
                : (effectiveAssets * _dntSupplySnapshot) / _dntNavSnapshot;
            if (receiveSharesBlocked || !canReceiveShares(rec)) {
                _mint(address(this), sharesToMint);
                _claimableShares[rec] += sharesToMint;
            } else {
                _mint(rec, sharesToMint);
            }
            totalEurcBacking += effectiveAssets;
            batchDepositEurc[batchId] -= net;
            delete batchUserDeposit[batchId][rec];
            ++processed;
        }
    }

    /// @dev Mirrors `_processWithdrawTicketsChunk`: pays EURC out using the locked snapshot WITHOUT
    ///      closing the batch. Same per-receiver aggregation as `processDepositChunk`.
    /// @dev Fees compose in real-vault order: swap fee (`_hedgeSwapFeeBps`) is applied first as a
    ///      flat haircut on the gross PPS-derived `owed`, then the protocol withdraw fee (`_withdrawFeeBps`)
    ///      is applied on the post-swap amount.
    ///      `totalEurcBacking` decreases by the gross `owed` — both the swap loss and the protocol
    ///      fee stay on the vault's token balance.
    function processWithdrawChunk(address[] calldata receivers, uint256 maxTickets) external {
        require(vaultState == VaultState.DntInProgress, "no DNT");
        uint256 batchId = _dntBatchId;
        uint256 supplyAtBurn = _dntSupplySnapshot;
        uint256 swapFee = _hedgeSwapFeeBps;
        uint256 feeBps = _withdrawFeeBps;
        uint256 processed = 0;
        for (uint256 i; i < receivers.length && processed < maxTickets; ++i) {
            address rec = receivers[i];
            uint256 userShares = batchUserWithdraw[batchId][rec];
            if (userShares == 0) continue;
            uint256 owed = supplyAtBurn == 0 ? 0 : (userShares * _dntNavSnapshot) / supplyAtBurn;
            uint256 afterSwap = swapFee == 0 ? owed : (owed * (10_000 - swapFee)) / 10_000;
            uint256 fee = feeBps == 0 ? 0 : _mulDivUp(afterSwap, feeBps, 10_000);
            uint256 toPay = afterSwap - fee;
            if (receiveAssetsBlocked || !canReceiveAssets(rec)) {
                _claimableEurc[rec] += toPay;
            } else {
                IERC20(asset).transfer(rec, toPay);
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

    /// @dev Mirrors the real vault's `setGates` (no governance / vault-state check in the mock).
    function setGates(
        address _receiveSharesGate,
        address _sendSharesGate,
        address _receiveAssetsGate,
        address _sendAssetsGate
    ) external {
        receiveSharesGate = _receiveSharesGate;
        sendSharesGate = _sendSharesGate;
        receiveAssetsGate = _receiveAssetsGate;
        sendAssetsGate = _sendAssetsGate;
    }

    /* SETTER FUNCTIONS */

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

    /// @dev Set the withdraw fee basis points
    function setWithdrawFeeBps(uint16 bps) external {
        _withdrawFeeBps = bps;
    }

    /// @dev Set the hedge swap fee basis points
    function setHedgeSwapFeeBps(uint16 bps) external {
        _hedgeSwapFeeBps = bps;
    }

    /* INTERNAL FUNCTIONS */

    /// @dev Mirrors the real vault's `_update`: every bpEUR transfer (incl. mints) is gated.
    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && !canSendShares(from)) revert CannotSendShares();
        if (to != address(0) && !canReceiveShares(to)) revert CannotReceiveShares();
        super._update(from, to, value);
    }

    function _targetBatchId() internal view returns (uint256) {
        return vaultState == VaultState.NormalIdle ? currentBatchId : currentBatchId + 1;
    }

    /// @dev Mirrors the real vault's `_conversionSupplyForPps`: during DNT return the snapshot supply;
    ///      outside DNT, should include pending withdraw.
    function _conversionSupply() internal view returns (uint256) {
        if (_dntBatchId != 0) return _dntSupplySnapshot;
        return totalSupply() + batchWithdrawShares[currentBatchId];
    }

    function _mulDivUp(uint256 x, uint256 y, uint256 d) internal pure returns (uint256) {
        return (x * y + (d - 1)) / d;
    }
}
