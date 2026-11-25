// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {AcceptanceMode, AssetKind, ManifestEntry, ReleaseMode} from "./NewTradeV2Types.sol";
import {NewTradeV2VaultStorage} from "./NewTradeV2VaultStorage.sol";
import {VaultAdmission} from "./libraries/VaultAdmission.sol";
import {VaultCustodyIn} from "./libraries/VaultCustodyIn.sol";
import {
    IERC6551Registry,
    IERC6551Account,
    IERC6551OwnerAccount,
    IERC6551ExecutableAccount,
    ITokenboundAccountProxy
} from "./interfaces/IERC6551.sol";

/// @notice Upgradeable asset vault for the V2 escrow (partial-release-oct20, F-01).
///
/// Custody leaves PER ENTRY. Every manifest entry and the controlling NFT is
/// attempted in its own call frame with its own gas budget; an attempt that does
/// not complete leaves that entry's custody and accounting exactly as before, and
/// it can be tried again at any time. There is no "failed" state: an entry is
/// released, or still held. A bundle is closed when every entry and the NFT have
/// left.
///
/// Destinations are recorded once, at the first release, and never change for
/// an ordinary retry (anyone may retry). The one exception is the redeemer's
/// redirect (D2-B): while the controlling NFT is still held, the recorded
/// redeemer may send the manifest entries to an address of their choice.
///
/// Upgradeable (UUPS). The upgrader is whoever holds UPGRADER_ROLE on the
/// controller (the escrow): one role registry for both contracts (D8).
/// Storage is one ERC-7201 namespaced struct; `ManifestEntry` is FROZEN
/// (manifests are arrays of it), see the layout rules in the design, 2A.4.
contract NewTradeV2VaultV2 is Initializable, UUPSUpgradeable, IERC721Receiver, IERC1155Receiver {
    using SafeERC20 for IERC20;

    bytes4 private constant VALID_SIGNER_MAGIC = 0x523e3260;
    bytes32 private constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    /// Answered by every vault implementation; an upgrade to a contract that does
    /// not answer it (an escrow, the seeder, the claim NFT) is refused.
    bytes32 public constant VAULT_FAMILY = keccak256("newtrade.v2.vault");
    uint256 public constant MAX_MANIFEST_ENTRIES = 32;
    /// Bit 32 of a release mask is the controlling NFT; bits 0..31 are entries.
    uint256 private constant NFT_BIT = 1 << 32;

    // ---- gas rule (design 2.3; constants of the implementation, adjustable by upgrade) ----
    /// Budget of one attempt as it enters the proxy: an ERC-20 entry.
    uint256 private constant BUDGET_ERC20 = 200_000;
    /// Budget of one attempt as it enters the proxy: an ERC-721 or ERC-1155 entry, or the NFT.
    uint256 private constant BUDGET_NFT = 400_000;
    /// Set-up allowance taken off the gas left before an attempt.
    uint256 private constant GAS_OVERHEAD = 12_000;
    /// What the batch loop keeps for its own work after the last attempt.
    uint256 private constant GAS_RESERVE = 40_000;

    /// Transient lock slot; the same slot in every implementation (design 2A.1).
    bytes32 private constant LOCK_SLOT = keccak256("newtrade.v2.vault.transient.lock");

    error ControllerOnly();
    error InvalidManifest();
    error UnsupportedAsset();
    error AssetReserved();
    error TransferMismatch();
    error InvalidCallback();
    error MigrationUnavailable();
    error Reentrancy();
    error NoRelease();
    error InvalidMask();
    error NotRedeemer();
    error UpgradeRefused();
    error ZeroAddress();
    error GasTooLow();
    error ReleaseFailed();
    error InvalidDestination();

    event ReleaseBegun(uint256 indexed bundleId, ReleaseMode mode, address extrasTo, address nftTo);
    event EntryReleased(uint256 indexed bundleId, uint256 indexed index, address to);
    event EntryPending(uint256 indexed bundleId, uint256 indexed index);
    event ControllingNFTReleased(uint256 indexed bundleId, address to);
    event EntriesRedirected(uint256 indexed bundleId, address to);
    event BundleEmptied(uint256 indexed bundleId);
    event UpgradesLocked();

    modifier onlyController() {
        if (msg.sender != NewTradeV2VaultStorage.s().controller) revert ControllerOnly();
        _;
    }

    /// The outer lock: taken by every controller call that moves custody, held
    /// across the self-calls of a batch.
    modifier locked() {
        if (_tload(LOCK_SLOT) != 0) revert Reentrancy();
        _tstore(LOCK_SLOT, 1);
        _;
        _tstore(LOCK_SLOT, 0);
    }

    constructor() {
        _disableInitializers();
    }

    /// @notice Binds the vault to its controller (the escrow proxy, which already
    /// exists) and the claim collection, once. No bootstrap, no separate binding
    /// transaction, no window without a controller (design 2A.4).
    function initialize(address controller_, address receipt_, AcceptanceMode[3] calldata modes) external initializer {
        if (controller_.code.length == 0 || receipt_.code.length == 0) revert ZeroAddress();
        NewTradeV2VaultStorage.VaultStorage storage $ = NewTradeV2VaultStorage.s();
        $.controller = controller_;
        $.receipt = receipt_;
        $.acceptanceModes = modes;
        $.assetPolicyRevision = 1;
    }

    // ------------------------------------------------------------------ upgrades

    /// The upgrader is the escrow's upgrader (D8). Refused while the vault's own
    /// lock is set, while a custody operation holds the transient lock, and for a
    /// target that is not a vault implementation.
    function _authorizeUpgrade(address newImplementation) internal view override {
        NewTradeV2VaultStorage.VaultStorage storage $ = NewTradeV2VaultStorage.s();
        if ($.upgradesLocked || _tload(LOCK_SLOT) != 0) revert UpgradeRefused();
        if (!IAccessControl($.controller).hasRole(UPGRADER_ROLE, msg.sender)) revert UpgradeRefused();
        (bool ok, bytes memory data) =
            newImplementation.staticcall(abi.encodeWithSelector(this.VAULT_FAMILY.selector));
        if (!ok || data.length != 32 || abi.decode(data, (bytes32)) != VAULT_FAMILY) revert UpgradeRefused();
    }

    function lockUpgrades() external {
        NewTradeV2VaultStorage.VaultStorage storage $ = NewTradeV2VaultStorage.s();
        if ($.upgradesLocked || !IAccessControl($.controller).hasRole(UPGRADER_ROLE, msg.sender)) {
            revert UpgradeRefused();
        }
        $.upgradesLocked = true;
        emit UpgradesLocked();
    }

    /// The implementation behind this proxy, read from the proxy's own storage
    /// (a migrator cannot read another contract's slot; design 6.3).
    function implementation() external view returns (address) {
        return ERC1967Utils.getImplementation();
    }

    // ------------------------------------------------------------------ wiring views

    function controller() external view returns (address) {
        return NewTradeV2VaultStorage.s().controller;
    }

    function receipt() external view returns (address) {
        return NewTradeV2VaultStorage.s().receipt;
    }

    // ------------------------------------------------------------------ admission policy

    function setAssetKind(address token, AssetKind kind, bool allowed)
        external
        onlyController
        returns (uint256 revision)
    {
        NewTradeV2VaultStorage.VaultStorage storage $ = NewTradeV2VaultStorage.s();
        VaultAdmission.requireEligible(token, kind);
        uint8 oldMembership = $.allowlistKindPlusOne[token];
        uint8 next = uint8(kind) + 1;
        if (allowed) {
            uint8 pinned = $.custodyKindPlusOne[token];
            if (pinned != 0 && pinned != next && $.assetLiabilityUnits[token] != 0) revert AssetReserved();
            if (oldMembership == next && pinned == next) return $.assetPolicyRevision;
            $.allowlistKindPlusOne[token] = next;
            if ($.assetLiabilityUnits[token] == 0) $.custodyKindPlusOne[token] = next;
        } else {
            if (oldMembership != next) return $.assetPolicyRevision;
            $.allowlistKindPlusOne[token] = 0;
        }
        revision = ++$.assetPolicyRevision;
    }

    function setAssetAcceptanceMode(AssetKind kind, AcceptanceMode mode)
        external
        onlyController
        returns (AcceptanceMode oldMode, uint256 revision)
    {
        NewTradeV2VaultStorage.VaultStorage storage $ = NewTradeV2VaultStorage.s();
        oldMode = $.acceptanceModes[uint8(kind)];
        if (oldMode == mode) return (oldMode, $.assetPolicyRevision);
        $.acceptanceModes[uint8(kind)] = mode;
        revision = ++$.assetPolicyRevision;
    }

    function assetAcceptanceMode(AssetKind kind) external view returns (AcceptanceMode) {
        return NewTradeV2VaultStorage.s().acceptanceModes[uint8(kind)];
    }

    function assetPolicyRevision() external view returns (uint256) {
        return NewTradeV2VaultStorage.s().assetPolicyRevision;
    }

    function isAssetAllowlisted(address token, AssetKind kind) public view returns (bool) {
        return NewTradeV2VaultStorage.s().allowlistKindPlusOne[token] == uint8(kind) + 1;
    }

    function isAllowed(address token, AssetKind kind) external view returns (bool) {
        return VaultAdmission.isAllowed(token, kind);
    }

    function requireBundleAllowed(uint256 bundleId, address nft) external view {
        if (!VaultAdmission.isAllowed(nft, AssetKind.ERC721)) revert UnsupportedAsset();
        ManifestEntry[] storage es = NewTradeV2VaultStorage.s().manifests[bundleId];
        for (uint256 i; i < es.length; ++i) {
            if (!VaultAdmission.isAllowed(es[i].token, es[i].kind)) revert UnsupportedAsset();
        }
    }

    // ------------------------------------------------------------------ custody in

    function deposit(uint256 bundleId, address seller, address nft, uint256 nftId, ManifestEntry[] calldata entries)
        external
        onlyController
        locked
        returns (bytes32 hash)
    {
        NewTradeV2VaultStorage.VaultStorage storage $ = NewTradeV2VaultStorage.s();
        if (entries.length > MAX_MANIFEST_ENTRIES || $.erc721Reserved[nft][nftId] || $.custody[bundleId].exists) {
            revert InvalidManifest();
        }
        VaultAdmission.validateAndPin(entries, nft, nftId);
        if (IERC721(nft).ownerOf(nftId) != seller) revert InvalidManifest();
        hash = keccak256(abi.encode(uint256(2), block.chainid, $.controller, nft, nftId, entries));
        _bind(bundleId, nft, nftId);
        for (uint256 i; i < entries.length; ++i) {
            $.manifests[bundleId].push(entries[i]);
            VaultCustodyIn.pullEntry(entries[i], seller, false);
        }
        VaultCustodyIn.pull721(nft, nftId, seller, address(this));
        VaultCustodyIn.postcheck(entries, nft, nftId);
    }

    function depositFromAccount(
        uint256 bundleId,
        address seller,
        address source,
        address nft,
        uint256 nftId,
        ManifestEntry[] calldata entries,
        bytes32 nonce
    ) external onlyController locked returns (bytes32 hash) {
        NewTradeV2VaultStorage.VaultStorage storage $ = NewTradeV2VaultStorage.s();
        if (entries.length > MAX_MANIFEST_ENTRIES || $.erc721Reserved[nft][nftId] || $.custody[bundleId].exists) {
            revert InvalidManifest();
        }
        VaultAdmission.validateAndPin(entries, nft, nftId);
        _authenticateMigration(seller, source, nft, nftId, nonce);
        hash = keccak256(abi.encode(uint256(2), block.chainid, $.controller, nft, nftId, entries));
        _bind(bundleId, nft, nftId);
        for (uint256 i; i < entries.length; ++i) {
            $.manifests[bundleId].push(entries[i]);
        }
        VaultCustodyIn.pull721(nft, nftId, seller, address(this));
        if (IERC721(nft).ownerOf(nftId) != address(this)) revert TransferMismatch();
        for (uint256 i; i < entries.length; ++i) {
            VaultCustodyIn.pullEntry(entries[i], source, true);
        }
        VaultCustodyIn.postcheck(entries, nft, nftId);
    }

    function _bind(uint256 bundleId, address nft, uint256 nftId) private {
        NewTradeV2VaultStorage.VaultStorage storage $ = NewTradeV2VaultStorage.s();
        $.erc721Reserved[nft][nftId] = true;
        $.assetLiabilityUnits[nft]++;
        $.custody[bundleId] = NewTradeV2VaultStorage.Custody(nft, nftId, true);
    }

    function _authenticateMigration(address seller, address source, address nft, uint256 nftId, bytes32 nonce)
        private
    {
        NewTradeV2VaultStorage.VaultStorage storage $ = NewTradeV2VaultStorage.s();
        if (
            !$.migrationEnabled || $.migrationNonces[seller][nonce] || source.code.length == 0 || source == seller
                || source == address(this) || source == $.controller || source == $.receipt
                || IERC721(nft).ownerOf(nftId) != seller
        ) revert MigrationUnavailable();
        try IERC6551Account(source).token() returns (uint256 c, address t, uint256 i) {
            if (c != block.chainid || t != nft || i != nftId) revert MigrationUnavailable();
        } catch {
            revert MigrationUnavailable();
        }
        $.migrationNonces[seller][nonce] = true;
    }

    function setMigrationEnabled(bool enabled) external onlyController {
        NewTradeV2VaultStorage.s().migrationEnabled = enabled;
    }

    function migrationNonceUsed(address seller, bytes32 nonce) external view returns (bool) {
        return NewTradeV2VaultStorage.s().migrationNonces[seller][nonce];
    }

    // ------------------------------------------------------------------ ERC-6551

    function computeAccount(address registry, address implementation_, bytes32 salt, address nft, uint256 nftId)
        external
        view
        returns (address)
    {
        return IERC6551Registry(registry).account(implementation_, salt, block.chainid, nft, nftId);
    }

    function createFreshAccount(
        address registry,
        address accountProxy,
        address implementation_,
        bytes32 salt,
        address nft,
        uint256 nftId,
        address buyer
    ) external onlyController returns (address account) {
        NewTradeV2VaultStorage.VaultStorage storage $ = NewTradeV2VaultStorage.s();
        account = IERC6551Registry(registry).account(accountProxy, salt, block.chainid, nft, nftId);
        if (
            account.code.length != 0 || account == address(this) || account == $.controller || account == $.receipt
                || account == buyer
        ) revert MigrationUnavailable();
        address made = IERC6551Registry(registry).createAccount(accountProxy, salt, block.chainid, nft, nftId);
        if (made != account || made.code.length == 0) revert MigrationUnavailable();
        ITokenboundAccountProxy(account).initialize(implementation_);
        (uint256 c, address t, uint256 i) = IERC6551Account(account).token();
        if (c != block.chainid || t != nft || i != nftId) revert MigrationUnavailable();
    }

    function selfBound(address account, address nft, uint256 nftId) external view returns (bool yes) {
        if (account.code.length == 0) return false;
        try IERC6551Account(account).token() returns (uint256 c, address t, uint256 i) {
            return c == block.chainid && t == nft && i == nftId;
        } catch {
            return false;
        }
    }

    // ------------------------------------------------------------------ custody out, per entry

    /// @notice Records the destinations once and attempts everything (design 2.1).
    /// A protocol contract (this vault, the escrow, the claim collection) is
    /// refused as either destination: none of them can hand an asset on, so the
    /// first exit reverts and the caller chooses again.
    function beginRelease(uint256 bundleId, ReleaseMode mode, address extrasTo, address nftTo)
        external
        onlyController
        locked
        returns (bool closed)
    {
        NewTradeV2VaultStorage.VaultStorage storage $ = NewTradeV2VaultStorage.s();
        NewTradeV2VaultStorage.ReleaseRecord storage r = $.releases[bundleId];
        if (r.initialized || !$.custody[bundleId].exists) revert NoRelease();
        if (extrasTo == address(0) || nftTo == address(0)) revert ZeroAddress();
        if (_isProtocol(extrasTo) || _isProtocol(nftTo)) revert InvalidDestination();
        r.initialized = true;
        r.mode = mode;
        r.extrasTo = extrasTo;
        r.nftTo = nftTo;
        emit ReleaseBegun(bundleId, mode, extrasTo, nftTo);
        closed = _batch(bundleId, type(uint256).max);
    }

    /// @notice Retries the entries named in `mask` (bit 32 = the NFT). `actor` is
    /// the escrow's caller. Empty `data` is the plain retry anyone may make.
    /// Non-empty `data` is a command: today only the redeemer's redirect (D2-B).
    function releaseRemaining(uint256 bundleId, uint256 mask, address actor, bytes calldata data)
        external
        onlyController
        locked
        returns (bool closed)
    {
        NewTradeV2VaultStorage.ReleaseRecord storage r = NewTradeV2VaultStorage.s().releases[bundleId];
        if (!r.initialized) revert NoRelease();
        if (data.length != 0) _command(bundleId, r, actor, data);
        uint256 n = NewTradeV2VaultStorage.s().manifests[bundleId].length;
        // Every named bit must exist: no silent ignoring (design 2.1).
        uint256 valid = ((1 << n) - 1) | NFT_BIT;
        if (mask & ~valid != 0) revert InvalidMask();
        closed = _batch(bundleId, mask);
    }

    /// D2-B: `abi.encode(uint8(1), address to)`. Changes where the manifest
    /// entries still held go; never clears a released bit; the NFT's own
    /// destination never changes. Only the recorded `nftTo` may send it: the
    /// redeemer on a redemption, the seller on a reclaim.
    /// Redemption: only while the NFT is still held. After a redirect the entries
    /// no longer wait for the NFT and the account check does not apply (the
    /// account is no longer the destination).
    /// Reclaim: at any time, also after the NFT has gone home, so a destination
    /// that refuses an entry never keeps it in the vault for good.
    function _command(uint256 bundleId, NewTradeV2VaultStorage.ReleaseRecord storage r, address actor, bytes calldata data) private {
        (uint8 op, address to) = abi.decode(data, (uint8, address));
        if (
            op != 1 || actor != r.nftTo || (r.mode == ReleaseMode.Redeem && r.releasedMask & NFT_BIT != 0)
                || to == address(0) || _isProtocol(to)
        ) revert NotRedeemer();
        r.extrasTo = to;
        r.redirected = true;
        emit EntriesRedirected(bundleId, to);
    }

    function _isProtocol(address a) private view returns (bool) {
        NewTradeV2VaultStorage.VaultStorage storage $ = NewTradeV2VaultStorage.s();
        return a == address(this) || a == $.controller || a == $.receipt;
    }

    /// One batch over the clear bits of `mask`: the NFT first, then the entries.
    /// On a redemption the entries wait while the NFT is held (design 4), unless
    /// the redeemer redirected them. Returns true when the bundle is closed.
    function _batch(uint256 bundleId, uint256 mask) private returns (bool closed) {
        NewTradeV2VaultStorage.VaultStorage storage $ = NewTradeV2VaultStorage.s();
        NewTradeV2VaultStorage.ReleaseRecord storage r = $.releases[bundleId];
        uint256 n = $.manifests[bundleId].length;
        uint256 full = ((1 << n) - 1) | NFT_BIT;
        uint256 todo = mask & full & ~uint256(r.releasedMask);
        bool single = todo != 0 && (todo & (todo - 1)) == 0;

        if (todo & NFT_BIT != 0) {
            if (_try(bundleId, 32, BUDGET_NFT, single)) emit ControllingNFTReleased(bundleId, r.nftTo);
            else emit EntryPending(bundleId, 32);
        }
        bool entriesMayGo = r.mode == ReleaseMode.Reclaim || r.redirected || (r.releasedMask & NFT_BIT != 0);
        if (entriesMayGo) {
            for (uint256 i; i < n; ++i) {
                if (todo & (1 << i) == 0) continue;
                uint256 budget = $.manifests[bundleId][i].kind == AssetKind.ERC20 ? BUDGET_ERC20 : BUDGET_NFT;
                if (_try(bundleId, i, budget, single)) emit EntryReleased(bundleId, i, r.extrasTo);
                else emit EntryPending(bundleId, i);
            }
        }
        closed = r.releasedMask == full;
        if (closed && todo != 0) emit BundleEmptied(bundleId);
    }

    /// Gas rule (design 2.3). Reverts the WHOLE call, with GasTooLow, when the gas
    /// left cannot both deliver the budget (63/64) and leave the reserve: an
    /// underfunded call must fail rather than succeed having attempted nothing,
    /// so gas estimation finds the gas a release really needs (P-1).
    /// Batch: a false return means a fully funded attempt ran and failed; its
    /// siblings still commit. Single (exactly one bit to do): the attempt gets
    /// all the gas there is, so a failure cannot be told from too little gas and
    /// reverts the WHOLE call with ReleaseFailed. A call that names one entry
    /// therefore either releases it or changes nothing. An entry that is only
    /// waiting for the NFT is not attempted and reverts nothing.
    function _try(uint256 bundleId, uint256 index, uint256 budget, bool single) private returns (bool ok) {
        uint256 a = gasleft();
        if (a <= GAS_OVERHEAD) revert GasTooLow();
        a -= GAS_OVERHEAD;
        uint256 give;
        if (single) {
            uint256 cap = a - a / 64;
            if (a <= GAS_RESERVE) revert GasTooLow();
            give = a - GAS_RESERVE;
            if (give > cap) give = cap;
        } else {
            if (a - a / 64 < budget || a - budget < GAS_RESERVE) revert GasTooLow();
            give = budget;
        }
        bytes memory callData = abi.encodeCall(this.attempt, (bundleId, index));
        assembly ("memory-safe") {
            // Zero-size output: the attempt's return or revert data is never
            // copied into this frame, whatever its size.
            ok := call(give, address(), 0, add(callData, 32), mload(callData), 0, 0)
        }
        if (single && !ok) revert ReleaseFailed();
    }

    /// @notice One attempt, callable only by the vault itself during a batch.
    /// Everything it does is undone if it reverts (design 2.2).
    function attempt(uint256 bundleId, uint256 index) external {
        if (msg.sender != address(this) || _tload(LOCK_SLOT) == 0) revert ControllerOnly();
        NewTradeV2VaultStorage.VaultStorage storage $ = NewTradeV2VaultStorage.s();
        NewTradeV2VaultStorage.ReleaseRecord storage r = $.releases[bundleId];
        if (!r.initialized) revert NoRelease();
        uint256 bit = index == 32 ? NFT_BIT : (1 << index);
        if (r.releasedMask & bit != 0) revert InvalidMask();
        r.releasedMask |= uint64(bit);
        if (index == 32) {
            NewTradeV2VaultStorage.Custody storage c = $.custody[bundleId];
            $.erc721Reserved[c.nft][c.nftId] = false;
            $.assetLiabilityUnits[c.nft]--;
            IERC721(c.nft).safeTransferFrom(address(this), r.nftTo, c.nftId);
            if (IERC721(c.nft).ownerOf(c.nftId) != r.nftTo) revert TransferMismatch();
            // Redemption: the fresh account must obey the recorded redeemer, checked
            // here, atomically with the NFT leaving (design 4, devlead point 2).
            if (r.mode == ReleaseMode.Redeem && !r.redirected) {
                if (
                    IERC6551OwnerAccount(r.extrasTo).owner() != r.nftTo
                        || IERC6551Account(r.extrasTo).isValidSigner(r.nftTo, "") != VALID_SIGNER_MAGIC
                ) revert TransferMismatch();
            }
        } else {
            if (index >= $.manifests[bundleId].length) revert InvalidMask();
            _release($.manifests[bundleId][index], r.extrasTo);
        }
    }

    /// Release checks (design 5.1, D4): the vault must still back what it owes
    /// after the transfer; the recipient must have received at least the amount.
    function _release(ManifestEntry storage e, address to) private {
        NewTradeV2VaultStorage.VaultStorage storage $ = NewTradeV2VaultStorage.s();
        if (e.kind == AssetKind.ERC20) {
            uint256 d = IERC20(e.token).balanceOf(to);
            $.erc20Liability[e.token] -= e.amount;
            $.assetLiabilityUnits[e.token] -= e.amount;
            IERC20(e.token).safeTransfer(to, e.amount);
            if (
                IERC20(e.token).balanceOf(address(this)) < $.erc20Liability[e.token]
                    || IERC20(e.token).balanceOf(to) < d + e.amount
            ) revert TransferMismatch();
        } else if (e.kind == AssetKind.ERC721) {
            $.erc721Reserved[e.token][e.tokenId] = false;
            $.assetLiabilityUnits[e.token]--;
            IERC721(e.token).safeTransferFrom(address(this), to, e.tokenId);
            if (IERC721(e.token).ownerOf(e.tokenId) != to) revert TransferMismatch();
        } else {
            uint256 d = IERC1155(e.token).balanceOf(to, e.tokenId);
            $.erc1155Liability[e.token][e.tokenId] -= e.amount;
            $.assetLiabilityUnits[e.token] -= e.amount;
            IERC1155(e.token).safeTransferFrom(address(this), to, e.tokenId, e.amount, "");
            if (
                IERC1155(e.token).balanceOf(address(this), e.tokenId) < $.erc1155Liability[e.token][e.tokenId]
                    || IERC1155(e.token).balanceOf(to, e.tokenId) < d + e.amount
            ) revert TransferMismatch();
        }
    }

    // ------------------------------------------------------------------ release views

    /// What the vault knows about a bundle: custody, release record, and the bits
    /// still held (entries by index, bit 32 the NFT; zero when closed or never held).
    function bundleStatus(uint256 bundleId)
        external
        view
        returns (NewTradeV2VaultStorage.Custody memory custody, NewTradeV2VaultStorage.ReleaseRecord memory record, uint256 held)
    {
        NewTradeV2VaultStorage.VaultStorage storage $ = NewTradeV2VaultStorage.s();
        custody = $.custody[bundleId];
        record = $.releases[bundleId];
        if (custody.exists) {
            uint256 full = ((1 << $.manifests[bundleId].length) - 1) | NFT_BIT;
            held = full & ~uint256(record.releasedMask);
        }
    }

    function getManifest(uint256 id) external view returns (ManifestEntry[] memory) {
        return NewTradeV2VaultStorage.s().manifests[id];
    }

    /// Accounting for one token (and id, for ERC-1155 / ERC-721).
    function liability(address token, uint256 id)
        external
        view
        returns (uint256 erc20, uint256 erc1155, bool reserved721, uint256 units)
    {
        NewTradeV2VaultStorage.VaultStorage storage $ = NewTradeV2VaultStorage.s();
        return ($.erc20Liability[token], $.erc1155Liability[token][id], $.erc721Reserved[token][id], $.assetLiabilityUnits[token]);
    }

    // ------------------------------------------------------------------ receiver hooks

    function onERC721Received(address operator, address from, uint256 id, bytes calldata) external returns (bytes4) {
        NewTradeV2VaultStorage.VaultStorage storage $ = NewTradeV2VaultStorage.s();
        NewTradeV2VaultStorage.Expected memory e = $.expected;
        if (
            operator != e.operator || e.kind != uint8(AssetKind.ERC721) + 1 || e.token != msg.sender || e.from != from
                || e.id != id || e.amount != 1
        ) revert InvalidCallback();
        delete $.expected;
        return IERC721Receiver.onERC721Received.selector;
    }

    function onERC1155Received(address operator, address from, uint256 id, uint256 amount, bytes calldata)
        external
        returns (bytes4)
    {
        NewTradeV2VaultStorage.VaultStorage storage $ = NewTradeV2VaultStorage.s();
        NewTradeV2VaultStorage.Expected memory e = $.expected;
        if (
            operator != e.operator || e.kind != uint8(AssetKind.ERC1155) + 1 || e.token != msg.sender || e.from != from
                || e.id != id || e.amount != amount
        ) revert InvalidCallback();
        delete $.expected;
        return IERC1155Receiver.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert InvalidCallback();
    }

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == type(IERC721Receiver).interfaceId || id == type(IERC1155Receiver).interfaceId
            || id == type(IERC165).interfaceId;
    }

    // ------------------------------------------------------------------ transient storage

    function _tload(bytes32 slot) private view returns (uint256 v) {
        assembly ("memory-safe") {
            v := tload(slot)
        }
    }

    function _tstore(bytes32 slot, uint256 v) private {
        assembly ("memory-safe") {
            tstore(slot, v)
        }
    }
}
