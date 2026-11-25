// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";

import {
    AcceptanceMode,
    AssetKind,
    BundleState,
    ReleaseMode,
    RedemptionMode,
    ManifestEntry,
    Payout,
    Bundle,
    RoyaltySnapshot,
    V2Initialization
} from "./NewTradeV2Types.sol";
import {INewTradeEscrowV2} from "./INewTradeEscrowV2.sol";
import {NewTradeEscrowV2Storage} from "./NewTradeEscrowV2Storage.sol";
import {NewTradeBundle} from "./NewTradeBundle.sol";
import {INewTradeVaultV2} from "./interfaces/INewTradeVaultV2.sol";
import {
    ISeaport,
    ItemType,
    OrderType,
    OfferItem,
    ConsiderationItem,
    OrderParameters,
    Order,
    OrderComponents
} from "./interfaces/ISeaport.sol";

/// @notice V2 beta bundle custody with seller-authorized, signatureless Seaport listings.
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
contract NewTradeEscrowV2 is
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable,
    NewTradeEscrowV2Storage,
    INewTradeEscrowV2
{
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    address public constant SEAPORT = 0x0000000000000068F116a894984e2DB1123eB395;
    uint64 public constant MAX_CUSTODY_DURATION = 90 days;
    uint96 public constant MAX_PROTOCOL_FEE_BPS = 1_000;
    /// Hard ceiling on the service fee taken FROM the creator royalty: 20 % of
    /// the royalty, never of the price. An admin cannot exceed it, and a bundle
    /// listed under a lower value keeps that lower value forever.
    uint16 public constant MAX_ROYALTY_SERVICE_FEE_BPS = 2_000;
    uint256 public constant MAX_CONSIDERATION_ITEMS = 32;
    uint256 private constant TOTAL_BPS = 10_000;
    /// Step 2: the conduit OpenSea's API demands, and the operator the receipt
    /// will actually see - Seaport transfers through `conduit.execute`.
    bytes32 public constant OPENSEA_CONDUIT_KEY = 0x0000007b02230091a7ed01230072f7006a004d60a8d4e71d599b8104250f0000;
    address public constant OPENSEA_CONDUIT = 0x1E0049783F008A0085193E00003D00cd54003c71;
    bytes32 private constant ENTRY_LOCK_SLOT = keccak256("newtrade.v2.beta.transient.entry");
    /// partial-release-oct20: gas the escrow keeps back from a vault release call
    /// for its own state write afterwards (measured in the build; design 2.3).
    uint256 private constant VAULT_CALL_RESERVE = 30_000;

    error InvalidState();
    error Unauthorized();
    error UnsupportedAsset();
    error InvalidDeadline();
    error InvalidConsideration();
    error InvalidOrder();
    error InvalidCallback();
    error InvalidRecipient();
    error Reentrancy();
    error FreshAccountUnavailable();
    error UpgradeLocked();
    error ZeroAddress();
    error MigrationUnavailable();

    constructor() {
        _disableInitializers();
    }

    function initialize(V2Initialization calldata c) external initializer {
        if (
            c.admin == address(0) || c.treasury == address(0) || c.receipt.code.length == 0 || c.vault.code.length == 0
                || c.transferValidator.code.length == 0 || c.seaportZone.code.length == 0
                || c.assetTokens.length != c.assetKinds.length || SEAPORT.code.length == 0
        ) revert ZeroAddress();
        if (c.protocolFeeBps > MAX_PROTOCOL_FEE_BPS) revert InvalidConsideration();
        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, c.admin);
        _grantRole(UPGRADER_ROLE, c.admin);
        _treasury = c.treasury;
        _protocolFeeBps = c.protocolFeeBps;
        _receipt = NewTradeBundle(c.receipt);
        _vault = INewTradeVaultV2(c.vault);
        uint256 revision = _vault.assetPolicyRevision();
        for (uint256 i; i < 3; ++i) {
            AssetKind kind = AssetKind(i);
            AcceptanceMode configured = c.assetAcceptanceModes[i];
            if (_vault.assetAcceptanceMode(kind) != configured) revert InvalidState();
            emit AssetAcceptanceModeUpdated(kind, AcceptanceMode.Disabled, configured, revision);
        }
        if (_receipt.getTransferValidator() != c.transferValidator) revert InvalidState();
        _seaportZone = c.seaportZone;
        // Option B (escrow-option-b-sep26): routing is retired; `c.royaltyRouter` is ignored.
        for (uint256 i; i < c.paymentTokens.length; ++i) {
            _paymentAllowed[c.paymentTokens[i]] = true;
        }
        for (uint256 i; i < c.assetTokens.length; ++i) {
            address token = c.assetTokens[i];
            AssetKind kind = c.assetKinds[i];
            if (!_vault.isAssetAllowlisted(token, kind)) revert InvalidState();
            emit AssetKindAllowed(token, kind, true);
            emit AssetAllowlistMembershipUpdated(token, kind, true, revision);
        }
        if (c.accountRegistry != address(0) && c.accountProxy != address(0) && c.accountImplementation != address(0)) {
            _trustAccountCode(c.accountRegistry, true, true);
            _trustAccountCode(c.accountProxy, false, true);
            _trustAccountCode(c.accountImplementation, false, true);
        }
        _setFreshAccountPolicy(
            c.accountRegistry,
            c.accountProxy,
            c.accountImplementation,
            c.accountRegistry != address(0) || c.accountProxy != address(0) || c.accountImplementation != address(0)
        );
    }

    /// @notice partial-release-oct20 (D1): points the escrow at the upgradeable
    /// per-entry vault. Runs once (reinitializer(3)), by the upgrader, inside the
    /// same `upgradeToAndCall` as the implementation upgrade; the implementation
    /// itself has initializers disabled, so it only works through the proxy.
    /// SIZE DECISION (size spike, 2026-10-20): the on-chain wiring checks
    /// (`controller() == this`, `receipt() == claim collection`) cost 242 B the
    /// escrow does not have under EIP-170 with D5 and D9 kept. They are made by
    /// the upgrade runbook's post-check and by the fork rehearsal instead, and a
    /// wrong vault is reversible by a later reinitializer version. Bundles still
    /// in the previous vault are not moved (Prem: rescued later through an
    /// escrow upgrade if ever needed).
    function initializeVault(address newVault) external reinitializer(3) onlyRole(UPGRADER_ROLE) {
        if (newVault.code.length == 0) revert ZeroAddress();
        _vault = INewTradeVaultV2(newVault);
    }

    modifier externalEntry() {
        _enter();
        _;
        _tstore(ENTRY_LOCK_SLOT, 0);
    }

    function _enter() private {
        if (_tload(ENTRY_LOCK_SLOT) != 0) revert Reentrancy();
        _tstore(ENTRY_LOCK_SLOT, 1);
    }

    function deposit(address nft, uint256 nftId, ManifestEntry[] calldata entries, uint64 deadline)
        external
        externalEntry
        returns (uint256 bundleId)
    {
        bundleId = _deposit(msg.sender, nft, nftId, entries, deadline);
    }

    function depositFromAccount(
        address sourceAccount,
        address nft,
        uint256 nftId,
        ManifestEntry[] calldata entries,
        uint64 deadline,
        bytes32 nonce
    ) external externalEntry returns (uint256 bundleId) {
        // Step 1: validate the custody window and allocate the bundle record.
        _validateDeadline(deadline);
        bundleId = _counter + 1;
        _initializeDeposit(_bundles[bundleId], msg.sender, nft, nftId, deadline);

        // Step 2: atomically pull the controller NFT and selected account assets into the vault.
        bytes32 hash = _vault.depositFromAccount(bundleId, msg.sender, sourceAccount, nft, nftId, entries, nonce);

        // Step 3: commit the manifest only after vault custody succeeds.
        _counter = bundleId;
        _bundles[bundleId].manifestHash = hash;

        // Step 4: mint the escrow-held wrapper and publish the deposited bundle.
        _completeDeposit(bundleId, entries);
        emit BundleMigrated(bundleId, sourceAccount, msg.sender, nonce);
    }

    function _deposit(address seller, address nft, uint256 nftId, ManifestEntry[] calldata entries, uint64 deadline)
        private
        returns (uint256 bundleId)
    {
        // Step 1: validate the requested custody window.
        _validateDeadline(deadline);

        // Step 2: allocate and pin the bundle record before vault custody begins.
        bundleId = ++_counter;
        Bundle storage b = _bundles[bundleId];
        _initializeDeposit(b, seller, nft, nftId, deadline);

        // Step 3: atomically pull the controller NFT and manifest assets into the vault.
        b.manifestHash = _vault.deposit(bundleId, seller, nft, nftId, entries);

        // Step 4: mint the escrow-held wrapper and publish the deposited bundle.
        _completeDeposit(bundleId, entries);
    }

    function _validateDeadline(uint64 deadline) private view {
        if (deadline <= block.timestamp || deadline > block.timestamp + MAX_CUSTODY_DURATION) revert InvalidDeadline();
    }

    function _initializeDeposit(Bundle storage b, address seller, address nft, uint256 nftId, uint64 deadline)
        private
    {
        if (!_freshAccountsEnabled || !_trustedAccountPolicy()) revert FreshAccountUnavailable();
        b.seller = seller;
        b.controllingNFT = nft;
        b.controllingTokenId = nftId;
        b.custodyDeadline = deadline;
        b.state = BundleState.Deposited;
        b.accountRegistry = _accountRegistry;
        b.accountProxy = _accountProxy;
        b.accountImplementation = _accountImplementation;
    }

    function _completeDeposit(uint256 bundleId, ManifestEntry[] calldata entries) private {
        Bundle storage b = _bundles[bundleId];
        _receipt.controllerMint(bundleId);
        emit BundleDeposited(
            bundleId,
            bundleId,
            b.seller,
            b.controllingNFT,
            b.controllingTokenId,
            b.manifestHash,
            b.custodyDeadline,
            b.accountRegistry,
            b.accountProxy,
            b.accountImplementation
        );
        for (uint256 i; i < entries.length; ++i) {
            emit ManifestAsset(bundleId, i, entries[i].kind, entries[i].token, entries[i].tokenId, entries[i].amount);
        }
    }

    /// @notice Lists a deposited bundle on the seller's exact consideration.
    /// PROTOCOL FEE (escrow-fee-from-proceeds-sep25): frozen per bundle at list()
    /// from the LIVE bps (ProtocolFeeSnapshot) and deducted from the escrow item
    /// at first exit. The seller's exact consideration does NOT bind it: a bps
    /// change between a quote and list() binds that listing; a change after list()
    /// binds only later list() calls. Capped at MAX_PROTOCOL_FEE_BPS (1,000);
    /// the admin that sets it is the same trust as the upgrader.
    function list(
        uint256 bundleId,
        address paymentToken,
        uint256 price,
        uint64 deadline,
        uint16 maxRoyaltyBps,
        Payout[] calldata exactConsideration
    ) external externalEntry returns (bytes32 orderHash) {
        Bundle storage b = _bundles[bundleId];

        // Step 1: accept only the seller's onchain commitment to the exact sale terms.
        if (msg.sender != b.seller) revert Unauthorized();
        if (b.state != BundleState.Deposited || block.timestamp >= b.custodyDeadline) revert InvalidState();
        if (deadline != b.custodyDeadline || price == 0 || !_paymentAllowed[paymentToken]) revert InvalidOrder();
        _vault.requireBundleAllowed(bundleId, b.controllingNFT);
        Payout[] memory payouts = exactConsideration;
        (address royaltyRecipient, uint256 royalty) = _validateExactConsideration(b, price, maxRoyaltyBps, payouts);

        // Step 2: persist the canonical FULL_OPEN order and its historical identity.
        b.paymentToken = paymentToken;
        b.price = price;
        b.considerationHash = keccak256(abi.encode(paymentToken, price, payouts));
        b.orderCounter = ISeaport(SEAPORT).getCounter(address(this));
        b.orderChainId = block.chainid;
        b.state = BundleState.Listed;
        // Step 2b: a REAL recent start time, fixed here and read back from
        // storage forever. The API rejects 1970; block.timestamp is recent by
        // construction and never re-derived in a view.
        _orderStartTimes[bundleId] = uint64(block.timestamp);
        _bundleConduitKey[bundleId] = OPENSEA_CONDUIT_KEY;
        // consideration[0] pays the escrow; that amount is what the seller may
        // later withdraw, recorded now so the callback never has to compute it.
        _escrowRecipientAmount[bundleId] = payouts[0].amount;
        // Freeze the protocol fee, unconditionally (zero allowed): a later
        // setProtocolFeeBps / setTreasury never changes a listed bundle.
        uint256 fee = price * _protocolFeeBps / TOTAL_BPS;
        _protocolFeeAmount[bundleId] = fee;
        emit ProtocolFeeSnapshot(bundleId, paymentToken, fee);
        for (uint256 i; i < payouts.length; ++i) {
            _payouts[bundleId].push(payouts[i]);
        }
        // Step 2c: freeze the creator royalty (option B, escrow-option-b-sep26).
        // It is NOT a consideration item: the first exit credits it to the
        // ERC-2981 recipient out of item[0], through the owed ledger. Written
        // unconditionally, here, from the answer the seller just accepted, into
        // the existing snapshot slot (no new storage): creator = recipient,
        // gross = net = the royalty, router/treasury/service fee zero. Nothing
        // else writes this slot.
        _royaltySnapshots[bundleId] = RoyaltySnapshot({
            router: address(0),
            creator: royaltyRecipient,
            treasury: address(0),
            serviceFeeBps: 0,
            grossRoyalty: royalty,
            serviceFeeAmount: 0,
            creatorNet: royalty
        });
        if (royalty != 0) emit CreatorRoyaltySnapshot(bundleId, royaltyRecipient, paymentToken, royalty);
        OrderParameters memory p = _storedOrder(bundleId, b, _orderStartTimes[bundleId]);
        orderHash = ISeaport(SEAPORT).getOrderHash(_components(p, b.orderCounter));
        b.orderHash = orderHash;
        // Step 12: record the ONE digest this bundle's listing will ever have,
        // so an offchain signature check can be resolved back to a bundle.
        _listingDigestBundle[_signingDigest(orderHash)] = bundleId;

        // Step 3: approve the wrapper and validate the escrow's order on Seaport.
        // Step 7: approve the conduit. Seaport moves the receipt through
        // conduit.execute, so the conduit - not Seaport - is the operator the
        // receipt's validator and callback will see. The escrow owns the
        // receipt, so a plain ERC721 approve is enough and does not consult the
        // validator.
        _receipt.approve(OPENSEA_CONDUIT, bundleId);
        Order[] memory orders = new Order[](1);
        orders[0] = Order(p, bytes(""));
        if (!ISeaport(SEAPORT).validate(orders)) revert InvalidOrder();

        // Step 4: publish the seller-authorized listing and its exact payouts.
        emit BundleListed(
            bundleId,
            orderHash,
            b.considerationHash,
            paymentToken,
            price,
            deadline,
            p.salt,
            b.orderCounter,
            block.chainid,
            SEAPORT
        );
        for (uint256 i; i < payouts.length; ++i) {
            emit SaleConsideration(bundleId, i, paymentToken, payouts[i].recipient, payouts[i].amount);
        }
    }

    /// @return royaltyRecipient The controlling NFT's ERC-2981 recipient.
    /// @return royalty The royalty `list()` freezes and the first exit credits.
    function _validateExactConsideration(
        Bundle storage b,
        uint256 price,
        uint16 maxRoyaltyBps,
        Payout[] memory payouts
    ) private view returns (address royaltyRecipient, uint256 royalty) {
        if (payouts.length == 0 || payouts.length > MAX_CONSIDERATION_ITEMS || maxRoyaltyBps > TOTAL_BPS) {
            revert InvalidConsideration();
        }
        uint256 total;
        for (uint256 i; i < payouts.length; ++i) {
            if (payouts[i].recipient == address(0) || payouts[i].amount == 0) revert InvalidConsideration();
            for (uint256 j; j < i; ++j) {
                if (payouts[j].recipient == payouts[i].recipient) revert InvalidConsideration();
            }
            total += payouts[i].amount;
        }
        if (total != price) revert InvalidConsideration();
        // Step 6: OpenSea requires consideration[0].recipient == offerer. The
        // escrow IS the offerer, so it must be paid first and settle onward.
        if (payouts[0].recipient != address(this)) revert InvalidConsideration();
        (royaltyRecipient, royalty) = _royalty(b.controllingNFT, b.controllingTokenId, price);
        if (royalty > price * maxRoyaltyBps / TOTAL_BPS) revert InvalidConsideration();
        uint256 fee = price * _protocolFeeBps / TOTAL_BPS;
        if (royalty + fee > price) revert InvalidConsideration();
        // OPTION B (escrow-option-b-sep26): neither the protocol fee nor the
        // creator royalty is a consideration item. Both are settled out of the
        // escrow item at first exit (the royalty credited to its ERC-2981
        // recipient through the owed ledger), so item[0] must cover both. The
        // order carries only what the marketplace schedule names.
        if (payouts[0].amount < royalty + fee) revert InvalidConsideration();
        // No double pay: the recipient is credited at first exit, so no item may
        // also pay it. (This also refuses a royalty addressed to the escrow
        // itself: item[0] names it.) Items to other addresses stay allowed.
        if (royalty != 0 && _amountTo(payouts, royaltyRecipient) != 0) revert InvalidConsideration();
        // partial-release-oct20 (D5b): a credit to the vault or the claim collection
        // could never be paid out (review F-05); the escrow itself is already refused
        // by the item0 rule above.
        if (royalty != 0 && (royaltyRecipient == address(_vault) || royaltyRecipient == address(_receipt))) {
            revert InvalidConsideration();
        }
    }

    function _amountTo(Payout[] memory payouts, address recipient) private pure returns (uint256) {
        for (uint256 i; i < payouts.length; ++i) {
            if (payouts[i].recipient == recipient) return payouts[i].amount;
        }
        return 0;
    }

    function _royalty(address token, uint256 id, uint256 price) private view returns (address r, uint256 a) {
        bool supported;
        try IERC165(token).supportsInterface(type(IERC2981).interfaceId) returns (bool ok) {
            supported = ok;
        } catch {}
        if (!supported) return (address(0), 0);
        (bool success, bytes memory data) = token.staticcall(abi.encodeCall(IERC2981.royaltyInfo, (id, price)));
        if (!success || data.length != 64) revert InvalidConsideration();
        (r, a) = abi.decode(data, (address, uint256));
        if (a != 0 && r == address(0)) revert InvalidConsideration();
    }

    /**
     * @dev `startTime` is a parameter rather than a read of `_orderStartTimes`
     * so the repair preview can reconstruct the REPAIRED order without writing
     * storage first. Live call sites pass the stored value, so a legacy listing
     * still reconstructs with 0 and still hashes to its recorded hash.
     */
    function _storedOrder(uint256 bundleId, Bundle storage b, uint64 startTime)
        private
        view
        returns (OrderParameters memory p)
    {
        OfferItem[] memory offer = new OfferItem[](1);
        offer[0] = OfferItem(ItemType.ERC721, address(_receipt), bundleId, 1, 1);
        Payout[] storage stored = _payouts[bundleId];
        ConsiderationItem[] memory consideration = new ConsiderationItem[](stored.length);
        ItemType typ = b.paymentToken == address(0) ? ItemType.NATIVE : ItemType.ERC20;
        for (uint256 i; i < stored.length; ++i) {
            consideration[i] =
                ConsiderationItem(typ, b.paymentToken, 0, stored[i].amount, stored[i].amount, stored[i].recipient);
        }
        p = OrderParameters(
            address(this),
            _seaportZone,
            offer,
            consideration,
            OrderType.FULL_RESTRICTED,
            startTime,
            b.custodyDeadline,
            bytes32(0),
            _listingSalt(bundleId, b.manifestHash, b.orderChainId),
            // Step 3: per-bundle conduit. Bundle 1 stored none, so it reads
            // bytes32(0) and still reconstructs its recorded hash.
            _bundleConduitKey[bundleId],
            consideration.length
        );
    }

    // Step 11: amendListingFee is REMOVED. It is consumed - _feeAmended[1] is
    // true on chain and bundle 1 is the only bundle - so it was already
    // unreachable. Its storage slot 14 is deliberately RETAINED so the consumed
    // latch stays readable. ABI/dependency impact recorded in
    // output/implement-normal-opensea-flow-sep16/abi-impact.md before removal.

    function _previewOrder(
        uint256 bundleId,
        Bundle storage b,
        address paymentToken,
        Payout[] memory payouts,
        uint64 startTime
    ) private view returns (OrderParameters memory p) {
        OfferItem[] memory offer = new OfferItem[](1);
        offer[0] = OfferItem(ItemType.ERC721, address(_receipt), bundleId, 1, 1);
        ConsiderationItem[] memory consideration = new ConsiderationItem[](payouts.length);
        ItemType typ = paymentToken == address(0) ? ItemType.NATIVE : ItemType.ERC20;
        for (uint256 i; i < payouts.length; ++i) {
            consideration[i] =
                ConsiderationItem(typ, paymentToken, 0, payouts[i].amount, payouts[i].amount, payouts[i].recipient);
        }
        p = OrderParameters(
            address(this),
            _seaportZone,
            offer,
            consideration,
            OrderType.FULL_RESTRICTED,
            // Step 4: explicit, never block.timestamp - a view must be
            // deterministic so an offchain expected hash can bind to it.
            startTime,
            b.custodyDeadline,
            bytes32(0),
            _listingSalt(bundleId, b.manifestHash, block.chainid),
            OPENSEA_CONDUIT_KEY,
            consideration.length
        );
    }

    /**
     * Step 8: accept native consideration from Seaport only, and account for
     * NOTHING here.
     *
     * fulfillAvailableAdvancedOrders aggregates same-recipient native items
     * across orders into ONE transfer, so the amount arriving here is not
     * per-bundle and must never be used as a credit. The credit is written in
     * the first-exit callback instead, where the bundle is known.
     */
    receive() external payable {
        if (msg.sender != SEAPORT) revert Unauthorized();
    }

    /**
     * Step 12: EIP-1271, scoped to exactly one thing - the escrow's own live
     * listings.
     *
     * WHY THIS EXISTS
     * The escrow is the offerer, and an offerer that is a contract has no
     * private key. OpenSea's API validates the order by asking the offerer
     * whether a signature over the EIP-712 signing digest is valid. Without
     * this, the escrow can validate orders on chain but cannot get one
     * ingested by the API.
     *
     * WHAT IT WILL AND WILL NOT APPROVE
     * It approves a digest only when ALL of the following hold, every one of
     * them re-read at call time rather than trusted from the mapping:
     *   - the digest was produced by this contract inside list();
     *   - the bundle is still Listed and has never been issued;
     *   - the listing has not expired - Seaport would refuse an expired order
     *     anyway, but there is no reason to let a dead one be ingested;
     *   - re-deriving the digest from the bundle's CURRENT stored order hash
     *     and Seaport's CURRENT domain separator reproduces the same digest,
     *     which is what rejects a stale digest and a wrong chain or protocol;
     *   - Seaport still reports the order validated, uncancelled and unfilled.
     * It will not approve an arbitrary digest under any circumstances. There is
     * no owner override and no way to add a digest except by listing a bundle.
     *
     * THE SIGNATURE BYTES ARE NOT INSPECTED, deliberately. The digest is the
     * authorization: it can only exist because this contract built and
     * validated that exact order, and it commits to the offerer, the offer, the
     * consideration, the counter, the salt, the chain and the Seaport address.
     * Requiring particular bytes on top would add no security and would make
     * ingestion depend on guessing what the API sends, which is unproven. The
     * publication payload may therefore carry an empty signature, `0x`.
     *
     * UNPROVEN: that OpenSea's API accepts this, or accepts an empty signature
     * field. That is a server behaviour and no local test can establish it.
     */
    function isValidSignature(bytes32 digest, bytes calldata) external view returns (bytes4) {
        uint256 bundleId = _listingDigestBundle[digest];
        if (bundleId == 0) return bytes4(0xffffffff);
        Bundle storage b = _bundles[bundleId];
        if (b.state != BundleState.Listed || b.everIssued) return bytes4(0xffffffff);
        if (block.timestamp >= b.custodyDeadline) return bytes4(0xffffffff);
        if (_signingDigest(b.orderHash) != digest) return bytes4(0xffffffff);
        (bool validated, bool cancelled, uint256 filled,) = ISeaport(SEAPORT).getOrderStatus(b.orderHash);
        if (!validated || cancelled || filled != 0) return bytes4(0xffffffff);
        return 0x1626ba7e;
    }

    /**
     * The EIP-712 signing digest of an order hash, under the domain separator
     * the DEPLOYED Seaport reports. Read live rather than recomputed so a
     * different chain id, a different Seaport, or a Seaport that changed its
     * domain all produce a different digest and stop validating.
     */
    function _signingDigest(bytes32 orderHash) private view returns (bytes32) {
        (, bytes32 domainSeparator,) = ISeaport(SEAPORT).information();
        return keccak256(abi.encodePacked(bytes2(0x1901), domainSeparator, orderHash));
    }

    /// The digest a publication payload must present for `bundleId`, or zero
    /// when the bundle has no listing. View-only convenience for the offchain
    /// package; `isValidSignature` does not consult it.
    function listingSigningDigest(uint256 bundleId) external view returns (bytes32) {
        bytes32 orderHash = _bundles[bundleId].orderHash;
        return orderHash == bytes32(0) ? bytes32(0) : _signingDigest(orderHash);
    }

    /// Proceeds credited to a seller at first exit; withdrawn separately.
    event ProceedsCredited(uint256 indexed bundleId, address indexed seller, address indexed token, uint256 amount);
    event ProceedsWithdrawn(address indexed seller, address indexed token, uint256 amount);
    /// The protocol fee frozen at `list()`, retained from the escrow item at first exit.
    event ProtocolFeeSnapshot(uint256 indexed bundleId, address indexed token, uint256 amount);
    /// Option B: the creator royalty frozen at list() (skipped when zero).
    event CreatorRoyaltySnapshot(uint256 indexed bundleId, address indexed recipient, address indexed token, uint256 amount);
    /// Option B: the frozen royalty credited to its recipient at first exit.
    event CreatorRoyaltyCredited(uint256 indexed bundleId, address indexed recipient, address indexed token, uint256 amount);
    event SurplusWithdrawn(address indexed token, address indexed to, uint256 amount, address indexed by);

    function claimable(address seller, address token) external view returns (uint256) {
        return _claimable[seller][token];
    }

    /**
     * Step 9: seller pull-withdrawal. Locked and CEI.
     *
     * Payment is never pushed during fulfilment: a seller wallet that reverts
     * would brick the buyer's purchase, not just its own payout.
     */
    function withdraw(address token) external externalEntry returns (uint256) {
        return _withdrawTo(msg.sender, token);
    }

    /**
     * Permissionless payout of `account`'s credit TO `account` (option B,
     * escrow-option-b-sep26): a creator that is a contract unable to call
     * `withdraw` (a plain splitter, a restricted multisig) can still be paid.
     * Anyone may trigger it; the funds only ever go to the credited account.
     */
    function withdrawFor(address account, address token) external externalEntry returns (uint256) {
        return _withdrawTo(account, token);
    }

    /// The one withdrawal path: debit (effects), event, then the payment last.
    function _withdrawTo(address account, address token) private returns (uint256 amount) {
        amount = _debitOwed(account, token);
        emit ProceedsWithdrawn(account, token, amount);
        _pay(token, account, amount);
    }

    // ---- the owed ledger: the ONLY code that touches `_claimable` ------------
    // (a source-guard test counts its occurrences; a write anywhere else fails it)

    function _creditOwed(address account, address token, uint256 amount) private {
        _claimable[account][token] += amount;
        _totalOwed[token] += amount;
    }

    function _debitOwed(address account, address token) private returns (uint256 amount) {
        mapping(address => uint256) storage owedTo = _claimable[account];
        amount = owedTo[token];
        if (amount == 0) revert InvalidState();
        owedTo[token] = 0;
        // UNCHECKED TRIM 2 (size decision 2026-09-25). Relies on invariant (i),
        // totalOwed == sum of claimable, so amount <= total and this cannot wrap.
        // Fail-safe: if (i) were broken the total wraps HIGH, above the balance,
        // and every withdrawSurplus then reverts (Panic 0x11) - it never pays.
        unchecked {
            _totalOwed[token] -= amount;
        }
    }

    /// The one outbound payment: native by call, ERC-20 by SafeERC20. Always last.
    function _pay(address token, address to, uint256 amount) private {
        if (token == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert InvalidRecipient();
        } else {
            SafeERC20.safeTransfer(IERC20(token), to, amount);
        }
    }

    function _balanceOf(address token) private view returns (uint256) {
        return token == address(0) ? address(this).balance : IERC20(token).balanceOf(address(this));
    }

    function totalOwed(address token) external view returns (uint256) {
        return _totalOwed[token];
    }

    /// @notice The admin takes surplus only: never more than `balance - totalOwed`
    /// (the retained protocol fees and any stray funds), so sellers' proceeds are
    /// unreachable. One rule for every token. Surplus = `balance - totalOwed(token)`.
    function withdrawSurplus(address token, address to, uint256 amount)
        external
        externalEntry
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        // LATCH: the owed ledger exists only once the seeder ran inside the
        // upgrade (reinitializer(2)). A bare upgrade to this implementation
        // leaves _totalOwed at zero, where the "surplus" would be every seller's
        // proceeds - so until seeded there is no surplus at all.
        if (_getInitializedVersion() < 2 || to == address(0) || amount == 0) revert InvalidState();
        // SIZE TRIM 3, the cap: surplus = balance - totalOwed. CHECKED on purpose: if the
        // balance ever fell below what is owed, this subtraction reverts
        // (Panic 0x11) - fails safe - rather than letting any amount through.
        // (Chosen over an explicit InvalidState check to fit EIP-170; size
        // decision 2026-09-25.) The cap is computed before any transfer.
        if (amount > _balanceOf(token) - _totalOwed[token]) revert InvalidState();
        emit SurplusWithdrawn(token, to, amount, msg.sender);
        _pay(token, to, amount);
    }

    function _listingSalt(uint256 bundleId, bytes32 manifestHash, uint256 chainId) private view returns (uint256) {
        return
            uint256(keccak256(abi.encode("NEWTRADE_PRIMARY_V2_BETA", chainId, address(this), bundleId, manifestHash)));
    }

    /// @dev Compatibility alias: the Bundle NFT's first-exit callback (legacy
    /// selector name kept for the deployed collection). Credits the seller the
    /// escrow item less the fee frozen at list(); the fee stays as surplus.
    /// PROTOCOL FEE (escrow-fee-from-proceeds-sep25): frozen per bundle at list()
    /// from the LIVE bps (ProtocolFeeSnapshot) and deducted from the escrow item
    /// at first exit. The seller's exact consideration does NOT bind it: a bps
    /// change between a quote and list() binds that listing; a change after list()
    /// binds only later list() calls. Capped at MAX_PROTOCOL_FEE_BPS (1,000);
    /// the admin that sets it is the same trust as the upgrader.
    function onReceiptFirstExit(address operator, address from, address to, uint256 receiptId) external {
        // Step 1: authenticate the first wrapper exit from escrow through Seaport.
        // Step 10: bind the exit to THIS bundle's current order, not merely to
        // "some Seaport call".
        //
        // operator is the CONDUIT, not Seaport: with a non-zero conduit key
        // Seaport transfers via conduit.execute, so the receipt sees the
        // conduit as msg.sender/auth.
        //
        // The registry's substandard-8 authorization is per tokenId and names
        // no operator, and a whitelisted operator could in principle move the
        // receipt outside a sale - so the operator check alone is not enough.
        // Seaport writes order status BEFORE transferring the offer item, so
        // the status of this bundle's CURRENT hash is readable here and is what
        // makes the exit exact. An obsolete order fails it without needing any
        // cancellation.
        if (msg.sender != address(_receipt) || operator != OPENSEA_CONDUIT || from != address(this)) {
            revert InvalidCallback();
        }
        Bundle storage b = _bundles[receiptId];
        if (b.state != BundleState.Listed || b.everIssued || _receipt.ownerOf(receiptId) != to) {
            revert InvalidCallback();
        }
        // partial-release-oct20 (D5a): the vault can never redeem, so it is refused too.
        if (
            to == address(0) || to == address(this) || to == address(_receipt) || to == address(_vault)
                || _selfBound(to, b)
        ) revert InvalidRecipient();

        // The current order must be validated, uncancelled and FULLY filled.
        (bool validated, bool cancelled, uint256 filled, uint256 size) =
            ISeaport(SEAPORT).getOrderStatus(b.orderHash);
        if (!validated || cancelled || filled == 0 || filled != size) revert InvalidCallback();

        // Step 2: permanently record issuance to the wrapper's first recipient.
        b.state = BundleState.Issued;
        b.everIssued = true;

        // Credit the stored seller-net once. Seaport reverts the whole call
        // unless every consideration item is delivered, so a credit written
        // here implies the funds arrived - atomically, without ever inspecting
        // a balance.
        // The protocol fee frozen at list() stays in the escrow as surplus: only
        // the net is owed to the seller. Validation guaranteed owed >= fee;
        // pre-upgrade bundles have a zero fee and are credited the full item.
        // Option B: the creator royalty frozen at list() is credited out of the
        // same item, to its ERC-2981 recipient, through the same ledger.
        // Pre-upgrade bundles have an all-zero snapshot: no creator credit.
        uint256 owed = _escrowRecipientAmount[receiptId];
        if (owed != 0) {
            _escrowRecipientAmount[receiptId] = 0;
            RoyaltySnapshot storage s = _royaltySnapshots[receiptId];
            uint256 royalty = s.creatorNet;
            uint256 net;
            // UNCHECKED TRIM 1 (size decision 2026-09-25). Relies on list()'s
            // item0 >= royalty + fee (and a zero fee and royalty for pre-upgrade
            // bundles), so owed >= royalty + fee. Fail-safe: were it broken, net
            // wraps HIGH; _creditOwed then overflows (the fill reverts) or totalOwed
            // exceeds the balance, so withdrawSurplus reverts (Panic 0x11) and the
            // seller's own withdraw cannot be paid - no path pays out.
            unchecked {
                net = owed - royalty - _protocolFeeAmount[receiptId];
            }
            _creditOwed(b.seller, b.paymentToken, net);
            emit ProceedsCredited(receiptId, b.seller, b.paymentToken, net);
            if (royalty != 0) {
                _creditOwed(s.creator, b.paymentToken, royalty);
                emit CreatorRoyaltyCredited(receiptId, s.creator, b.paymentToken, royalty);
            }
        }
        b.firstRecipient = to;
        b.issuedAt = uint64(block.timestamp);
        emit BundleIssued(receiptId, b.orderHash, to, b.issuedAt);

    }

    function redeemToFreshAccount(uint256 bundleId, bytes32 holderSalt)
        external
        externalEntry
        returns (address account)
    {
        Bundle storage b = _bundles[bundleId];

        // Step 1: require the current wrapper holder, not a prior owner or approved operator.
        if (
            b.state != BundleState.Issued || !b.everIssued || _receipt.ownerOf(bundleId) != msg.sender
                || _selfBound(msg.sender, b)
        ) revert Unauthorized();

        // Step 2: create a fresh account under the policy pinned at deposit.
        bytes32 fullSalt = _freshSalt(bundleId, msg.sender, holderSalt);
        account = _vault.createFreshAccount(
            b.accountRegistry,
            b.accountProxy,
            b.accountImplementation,
            fullSalt,
            b.controllingNFT,
            b.controllingTokenId,
            msg.sender
        );

        // Step 3: burn the wrapper and begin the per-entry release: the NFT to its
        // holder, the manifest entries to the account. The state is written BEFORE
        // the vault call so a token callback reads a coherent bundle; it closes to
        // Redeemed only when the vault reports nothing held (partial-release-oct20).
        // The account-owner / valid-signer check now runs INSIDE the vault's NFT
        // attempt, against the recorded redeemer, so a later retry by anyone
        // completes it (design 2A / section 4).
        b.state = BundleState.Redeeming;
        if (_burnAndRelease({bundleId: bundleId, b: b, mode: ReleaseMode.Redeem, extrasTo: account, nftTo: msg.sender})) {
            b.state = BundleState.Redeemed;
        }

        // Step 4: publish the completed fresh-account redemption.
        emit BundleRedeemed(
            bundleId,
            msg.sender,
            RedemptionMode.FreshAccount,
            account,
            b.controllingNFT,
            b.controllingTokenId,
            uint64(block.timestamp)
        );
    }

    /// @notice Seller exit for an expired bundle that was never issued. The controlling NFT
    /// always returns to the seller's wallet; every manifest asset goes to `extrasTo`, which the
    /// seller chooses. For a bundle deposited with `depositFromAccount` the seller passes the
    /// original ERC-6551 account (the `sourceAccount` of `BundleMigrated`) to put the assets back
    /// where they came from; passing their own wallet keeps the pre-change behaviour.
    /// @dev `extrasTo` is NOT validated beyond being non-zero: the assets are the seller's own
    /// and the destination is the seller's choice. Not to be confused with `withdraw(token)`,
    /// which pays out sale proceeds.
    function reclaim(uint256 bundleId, address extrasTo) external externalEntry {
        // A missing destination is a different mistake from missing authority: say so.
        if (extrasTo == address(0)) revert ZeroAddress();
        Bundle storage b = _bundles[bundleId];

        // Step 1: only the seller may reclaim an expired bundle that was never issued.
        if (
            msg.sender != b.seller || block.timestamp < b.custodyDeadline || b.everIssued
                || (b.state != BundleState.Deposited && b.state != BundleState.Listed)
                || _receipt.ownerOf(bundleId) != address(this)
        ) revert Unauthorized();

        // Step 2: burn the wrapper, return the controlling NFT to the seller and the
        // manifest assets to the seller's chosen destination.
        b.state = BundleState.Reclaiming;
        if (_burnAndRelease({bundleId: bundleId, b: b, mode: ReleaseMode.Reclaim, extrasTo: extrasTo, nftTo: b.seller})) {
            b.state = BundleState.Reclaimed;
        }
        emit BundleReclaimed(bundleId, b.seller, extrasTo, uint64(block.timestamp));
    }

    /// @notice Releases what the vault still holds for a bundle whose redemption or
    /// reclaim has begun (partial-release-oct20, F-01). `mask` names manifest entries
    /// by index, bit 32 the controlling NFT. Anyone may call it: the destinations
    /// were recorded at the first call and never change (D3). `data` empty is the
    /// plain retry; a non-empty `data` is a command the vault interprets for the
    /// escrow's caller only (D2-B: the recorded redeemer redirecting the manifest
    /// entries while the NFT is held). The bundle closes when the vault reports
    /// nothing held.
    function withdrawRemaining(uint256 bundleId, uint256 mask, bytes calldata data) external externalEntry {
        Bundle storage b = _bundles[bundleId];
        if (b.state != BundleState.Redeeming && b.state != BundleState.Reclaiming) revert InvalidState();
        if (_vault.releaseRemaining{gas: gasleft() - VAULT_CALL_RESERVE}(bundleId, mask, msg.sender, data)) {
            b.state = b.state == BundleState.Redeeming ? BundleState.Redeemed : BundleState.Reclaimed;
        }
    }

    /// @dev Exit shared by redemption and reclaim: burn the Bundle NFT, then begin
    /// the vault's per-entry release of every manifest asset to `extrasTo` and the
    /// controlling NFT to `nftTo`. Named arguments at every call site, so a swapped
    /// destination is visible instead of a silent positional accident. The vault
    /// keeps its own gas reserve for its bookkeeping; the escrow keeps
    /// VAULT_CALL_RESERVE for the state write after the call (design 2.3).
    /// Returns true when nothing of the bundle is held any more.
    function _burnAndRelease(uint256 bundleId, Bundle storage b, ReleaseMode mode, address extrasTo, address nftTo)
        private
        returns (bool closed)
    {
        _receipt.controllerBurn(bundleId);
        closed = _vault.beginRelease{gas: gasleft() - VAULT_CALL_RESERVE}({
            bundleId: bundleId,
            mode: mode,
            extrasTo: extrasTo,
            nftTo: nftTo
        });
    }

    function previewOrderParameters(
        uint256 bundleId,
        address paymentToken,
        uint256 price,
        uint64 deadline,
        uint16 maxRoyaltyBps,
        Payout[] calldata payouts,
        uint64 startTime
    ) external view returns (OrderParameters memory) {
        Bundle storage b = _bundles[bundleId];
        if (
            b.state != BundleState.Deposited || deadline != b.custodyDeadline || price == 0
                || !_paymentAllowed[paymentToken]
        ) revert InvalidOrder();
        Payout[] memory items = payouts;
        _validateExactConsideration(b, price, maxRoyaltyBps, items);
        return _previewOrder(bundleId, b, paymentToken, items, startTime);
    }

    /// @notice Returns the live fee inputs an app must use to construct the
    /// seller-approved exact consideration array. NEITHER amount is a
    /// consideration item (option B, escrow-option-b-sep26): both are settled out
    /// of the escrow item at first exit - `protocolAmount` retained as surplus,
    /// `royaltyAmount` credited to `royaltyRecipient` (always the controlling
    /// NFT's ERC-2981 recipient) - so item 0 must cover both, and no item may pay
    /// `royaltyRecipient`. `list` requotes the royalty and freezes both LIVE at
    /// `list` (ProtocolFeeSnapshot, CreatorRoyaltySnapshot).
    function quotePrimaryFees(uint256 bundleId, uint256 price)
        external
        view
        returns (address treasury, uint256 protocolAmount, address royaltyRecipient, uint256 royaltyAmount)
    {
        (royaltyRecipient, royaltyAmount) = _depositedRoyalty(bundleId, price);
        treasury = _treasury;
        protocolAmount = price * _protocolFeeBps / TOTAL_BPS;
        if (royaltyAmount + protocolAmount > price) revert InvalidConsideration();
    }

    /// @dev The controlling NFT's live ERC-2981 answer for a bundle that is
    /// still Deposited.
    function _depositedRoyalty(uint256 bundleId, uint256 price) private view returns (address, uint256) {
        Bundle storage b = _bundles[bundleId];
        if (b.state != BundleState.Deposited || price == 0) revert InvalidOrder();
        return _royalty(b.controllingNFT, b.controllingTokenId, price);
    }

    /// @notice The creator royalty frozen at listing (option B): `creator` is the
    /// ERC-2981 recipient, `grossRoyalty == creatorNet` the amount credited at
    /// first exit; router, treasury and service fee are always zero. All-zero
    /// for every bundle listed before option B.
    function getRoyaltySnapshot(uint256 bundleId) external view returns (RoyaltySnapshot memory) {
        return _royaltySnapshots[bundleId];
    }

    function getOrder(uint256 bundleId)
        external
        view
        returns (
            OrderParameters memory parameters,
            uint256 counter,
            bytes32 orderHash,
            uint256 chainId,
            address protocol
        )
    {
        Bundle storage b = _bundles[bundleId];
        if (b.orderHash == bytes32(0)) revert InvalidState();
        return (_storedOrder(bundleId, b, _orderStartTimes[bundleId]), b.orderCounter, b.orderHash, b.orderChainId, SEAPORT);
    }

    function computeManifestHash(address nft, uint256 id, ManifestEntry[] calldata entries)
        external
        view
        returns (bytes32)
    {
        return keccak256(abi.encode(uint256(2), block.chainid, address(this), nft, id, entries));
    }

    function computeFreshAccount(uint256 bundleId, address holder, bytes32 holderSalt)
        external
        view
        returns (address account, bytes32 fullSalt)
    {
        Bundle storage b = _bundles[bundleId];
        fullSalt = _freshSalt(bundleId, holder, holderSalt);
        account =
            _vault.computeAccount(b.accountRegistry, b.accountProxy, fullSalt, b.controllingNFT, b.controllingTokenId);
    }

    function _freshSalt(uint256 bundleId, address holder, bytes32 holderSalt) private view returns (bytes32) {
        return keccak256(
            abi.encode("NEWTRADE_FRESH_ACCOUNT_V2_BETA", block.chainid, address(this), bundleId, holder, holderSalt)
        );
    }

    function _selfBound(address holder, Bundle storage b) private view returns (bool) {
        return _vault.selfBound(holder, b.controllingNFT, b.controllingTokenId);
    }

    function getBundle(uint256 id) external view returns (Bundle memory) {
        return _bundles[id];
    }

    function getManifest(uint256 id) external view returns (ManifestEntry[] memory) {
        // Pure pass-through of the vault's answer, forwarded as raw returndata
        // so this contract carries no second copy of the manifest codec. The
        // vault is protocol code bound at initialize; its revert data bubbles.
        (bool ok, bytes memory data) = address(_vault).staticcall(abi.encodeCall(INewTradeVaultV2.getManifest, (id)));
        assembly ("memory-safe") {
            if iszero(ok) { revert(add(data, 32), mload(data)) }
            return(add(data, 32), mload(data))
        }
    }

    function getPayouts(uint256 id) external view returns (Payout[] memory) {
        return _payouts[id];
    }

    function receiptMetadata(uint256 id)
        external
        view
        returns (uint256 chainId, address controllingNFT, uint256 controllingTokenId, bytes32 manifestHash)
    {
        Bundle storage b = _collectionBundle(id);
        return (block.chainid, b.controllingNFT, b.controllingTokenId, b.manifestHash);
    }

    /// @notice Lets the ERC-721C wrapper proxy the original NFT's royalty rule:
    /// a pure per-token mirror of the controlling NFT's live ERC-2981 answer,
    /// recipient and amount, in every state (option B retired the router
    /// substitution).
    function receiptRoyaltyInfo(uint256 id, uint256 salePrice)
        external
        view
        returns (address recipient, uint256 amount)
    {
        Bundle storage b = _collectionBundle(id);
        (recipient, amount) = _royalty(b.controllingNFT, b.controllingTokenId, salePrice);
    }

    /// @dev Shared gate for the collection's callbacks: only the Bundle
    /// collection may ask, and only about a bundle that exists.
    function _collectionBundle(uint256 id) private view returns (Bundle storage b) {
        if (msg.sender != address(_receipt)) revert Unauthorized();
        b = _bundles[id];
        if (b.state == BundleState.None) revert InvalidState();
    }

    /// @dev Compatibility alias: returns the NewTradeBundle collection.
    function receipt() external view returns (address) {
        return address(_receipt);
    }

    function vault() external view returns (address) {
        return address(_vault);
    }

    function migrationNonceUsed(address seller, bytes32 nonce) external view returns (bool) {
        return _vault.migrationNonceUsed(seller, nonce);
    }

    function isPaymentTokenAllowed(address token) external view returns (bool) {
        return _paymentAllowed[token];
    }

    function setAssetKind(address token, AssetKind kind, bool allowed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 revision = _vault.setAssetKind(token, kind, allowed);
        emit AssetKindAllowed(token, kind, allowed);
        emit AssetAllowlistMembershipUpdated(token, kind, allowed, revision);
    }

    function setAssetAcceptanceMode(AssetKind kind, AcceptanceMode mode) external onlyRole(DEFAULT_ADMIN_ROLE) {
        (AcceptanceMode oldMode, uint256 revision) = _vault.setAssetAcceptanceMode(kind, mode);
        emit AssetAcceptanceModeUpdated(kind, oldMode, mode, revision);
    }

    function setPaymentTokenAllowed(address token, bool allowed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token != address(0) && token.code.length == 0) revert UnsupportedAsset();
        _paymentAllowed[token] = allowed;
        emit PaymentTokenAllowed(token, allowed);
    }

    /// @notice Binds only list() calls made after it (listed bundles keep their
    /// snapshot); reverts above MAX_PROTOCOL_FEE_BPS.
    function setProtocolFeeBps(uint96 fee) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (fee > MAX_PROTOCOL_FEE_BPS) revert InvalidConsideration();
        uint96 old = _protocolFeeBps;
        _protocolFeeBps = fee;
        emit ProtocolFeeUpdated(old, fee);
    }

    function setTreasury(address treasury_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (treasury_ == address(0)) revert ZeroAddress();
        address old = _treasury;
        _treasury = treasury_;
        emit TreasuryUpdated(old, treasury_);
    }

    function setFreshAccountPolicy(address registry, address accountProxy, address implementation, bool enabled)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _setFreshAccountPolicy(registry, accountProxy, implementation, enabled);
    }

    /// @notice Explicitly approves the exact runtime code at a registry or
    /// implementation address. A changed codehash is no longer trusted.
    function setTrustedAccountCode(address target, bool registry, bool trusted) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _trustAccountCode(target, registry, trusted);
        if (
            trusted == false
                && (target == _accountRegistry || target == _accountProxy || target == _accountImplementation)
        ) {
            _freshAccountsEnabled = false;
        }
    }

    function trustedAccountCode(address target, bool registry) external view returns (bool) {
        return _codeTrusted(target, registry);
    }

    /// @dev True only when an explicit approval exists for `target` and its
    /// current runtime code still hashes to that approval.
    function _codeTrusted(address target, bool registry) private view returns (bool) {
        bytes32 approved = registry ? _trustedRegistryCodehash[target] : _trustedImplementationCodehash[target];
        return approved != bytes32(0) && approved == target.codehash;
    }

    function _trustAccountCode(address target, bool registry, bool trusted) private {
        if (target.code.length == 0) revert FreshAccountUnavailable();
        bytes32 hash = trusted ? target.codehash : bytes32(0);
        if (registry) _trustedRegistryCodehash[target] = hash;
        else _trustedImplementationCodehash[target] = hash;
        emit TrustedAccountCodeUpdated(target, registry, hash, trusted);
    }

    function _setFreshAccountPolicy(address registry, address accountProxy, address implementation, bool enabled)
        private
    {
        if (
            enabled
                && (
                    !_codeTrusted(registry, true) || !_codeTrusted(accountProxy, false)
                        || !_codeTrusted(implementation, false)
                )
        ) revert FreshAccountUnavailable();
        _accountRegistry = registry;
        _accountProxy = accountProxy;
        _accountImplementation = implementation;
        _freshAccountsEnabled = enabled;
        emit FreshAccountPolicyUpdated(registry, accountProxy, implementation, enabled);
    }

    function _trustedAccountPolicy() private view returns (bool) {
        return _trustedRegistryCodehash[_accountRegistry] == _accountRegistry.codehash
            && _trustedImplementationCodehash[_accountProxy] == _accountProxy.codehash
            && _trustedImplementationCodehash[_accountImplementation] == _accountImplementation.codehash;
    }

    function setMigrationEnabled(bool enabled) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _vault.setMigrationEnabled(enabled);
    }

    function lockUpgrades() external onlyRole(UPGRADER_ROLE) {
        if (_upgradesLocked) revert UpgradeLocked();
        _upgradesLocked = true;
        emit UpgradesLocked();
    }

    function _authorizeUpgrade(address) internal override onlyRole(UPGRADER_ROLE) {
        if (_upgradesLocked) revert UpgradeLocked();
    }

    function _components(OrderParameters memory p, uint256 counter) private pure returns (OrderComponents memory) {
        return OrderComponents(
            p.offerer,
            p.zone,
            p.offer,
            p.consideration,
            p.orderType,
            p.startTime,
            p.endTime,
            p.zoneHash,
            p.salt,
            p.conduitKey,
            counter
        );
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
