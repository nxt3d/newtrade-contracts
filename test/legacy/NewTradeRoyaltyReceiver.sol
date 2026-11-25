// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Fixed ERC-2981 recipient for routed creator royalties.
///
/// WHY A SEPARATE CONTRACT
/// A Seaport listing must keep a distinct consideration item paying the FULL
/// ERC-2981 royalty, so marketplaces keep recognising the gross creator fee.
/// The escrow is already consideration[0] (OpenSea requires offerer == first
/// recipient) and recipients must be unique, so the royalty needs its own
/// address. That address is this contract, and it is the same for every routed
/// bundle.
///
/// WHY LEDGER CREDITS INSTEAD OF A SWEEP
/// Seaport transfers offer items BEFORE consideration items, so when the
/// escrow's first-exit callback runs the royalty has not arrived yet and could
/// not be swept. The escrow instead writes the split it snapshotted at listing
/// into this ledger; Seaport reverts the whole fulfilment unless every
/// consideration item is delivered, so a credit written here implies the gross
/// royalty landed in the same transaction. Balances are never inspected, which
/// also makes fulfillAvailableAdvancedOrders' same-recipient aggregation safe.
///
/// NO ADMIN PATH
/// Only the bound controller (the escrow) can write credits, and only the
/// credited account can move its own balance. Nobody can seize, redirect or
/// skim: there is deliberately no owner and no rescue function. The accepted
/// consequence: value that arrives without a matching credit - native sent by
/// Seaport for a non-routed order, or any ERC-20 pushed in directly - is
/// credited to nobody and stays here forever. That only ever leaves the
/// contract holding more than the sum of its credits, never less.
///
/// SEAPORT is pinned here as well as in NewTradeEscrowV2. The two constants
/// must stay equal: a routed native listing on any other Seaport would be
/// refused by `receive()` and the whole fill would revert (fail-closed).
contract NewTradeRoyaltyReceiver {
    using SafeERC20 for IERC20;

    error ControllerOnly();
    error Unauthorized();
    error ZeroAddress();
    error NothingToWithdraw();
    error Reentrancy();
    error TransferFailed();

    event RoyaltyCredited(uint256 indexed bundleId, address indexed account, address indexed token, uint256 amount);
    event RoyaltyWithdrawn(address indexed account, address indexed token, uint256 amount);

    address public constant SEAPORT = 0x0000000000000068F116a894984e2DB1123eB395;
    bytes32 private constant ENTRY_LOCK_SLOT = keccak256("newtrade.v2.royalty-receiver.transient.entry");

    address public immutable bootstrap;
    address public controller;
    mapping(address account => mapping(address token => uint256 amount)) private _claimable;

    constructor(address bootstrap_) {
        if (bootstrap_ == address(0)) revert ZeroAddress();
        bootstrap = bootstrap_;
    }

    /// @notice Bound once by the deployer to the escrow proxy, exactly like the
    /// receipt and the vault.
    function bindController(address controller_) external {
        if (msg.sender != bootstrap || controller != address(0) || controller_.code.length == 0) {
            revert ControllerOnly();
        }
        controller = controller_;
    }

    /// @notice Native consideration arrives from Seaport only. Anything else is
    /// refused so stray sends cannot strand value here.
    receive() external payable {
        if (msg.sender != SEAPORT) revert Unauthorized();
    }

    /// @notice Written by the escrow at the bundle's first exit from the values it
    /// snapshotted at listing. Zero amounts are skipped, non-zero ones require a
    /// real account.
    function credit(
        uint256 bundleId,
        address token,
        address creator,
        uint256 creatorNet,
        address treasury,
        uint256 serviceFee
    ) external {
        if (msg.sender != controller) revert ControllerOnly();
        if (creatorNet != 0) {
            if (creator == address(0)) revert ZeroAddress();
            _claimable[creator][token] += creatorNet;
            emit RoyaltyCredited(bundleId, creator, token, creatorNet);
        }
        if (serviceFee != 0) {
            if (treasury == address(0)) revert ZeroAddress();
            _claimable[treasury][token] += serviceFee;
            emit RoyaltyCredited(bundleId, treasury, token, serviceFee);
        }
    }

    function claimable(address account, address token) external view returns (uint256) {
        return _claimable[account][token];
    }

    /// @notice Pull withdrawal for the caller's own balance. Locked and CEI.
    function withdraw(address token) external returns (uint256 amount) {
        if (_tload(ENTRY_LOCK_SLOT) != 0) revert Reentrancy();
        _tstore(ENTRY_LOCK_SLOT, 1);
        amount = _claimable[msg.sender][token];
        if (amount == 0) revert NothingToWithdraw();
        _claimable[msg.sender][token] = 0; // effects before interaction
        if (token == address(0)) {
            (bool ok,) = msg.sender.call{value: amount}("");
            if (!ok) revert TransferFailed();
        } else {
            IERC20(token).safeTransfer(msg.sender, amount);
        }
        emit RoyaltyWithdrawn(msg.sender, token, amount);
        _tstore(ENTRY_LOCK_SLOT, 0);
    }

    function _tload(bytes32 slot) private view returns (uint256 value) {
        assembly ("memory-safe") {
            value := tload(slot)
        }
    }

    function _tstore(bytes32 slot, uint256 value) private {
        assembly ("memory-safe") {
            tstore(slot, value)
        }
    }
}
