// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Payout, Bundle, RoyaltySnapshot} from "./NewTradeV2Types.sol";
import {NewTradeBundle} from "./NewTradeBundle.sol";
import {INewTradeVaultV2} from "./interfaces/INewTradeVaultV2.sol";

/// @notice NewTradeEscrowV2's sequential storage, shared by the escrow and by
/// the one-shot NewTradeEscrowV2Seeder that runs inside its upgrade
/// (escrow-fee-from-proceeds-sep25). Moved here VERBATIM, in the same order and
/// with the same types, from NewTradeEscrowV2: the OpenZeppelin parents keep
/// their state in ERC-7201 namespaces and take no sequential slot, so these
/// still start at slot 0. `forge inspect … storage-layout` against 4c202bc is
/// the check (every existing slot identical; two appended).
abstract contract NewTradeEscrowV2Storage {
    // Direct storage for the undeployed V2 beta. Future implementations must preserve
    // field order and types and only append fields; no NewTrade storage gap is reserved.
    // OpenZeppelin upgradeable parents retain their own namespaced storage.
    mapping(uint256 => Bundle) internal _bundles;
    mapping(uint256 => Payout[]) internal _payouts;
    mapping(address => bool) internal _paymentAllowed;
    uint256 internal _counter;
    uint96 internal _protocolFeeBps;
    address internal _treasury;
    // COMPATIBILITY ALIAS: `_receipt` and the `receipt`-named external
    // selectors below refer to the NewTradeBundle collection ("Bundle" is the
    // product name). They keep their legacy names because the deployed
    // 0x3FF1...175f collection and the app's pinned escrow ABI call them and
    // an in-place escrow upgrade must keep serving them.
    NewTradeBundle internal _receipt;
    // partial-release-oct20: the declared type is now the vault INTERFACE. Same
    // slot, same offset, still an address; only the name in the storage layout
    // changes (`contract NewTradeV2Vault` -> `contract INewTradeVaultV2`).
    INewTradeVaultV2 internal _vault;
    address internal _seaportZone;
    address internal _accountRegistry;
    address internal _accountImplementation;
    bool internal _freshAccountsEnabled;
    bool internal _upgradesLocked;
    mapping(address => bytes32) internal _trustedRegistryCodehash;
    mapping(address => bytes32) internal _trustedImplementationCodehash;
    address internal _accountProxy;

    /**
     * Appended AFTER every pre-existing variable, so no existing slot, packing
     * offset or Bundle member moves. The deployed implementation is a build of
     * this file, so its layout is this file's layout.
     *
     * Zero is the legacy value and is never written by a migration: every order
     * listed before this upgrade keeps startTime 0 and therefore keeps hashing
     * to exactly the hash already recorded onchain. Only a listing that is
     * explicitly repaired, or one created after the upgrade, holds 1.
     */
    mapping(uint256 => uint64) internal _orderStartTimes;

    /**
     * One-shot guard for the fee amendment, appended AFTER _orderStartTimes so
     * no existing slot or packing offset moves.
     *
     * Deliberately SEPARATE from _orderStartTimes. The completed repair set that
     * mapping to 1 and it must stay 1; the amendment must never reset, reuse or
     * depend on relaxing the repair's guard. Two mechanisms, two latches.
     */
    mapping(uint256 => bool) internal _feeAmended;

    /**
     * Step 1: append-only slots for the OpenSea-compatible flow. Nothing above
     * moves, so bundle 1 keeps its layout, hash reconstruction and reclaim.
     *
     * Bundle 1 reads zero from both new mappings, which is exactly its legacy
     * shape: zero conduit key, and an escrow-recipient amount it never had.
     */
    mapping(uint256 => bytes32) internal _bundleConduitKey;
    mapping(uint256 => uint256) internal _escrowRecipientAmount;
    mapping(address => mapping(address => uint256)) internal _claimable;

    /**
     * Step 12: EIP-1271. The signing digest of a listing -> its bundle.
     *
     * Written once at list(). It is a LOOKUP, never an authorization: entries
     * are not removed on a terminal transition, because isValidSignature
     * re-derives the digest from current state and re-reads the bundle and the
     * Seaport order status. A lingering entry for a bundle that has since been
     * issued, redeemed or reclaimed therefore stops validating on its own,
     * which is safer than depending on every exit path remembering to clear it.
     */
    mapping(bytes32 => uint256) internal _listingDigestBundle;

    /**
     * Creator-royalty service fee, appended AFTER _listingDigestBundle so no
     * existing slot, packing offset or Bundle member moves.
     *
     * _royaltyRouter / _royaltyServiceFeeBps are the LIVE policy and are read
     * only inside list() (and its quote views). _royaltySnapshots is written
     * once per routed listing and is the ONLY thing the first exit reads, so a
     * later policy change can never touch a listed bundle's economics. Bundles
     * listed before this upgrade read a zero router and take the legacy path.
     *
     * OPTION B (escrow-option-b-sep26): _royaltyRouter and _royaltyServiceFeeBps
     * are DEAD - routing is retired and nothing reads or writes them. They stay
     * in place (append-only layout). _royaltySnapshots now holds the creator
     * royalty frozen at list() (see RoyaltySnapshot).
     */
    address internal _royaltyRouter;
    uint16 internal _royaltyServiceFeeBps;
    mapping(uint256 => RoyaltySnapshot) internal _royaltySnapshots;

    // ---- escrow-fee-from-proceeds (append-only; nothing above moves) ----------
    /// The protocol fee frozen at `list()` for each bundle, deducted from the
    /// escrow item (consideration[0]) at first exit. Zero for every bundle
    /// listed before this upgrade (they keep paying the seller the full item).
    mapping(uint256 => uint256) internal _protocolFeeAmount;
    /// Per token, the sum of every account's `_claimable`: what the escrow owes.
    /// Written ONLY by `_creditOwed` / `_debitOwed` in NewTradeEscrowV2 (and seeded
    /// once, inside the upgrade, by NewTradeEscrowV2Seeder). `balance - _totalOwed`
    /// is surplus the admin may withdraw: the retained protocol fees and any
    /// stray funds, never proceeds.
    mapping(address => uint256) internal _totalOwed;
}
