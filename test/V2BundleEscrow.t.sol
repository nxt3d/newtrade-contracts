// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {NewTradeEscrowV2} from "../src/NewTradeEscrowV2.sol";
import {NewTradeBundle} from "../src/NewTradeBundle.sol";
import {BundleDeploy} from "./helpers/BundleDeploy.sol";
import {NewTradeV2Vault} from "./legacy/NewTradeV2Vault.sol";
import {NewTradeV2VaultV2} from "../src/NewTradeV2VaultV2.sol";
import {VaultV2Deploy, VaultV2Views} from "./helpers/VaultV2Deploy.sol";
import {
    AcceptanceMode,
    AssetKind,
    BundleState,
    ManifestEntry,
    Payout,
    Bundle,
    V2Initialization
} from "../src/NewTradeV2Types.sol";
import {ISeaport, Order, OrderType, OrderParameters, OrderComponents} from "../src/interfaces/ISeaport.sol";
import {IERC6551ExecutableAccount} from "../src/interfaces/IERC6551.sol";
import {MockERC20, MockERC721, MockERC1155} from "./mocks/TokenMocks.sol";
import {ConduitMock} from "./helpers/ConduitMock.sol";
import {SeaportV2Mock} from "./helpers/SeaportV2Mock.sol";
import {
    Mock6551Registry,
    Mock6551Implementation,
    MockTokenboundAccountProxy,
    Mock6551WrongOwnerImplementation,
    Mock6551InvalidSignerImplementation,
    Mock6551RevertingOwnerImplementation,
    Mock6551SpoofAccount,
    Mock6551RevertingTokenHolder,
    Mock6551DivergentRegistry,
    Mock6551WrongTupleRegistry,
    ToggleReleaseFailureERC20,
    ToggleReleaseFailureERC721,
    ToggleReleaseFailureERC1155
} from "./helpers/ERC6551Mocks.sol";

struct RetiredSaleAuthorizationV2 {
    address seller;
    uint256 bundleId;
    uint256 receiptId;
    bytes32 manifestHash;
    uint64 custodyDeadline;
    address paymentToken;
    uint256 price;
    bytes32 nonce;
    bytes32 considerationHash;
    bytes32 agentDataHash;
    uint16 maxRoyaltyBps;
}

struct RetiredSellerRecipient {
    address payable recipient;
    uint16 bps;
}

contract SecondaryMarketplace {
    function transfer(NewTradeBundle receipt, address from, address to, uint256 id) external {
        receipt.transferFrom(from, to, id);
    }
}

contract RejectingReceiptHolder {
    function redeem(NewTradeEscrowV2 escrow, uint256 id, bytes32 salt) external {
        escrow.redeemToFreshAccount(id, salt);
    }
}

contract FalseStandardClaims {
    function supportsInterface(bytes4) external pure returns (bool) {
        return true;
    }
}

contract RedeemingReceiptReceiver is IERC721Receiver, IERC1155Receiver {
    NewTradeEscrowV2 immutable escrow;
    NewTradeBundle immutable receipt;
    bytes32 immutable salt;
    address public account;

    constructor(NewTradeEscrowV2 escrow_, NewTradeBundle receipt_, bytes32 salt_) {
        escrow = escrow_;
        receipt = receipt_;
        salt = salt_;
    }

    function onERC721Received(address, address, uint256 id, bytes calldata) external returns (bytes4) {
        if (msg.sender == address(receipt)) account = escrow.redeemToFreshAccount(id, salt);
        return IERC721Receiver.onERC721Received.selector;
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC1155Receiver.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return IERC1155Receiver.onERC1155BatchReceived.selector;
    }

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == type(IERC721Receiver).interfaceId || id == type(IERC1155Receiver).interfaceId
            || id == type(IERC165).interfaceId;
    }
}

contract AppendedStorageEscrowV2 is NewTradeEscrowV2 {
    uint256 public appendedValue;

    /// partial-release-oct20: version 4, the next after `initializeVault` (3).
    function initializeAppendedValue(uint256 value) external reinitializer(4) onlyRole(DEFAULT_ADMIN_ROLE) {
        appendedValue = value;
    }
}

contract V2BundleEscrowTest is Test {
    using VaultV2Views for NewTradeV2VaultV2;

    event AssetAcceptanceModeUpdated(
        AssetKind indexed kind, AcceptanceMode oldMode, AcceptanceMode newMode, uint256 indexed policyRevision
    );
    event AssetAllowlistMembershipUpdated(
        address indexed token, AssetKind indexed kind, bool allowed, uint256 indexed policyRevision
    );

    address constant SEAPORT = 0x0000000000000068F116a894984e2DB1123eB395;
    address seller = address(0xA11CE);
    address buyer = address(0xB0B);
    address holderB = address(0xBEE);
    address holderC = address(0xCEE);
    address treasury = address(0xFEE);
    address receiptOwner = address(0x0113E2);
    uint256 constant PRICE = 1 ether;

    NewTradeEscrowV2 escrow;
    NewTradeBundle receipt;
    /// partial-release-oct20: the upgradeable per-entry vault behind its proxy,
    /// switched in through `initializeVault` exactly as in production (D1).
    NewTradeV2VaultV2 custody;
    /// The constructor-built vault the escrow was initialized with; retired by the switch.
    NewTradeV2Vault legacyVault;
    /// Set (then `setUp()` re-run) by tests that replay an upgrade the live escrow
    /// ran BEFORE the F-01 switch (the Sep-26 seeder, reinitializer(2)): the fixture
    /// stays on the legacy vault until the test performs the switch itself, in the
    /// production order. `custody` is zero until then.
    bool deferVaultSwitch;
    address[] fixtureTokens;
    AssetKind[] fixtureKinds;
    AcceptanceMode[3] fixtureModes;
    MockERC20 erc20;
    MockERC721 control;
    MockERC721 extra721;
    MockERC1155 erc1155;
    Mock6551Registry registry;
    Mock6551Implementation implementation;
    MockTokenboundAccountProxy accountProxy;
    uint64 deadline;
    address constant CONDUIT = 0x1E0049783F008A0085193E00003D00cd54003c71;

    function setUp() public virtual {
        // A REAL clock. Foundry starts at block.timestamp == 1, which is exactly
        // the legacy NEW_LISTING_START_TIME, so every assertion about a stored
        // listing timestamp would pass without proving anything.
        vm.warp(1_757_000_000);
        vm.etch(SEAPORT, address(new SeaportV2Mock()).code);
        // The conduit is a real operator in this design, so it must exist locally.
        vm.etch(CONDUIT, address(new ConduitMock()).code);
        SeaportV2Mock(SEAPORT).setCounter(42);
        // vm.etch copies runtime code but not constructor-written storage, so
        // the mock's domain separator has to be set explicitly or it is zero.
        SeaportV2Mock(SEAPORT).setDomainSeparator(keccak256("BASE_SEAPORT_1_6_DOMAIN"));
        erc20 = new MockERC20("Bundle USD", "BUSD", 18);
        control = new MockERC721();
        extra721 = new MockERC721();
        erc1155 = new MockERC1155();
        registry = new Mock6551Registry();
        implementation = new Mock6551Implementation();
        accountProxy = new MockTokenboundAccountProxy(address(implementation));
        address[] memory payments = new address[](2);
        payments[0] = address(0);
        payments[1] = address(erc20);
        address[] memory tokens = new address[](4);
        tokens[0] = address(erc20);
        tokens[1] = address(control);
        tokens[2] = address(extra721);
        tokens[3] = address(erc1155);
        AssetKind[] memory kinds = new AssetKind[](4);
        kinds[0] = AssetKind.ERC20;
        kinds[1] = AssetKind.ERC721;
        kinds[2] = AssetKind.ERC721;
        kinds[3] = AssetKind.ERC1155;
        AcceptanceMode[3] memory modes = [AcceptanceMode.Allowlist, AcceptanceMode.Allowlist, AcceptanceMode.Allowlist];
        receipt = BundleDeploy.deploy(address(this), SEAPORT, SEAPORT, receiptOwner);
        legacyVault = new NewTradeV2Vault(address(this), address(receipt), tokens, kinds, modes);
        V2Initialization memory c = V2Initialization(
            address(this),
            treasury,
            250,
            payments,
            tokens,
            kinds,
            modes,
            address(registry),
            address(accountProxy),
            address(implementation),
            address(receipt),
            address(legacyVault),
            SEAPORT,
            SEAPORT,
            address(0)
        );
        NewTradeEscrowV2 impl = new NewTradeEscrowV2();
        escrow =
            NewTradeEscrowV2(payable(address(new ERC1967Proxy(address(impl), abi.encodeCall(NewTradeEscrowV2.initialize, (c))))));
        receipt.bindController(address(escrow));
        legacyVault.bindController(address(escrow));
        fixtureTokens = tokens;
        fixtureKinds = kinds;
        fixtureModes = modes;
        control.mint(seller, 1);
        extra721.mint(seller, 7);
        erc20.mint(seller, 100 ether);
        erc1155.mint(seller, 3, 10);
        if (deferVaultSwitch) {
            delete custody;
            _approveSeller(address(legacyVault));
        } else {
            _switchVault();
        }
        deadline = uint64(block.timestamp + 1 days);
    }

    /// partial-release-oct20: the production switch (D1) with the fixture's policy
    /// replayed, and the seller's approvals moved to the new vault.
    function _switchVault() internal {
        custody = VaultV2Deploy.switchEscrowMirroring(escrow, address(receipt), fixtureTokens, fixtureKinds, fixtureModes);
        _approveSeller(address(custody));
    }

    function _approveSeller(address vault_) internal {
        vm.startPrank(seller);
        control.setApprovalForAll(vault_, true);
        extra721.setApprovalForAll(vault_, true);
        erc20.approve(vault_, type(uint256).max);
        erc1155.setApprovalForAll(vault_, true);
        vm.stopPrank();
    }

    function manifest() internal view returns (ManifestEntry[] memory es) {
        es = new ManifestEntry[](3);
        es[0] = ManifestEntry(AssetKind.ERC20, address(erc20), 0, 20 ether);
        es[1] = ManifestEntry(AssetKind.ERC721, address(extra721), 7, 1);
        es[2] = ManifestEntry(AssetKind.ERC1155, address(erc1155), 3, 4);
    }

    /// consideration[0] now pays the ESCROW, which is the offerer. OpenSea
    /// requires offerer == first recipient; the escrow settles onward via the
    /// pull-payment credit written at first exit.
    ///
    /// The protocol fee (0.025) is NOT an item (escrow-fee-from-proceeds-sep25):
    /// the escrow item carries the whole price and the first exit retains the
    /// fee, crediting the seller 0.975 = item0 - fee.
    function payouts() internal view returns (Payout[] memory ps) {
        ps = new Payout[](1);
        ps[0] = Payout(payable(address(escrow)), 1 ether);
    }

    function deposit() internal returns (uint256 id) {
        vm.prank(seller);
        id = escrow.deposit(address(control), 1, manifest(), deadline);
    }

    function list(uint256 id) internal returns (bytes32 hash, OrderParameters memory p) {
        Payout[] memory ps = payouts();
        p = escrow.previewOrderParameters(id, address(erc20), PRICE, deadline, 0, ps, uint64(block.timestamp));
        vm.prank(seller);
        hash = escrow.list(id, address(erc20), PRICE, deadline, 0, ps);
    }

    function issue(uint256 id, address recipient) internal returns (bytes32 hash, OrderParameters memory p) {
        (hash, p) = list(id);
        SeaportV2Mock(SEAPORT).fill(p, recipient);
    }

    /// A secondary sale approves the CONDUIT, because the conduit is the
    /// operator that actually moves the token when the order carries a non-zero
    /// conduit key. Approving Seaport here would rehearse a transfer the live
    /// flow never performs.
    function authorizedTransfer(address from, address to, uint256 id) internal {
        vm.prank(from);
        receipt.approve(CONDUIT, id);
        SeaportV2Mock(SEAPORT).transferReceipt(address(receipt), from, to, id);
    }

    function authorizedSafeTransfer(address from, address to, uint256 id) internal {
        vm.prank(from);
        receipt.approve(CONDUIT, id);
        SeaportV2Mock(SEAPORT).safeTransferReceipt(address(receipt), from, to, id);
    }

    /// partial-release-oct20 (D1, D8): `_vault` stays in the baseline slot (86bbb204:
    /// slot 6, offset 0; the type-level gate is test/layout/check_storage_layout.py), and
    /// the vault's upgrader is whoever holds the escrow's UPGRADER_ROLE.
    function test_VaultSwitchWritesTheBaselineSlot() public view {
        assertEq(vm.load(address(escrow), bytes32(uint256(6))), bytes32(uint256(uint160(address(custody)))));
    }

    function test_InitializeVaultIsOnceAndUpgraderOnly() public {
        vm.prank(buyer);
        vm.expectRevert();
        escrow.initializeVault(address(custody));
        vm.expectRevert();
        escrow.initializeVault(address(custody));
    }

    function test_VaultUpgradeFollowsTheEscrowsUpgraderRole() public {
        NewTradeV2VaultV2 next = new NewTradeV2VaultV2();
        vm.prank(buyer);
        vm.expectRevert(NewTradeV2VaultV2.UpgradeRefused.selector);
        custody.upgradeToAndCall(address(next), "");
        custody.upgradeToAndCall(address(next), "");
        assertEq(custody.implementation(), address(next));
        escrow.revokeRole(escrow.UPGRADER_ROLE(), address(this));
        vm.expectRevert(NewTradeV2VaultV2.UpgradeRefused.selector);
        custody.upgradeToAndCall(address(next), "");
    }

    function test_AppendOnlyUpgradePreservesStorageAndRoles() public {
        uint256 id = deposit();
        (bytes32 hash, OrderParameters memory p) = list(id);
        bytes32 bundleBefore = keccak256(abi.encode(escrow.getBundle(id)));
        bytes32 payoutsBefore = keccak256(abi.encode(escrow.getPayouts(id)));
        AppendedStorageEscrowV2 next = new AppendedStorageEscrowV2();
        escrow.upgradeToAndCall(address(next), abi.encodeCall(next.initializeAppendedValue, (123)));

        assertEq(AppendedStorageEscrowV2(payable(address(escrow))).appendedValue(), 123);
        assertEq(keccak256(abi.encode(escrow.getBundle(id))), bundleBefore);
        assertEq(keccak256(abi.encode(escrow.getPayouts(id))), payoutsBefore);
        assertTrue(escrow.hasRole(escrow.DEFAULT_ADMIN_ROLE(), address(this)));
        assertTrue(escrow.hasRole(escrow.UPGRADER_ROLE(), address(this)));
        assertTrue(escrow.trustedAccountCode(address(registry), true));
        assertTrue(escrow.trustedAccountCode(address(implementation), false));
        assertEq(escrow.getBundle(id).orderHash, hash);
        SeaportV2Mock(SEAPORT).fill(p, buyer);
        vm.prank(buyer);
        escrow.redeemToFreshAccount(id, bytes32(uint256(123)));

        vm.expectRevert();
        AppendedStorageEscrowV2(payable(address(escrow))).initializeAppendedValue(456);
        escrow.lockUpgrades();
        vm.expectRevert(NewTradeEscrowV2.UpgradeLocked.selector);
        escrow.upgradeToAndCall(address(next), "");
    }

    function test_DepositPinsPolicyAndMaintainsLiabilities() public {
        uint256 id = deposit();
        Bundle memory b = escrow.getBundle(id);
        assertEq(uint8(b.state), uint8(BundleState.Deposited));
        assertEq(b.accountRegistry, address(registry));
        assertEq(b.accountImplementation, address(implementation));
        assertEq(receipt.ownerOf(id), address(escrow));
        assertEq(custody.erc20Liability(address(erc20)), 20 ether);
        assertEq(custody.erc1155Liability(address(erc1155), 3), 4);
        assertEq(b.manifestHash, escrow.computeManifestHash(address(control), 1, manifest()));
        assertEq(receipt.getApproved(id), address(0));
    }

    function test_ReceiptMetadataIsSelfContainedAndClearlyIdentifiesWrapper() public {
        uint256 id = deposit();
        string memory uri = receipt.tokenURI(id);
        assertTrue(bytes(uri).length > bytes("data:application/json;base64,").length);
        assertEq(_prefix(uri, 29), "data:application/json;base64,");
        assertTrue(keccak256(bytes(uri)) != keccak256(bytes(control.tokenURI(1))));
        string memory json = string(_decodeBase64(_suffix(uri, 29)));
        vm.parseJson(json);
        assertEq(vm.parseJsonString(json, ".properties.bundle_id"), "1");
        assertEq(vm.parseJsonString(json, ".properties.chain_id"), vm.toString(block.chainid));
        assertEq(
            vm.parseJsonString(json, ".properties.original_nft_contract"),
            Strings.toHexString(uint160(address(control)), 20)
        );
        assertEq(vm.parseJsonString(json, ".properties.original_nft_token_id"), "1");
        assertEq(
            vm.parseJsonString(json, ".properties.manifest_hash"),
            Strings.toHexString(uint256(escrow.getBundle(id).manifestHash), 32)
        );
        string memory chain = vm.toString(block.chainid);
        assertEq(
            vm.parseJsonString(json, ".properties.original_asset"),
            string.concat("eip155:", chain, "/erc721:", Strings.toHexString(uint160(address(control)), 20), "/1")
        );
        assertEq(
            vm.parseJsonString(json, ".properties.bundle_asset"),
            string.concat("eip155:", chain, "/erc721:", Strings.toHexString(uint160(address(receipt)), 20), "/1")
        );
        assertEq(vm.parseJsonString(json, ".attributes[1].value"), "1");
        assertEq(vm.parseJsonString(json, ".attributes[3].value"), "1");
        vm.expectRevert();
        receipt.tokenURI(id + 1);
    }

    function test_DepositRequiresLiveFreshPolicyAndValidManifest() public {
        escrow.setFreshAccountPolicy(address(0), address(0), address(0), false);
        vm.prank(seller);
        vm.expectRevert(NewTradeEscrowV2.FreshAccountUnavailable.selector);
        escrow.deposit(address(control), 1, manifest(), deadline);
        escrow.setFreshAccountPolicy(address(registry), address(accountProxy), address(implementation), true);
        ManifestEntry[] memory bad = manifest();
        bad[1] = bad[0];
        vm.prank(seller);
        vm.expectRevert();
        escrow.deposit(address(control), 1, bad, deadline);
        assertEq(control.ownerOf(1), seller);
        assertEq(custody.erc20Liability(address(erc20)), 0);
    }

    function test_SellerOnlyExactRestrictedListingAndCompleteReconstruction() public {
        uint256 id = deposit();
        Payout[] memory ps = payouts();
        vm.prank(buyer);
        vm.expectRevert(NewTradeEscrowV2.Unauthorized.selector);
        escrow.list(id, address(erc20), PRICE, deadline, 0, ps);
        (bytes32 hash, OrderParameters memory preview) = list(id);
        vm.prank(seller);
        vm.expectRevert(NewTradeEscrowV2.InvalidState.selector);
        escrow.list(id, address(erc20), PRICE, deadline, 0, ps);
        // list() now approves the conduit: that is the operator Seaport uses.
        assertEq(receipt.getApproved(id), CONDUIT);
        assertEq(preview.offerer, address(escrow));
        assertEq(preview.zone, SEAPORT);
        assertEq(uint8(preview.orderType), uint8(OrderType.FULL_RESTRICTED));
        // A new listing carries a REAL recent start time - the OpenSea API
        // rejects 1970 - and it is fixed in storage at list() rather than
        // re-derived, so getOrder() still reconstructs the same hash later.
        assertEq(preview.startTime, uint64(block.timestamp));
        // The legacy placeholder start time was the literal 1 (constant since removed).
        assertTrue(preview.startTime != 1);
        assertEq(preview.endTime, deadline);
        assertEq(preview.zoneHash, bytes32(0));
        // The order is routed through the OpenSea conduit: this is the field
        // that makes the conduit, not Seaport, the operator the receipt sees.
        assertEq(preview.conduitKey, escrow.OPENSEA_CONDUIT_KEY());
        assertEq(preview.totalOriginalConsiderationItems, ps.length);
        assertEq(preview.offer.length, 1);
        assertEq(preview.offer[0].token, address(receipt));
        assertEq(preview.offer[0].identifierOrCriteria, id);
        assertEq(preview.offer[0].startAmount, 1);
        (
            OrderParameters memory stored,
            uint256 historicalCounter,
            bytes32 storedHash,
            uint256 chainId,
            address protocol
        ) = escrow.getOrder(id);
        assertEq(keccak256(abi.encode(preview)), keccak256(abi.encode(stored)));
        assertEq(historicalCounter, 42);
        assertEq(storedHash, hash);
        assertEq(chainId, block.chainid);
        assertEq(protocol, SEAPORT);
        SeaportV2Mock(SEAPORT).setCounter(99);
        vm.chainId(999);
        (OrderParameters memory reconstructed, uint256 stillHistorical,, uint256 listedChain,) = escrow.getOrder(id);
        assertEq(keccak256(abi.encode(reconstructed)), keccak256(abi.encode(stored)));
        assertEq(stillHistorical, 42);
        assertTrue(listedChain != block.chainid);
        OrderComponents memory c = components(stored, historicalCounter);
        assertEq(ISeaport(SEAPORT).getOrderHash(c), storedHash);
    }

    function test_ListingTamperingAndActualRetiredSelectorsReject() public {
        uint256 id = deposit();
        Payout[] memory ps = payouts();
        vm.prank(seller);
        vm.expectRevert(NewTradeEscrowV2.InvalidOrder.selector);
        escrow.list(id, address(erc20), PRICE, deadline + 1, 0, ps);
        ps[0].amount -= 1;
        vm.prank(seller);
        vm.expectRevert(NewTradeEscrowV2.InvalidConsideration.selector);
        escrow.list(id, address(erc20), PRICE, deadline, 0, ps);
        ps = payouts();
        vm.prank(seller);
        vm.expectRevert(NewTradeEscrowV2.InvalidOrder.selector);
        escrow.list(id, address(0xBAD), PRICE, deadline, 0, ps);
        vm.prank(seller);
        vm.expectRevert(NewTradeEscrowV2.InvalidConsideration.selector);
        escrow.list(id, address(erc20), PRICE, deadline, 10_001, ps);
        RetiredSaleAuthorizationV2 memory oldAuth = RetiredSaleAuthorizationV2(
            seller,
            id,
            id,
            escrow.getBundle(id).manifestHash,
            deadline,
            address(erc20),
            PRICE,
            keccak256("retired-nonce"),
            bytes32(0),
            bytes32(0),
            0
        );
        RetiredSellerRecipient[] memory oldRecipients = new RetiredSellerRecipient[](1);
        oldRecipients[0] = RetiredSellerRecipient(payable(seller), 10_000);
        bytes4 oldList = bytes4(
            keccak256(
                "list(uint256,(address,uint256,uint256,bytes32,uint64,address,uint256,bytes32,bytes32,bytes32,uint16),(address,uint16)[],bytes)"
            )
        );
        (bool ok,) = address(escrow).call(abi.encodeWithSelector(oldList, id, oldAuth, oldRecipients, bytes("sig")));
        assertFalse(ok);
        bytes4 oldDigest = bytes4(
            keccak256(
                "saleAuthorizationDigest((address,uint256,uint256,bytes32,uint64,address,uint256,bytes32,bytes32,bytes32,uint16))"
            )
        );
        (ok,) = address(escrow).staticcall(abi.encodeWithSelector(oldDigest, oldAuth));
        assertFalse(ok);
        (ok,) = address(escrow).staticcall(abi.encodeWithSignature("saleZone()"));
        assertFalse(ok);
        (ok,) = address(escrow).call(
            abi.encodeWithSignature(
                "beforeReceiptTransfer(address,address,address,uint256)", SEAPORT, address(escrow), buyer, id
            )
        );
        assertFalse(ok);
        (ok,) = address(escrow).call(abi.encodeWithSignature("armSettlement(uint256,address)", id, buyer));
        assertFalse(ok);
        (ok,) = address(escrow).call(abi.encodeWithSignature("commitSettlement(uint256,address)", id, buyer));
        assertFalse(ok);
        (ok,) = address(escrow).call(abi.encodeWithSignature("redeem(uint256)", id));
        assertFalse(ok);
    }

    function test_ValidationFailureRollsBackListingAndApproval() public {
        uint256 id = deposit();
        SeaportV2Mock(SEAPORT).setRejectValidation(true);
        vm.prank(seller);
        vm.expectRevert(NewTradeEscrowV2.InvalidOrder.selector);
        escrow.list(id, address(erc20), PRICE, deadline, 0, payouts());
        assertEq(uint8(escrow.getBundle(id).state), uint8(BundleState.Deposited));
        assertEq(receipt.getApproved(id), address(0));
        assertEq(escrow.getPayouts(id).length, 0);
    }

    function test_ArbitraryCallerCannotPrevalidateEscrowOrder() public {
        uint256 id = deposit();
        Payout[] memory ps = payouts();
        OrderParameters memory p = escrow.previewOrderParameters(id, address(erc20), PRICE, deadline, 0, ps, uint64(block.timestamp));
        Order[] memory orders = new Order[](1);
        orders[0] = Order(p, "");
        vm.prank(buyer);
        vm.expectRevert("OFFERER_ONLY");
        ISeaport(SEAPORT).validate(orders);
        assertEq(receipt.getApproved(id), address(0));
        vm.prank(seller);
        escrow.list(id, address(erc20), PRICE, deadline, 0, ps);
    }

    function test_FirstExitIsAuthenticatedAndFailedSettlementRollsBack() public {
        uint256 id = deposit();
        vm.prank(address(escrow));
        vm.expectRevert();
        receipt.transferFrom(address(escrow), buyer, id);
        (, OrderParameters memory p) = list(id);
        vm.expectRevert("PAYMENT_FAILED");
        SeaportV2Mock(SEAPORT).fillAndRevert(p, buyer);
        assertEq(receipt.ownerOf(id), address(escrow));
        assertFalse(escrow.getBundle(id).everIssued);
        // The seller credit written by the callback must roll back with
        // everything else: a failed settlement must not leave a withdrawable
        // balance behind for a sale that never happened.
        assertEq(escrow.claimable(seller, address(erc20)), 0);
        SeaportV2Mock(SEAPORT).fill(p, buyer);
        // ...and a settlement that DID happen credits the escrow's consideration
        // item LESS the protocol fee frozen at list() (0.025 at 250 bps): the fee
        // stays in the escrow as surplus (escrow-fee-from-proceeds-sep25).
        assertEq(escrow.claimable(seller, address(erc20)), payouts()[0].amount - 0.025 ether);
        assertEq(escrow.totalOwed(address(erc20)), payouts()[0].amount - 0.025 ether);
        Bundle memory b = escrow.getBundle(id);
        assertEq(uint8(b.state), uint8(BundleState.Issued));
        assertTrue(b.everIssued);
        assertEq(b.firstRecipient, buyer);
        assertEq(receipt.ownerOf(id), buyer);
    }

    /// RE-ANCHORED (bundle-non-transferable-sep26): the claim can no longer go
    /// back to the escrow after its first exit, so a "second exit" cannot
    /// happen at all; the one-shot notification and the issued record stand.
    function test_FirstExitCallbackRunsExactlyOnceEvenAfterReceiptReturnsToController() public {
        uint256 id = deposit();
        issue(id, buyer);
        Bundle memory issued = escrow.getBundle(id);
        assertTrue(receipt.firstExitNotified(id));

        vm.prank(buyer);
        receipt.approve(CONDUIT, id);
        vm.expectRevert(NewTradeBundle.NonTransferable.selector);
        SeaportV2Mock(SEAPORT).transferReceipt(address(receipt), buyer, address(escrow), id);

        Bundle memory afterAttempt = escrow.getBundle(id);
        assertEq(uint8(afterAttempt.state), uint8(BundleState.Issued));
        assertTrue(afterAttempt.everIssued);
        assertEq(afterAttempt.firstRecipient, issued.firstRecipient);
        assertEq(afterAttempt.issuedAt, issued.issuedAt);
        assertEq(receipt.ownerOf(id), buyer);
    }

    function test_ExactDeadlineCannotFillMockSeaportOrder() public {
        uint256 id = deposit();
        (, OrderParameters memory p) = list(id);
        vm.warp(deadline);
        vm.expectRevert("EXPIRED");
        SeaportV2Mock(SEAPORT).fill(p, buyer);
        assertEq(receipt.ownerOf(id), address(escrow));
        assertFalse(receipt.firstExitNotified(id));
        assertFalse(escrow.getBundle(id).everIssued);
    }

    /// RE-ANCHORED (bundle-non-transferable-sep26): the claim no longer moves
    /// after its first sale - not directly, not through the validator-approved
    /// conduit, not through a marketplace - and the refusal comes before the
    /// validator is asked. What this test always pinned still holds: only the
    /// CURRENT holder redeems (an approval does not), and the fresh account
    /// follows the control NFT's owner.
    function test_OnlyAuthorizedMarketplaceTransferAndCurrentHolderRedeems() public {
        uint256 id = deposit();
        issue(id, buyer);
        vm.prank(buyer);
        vm.expectRevert(NewTradeBundle.NonTransferable.selector);
        receipt.transferFrom(buyer, holderB, id);
        vm.prank(buyer);
        receipt.approve(CONDUIT, id);
        vm.expectRevert(NewTradeBundle.NonTransferable.selector);
        SeaportV2Mock(SEAPORT).transferReceipt(address(receipt), buyer, holderB, id);
        SecondaryMarketplace market = new SecondaryMarketplace();
        vm.prank(buyer);
        receipt.approve(address(market), id);
        vm.expectRevert(NewTradeBundle.NonTransferable.selector);
        market.transfer(receipt, buyer, holderC, id);
        assertEq(receipt.ownerOf(id), buyer);
        vm.prank(holderB);
        vm.expectRevert(NewTradeEscrowV2.Unauthorized.selector);
        escrow.redeemToFreshAccount(id, keccak256("stranger"));
        // Approvals may still be granted; they neither move the claim nor redeem it.
        vm.prank(buyer);
        receipt.approve(holderC, id);
        vm.prank(holderC);
        vm.expectRevert(NewTradeEscrowV2.Unauthorized.selector);
        escrow.redeemToFreshAccount(id, keccak256("approved-only"));
        vm.prank(buyer);
        address account = escrow.redeemToFreshAccount(id, keccak256("holder"));
        assertEq(control.ownerOf(1), buyer);
        assertEq(extra721.ownerOf(7), account);
        assertEq(erc20.balanceOf(account), 20 ether);
        assertEq(erc1155.balanceOf(account, 3), 4);
        assertEq(custody.accountOwner(account), buyer);
        address newOwner = address(0xD00D);
        vm.prank(buyer);
        control.transferFrom(buyer, newOwner, 1);
        bytes memory spend = abi.encodeCall(erc20.transfer, (treasury, 1 ether));
        vm.prank(buyer);
        vm.expectRevert(bytes("AUTH"));
        IERC6551ExecutableAccount(account).execute(address(erc20), 0, spend, 0);
        vm.prank(holderB);
        vm.expectRevert(bytes("AUTH"));
        IERC6551ExecutableAccount(account).execute(address(erc20), 0, spend, 0);
        vm.prank(newOwner);
        IERC6551ExecutableAccount(account).execute(address(erc20), 0, spend, 0);
        assertEq(custody.accountOwner(account), newOwner);
    }

    function test_PolicyChangeCannotRedirectFundedBundleAndPredeploymentAllowsSaltRetry() public {
        uint256 id = deposit();
        issue(id, buyer);
        Mock6551Registry otherRegistry = new Mock6551Registry();
        Mock6551Implementation otherImplementation = new Mock6551Implementation();
        MockTokenboundAccountProxy otherProxy = new MockTokenboundAccountProxy(address(otherImplementation));
        escrow.setTrustedAccountCode(address(otherRegistry), true, true);
        escrow.setTrustedAccountCode(address(otherProxy), false, true);
        escrow.setTrustedAccountCode(address(otherImplementation), false, true);
        escrow.setFreshAccountPolicy(address(otherRegistry), address(otherProxy), address(otherImplementation), true);
        bytes32 blockedSalt = keccak256("blocked");
        (address predicted, bytes32 fullSalt) = escrow.computeFreshAccount(id, buyer, blockedSalt);
        assertEq(predicted, registry.account(address(accountProxy), fullSalt, block.chainid, address(control), 1));
        registry.createAccount(address(accountProxy), fullSalt, block.chainid, address(control), 1);
        vm.prank(buyer);
        vm.expectRevert();
        escrow.redeemToFreshAccount(id, blockedSalt);
        assertEq(receipt.ownerOf(id), buyer);
        assertEq(control.ownerOf(1), address(custody));
        vm.prank(buyer);
        address account = escrow.redeemToFreshAccount(id, keccak256("retry"));
        assertTrue(account != predicted);
        assertEq(custody.accountOwner(account), buyer);
    }

    function test_WrongAccountOwnerAndRejectingNftReceiverRollbackAtomically() public {
        Mock6551WrongOwnerImplementation wrong = new Mock6551WrongOwnerImplementation(address(0xDEAD));
        MockTokenboundAccountProxy wrongProxy = new MockTokenboundAccountProxy(address(wrong));
        vm.expectRevert(NewTradeEscrowV2.FreshAccountUnavailable.selector);
        escrow.setFreshAccountPolicy(address(registry), address(wrongProxy), address(wrong), true);
        escrow.setTrustedAccountCode(address(wrongProxy), false, true);
        escrow.setTrustedAccountCode(address(wrong), false, true);
        escrow.setFreshAccountPolicy(address(registry), address(wrongProxy), address(wrong), true);
        uint256 id = deposit();
        issue(id, buyer);
        // partial-release-oct20 (design 4): the account check runs inside the NFT
        // attempt. A wrong owner keeps the NFT and every entry held; the redemption
        // is Redeeming and the claim is burned. Retries by anyone fail the same way;
        // the redeemer's redirect (D2-B) is the way out.
        vm.prank(buyer);
        escrow.redeemToFreshAccount(id, keccak256("wrong-owner"));
        _assertPartialNftHeld(id, 3);
        vm.prank(holderC);
        escrow.withdrawRemaining(id, (uint256(1) << 32) | 7, "");
        _assertPartialNftHeld(id, 3);
        assertEq(custody.erc20Liability(address(erc20)), 20 ether);

        // RE-ANCHORED (bundle-non-transferable-sep26): the rejecting holder is the buyer of the first sale.
        setUp();
        id = deposit();
        RejectingReceiptHolder rejecting = new RejectingReceiptHolder();
        issue(id, address(rejecting));
        // partial-release-oct20: the NFT attempt fails (the holder rejects it); the
        // NFT and the entries stay held, nothing is lost, the claim is burned.
        rejecting.redeem(escrow, id, keccak256("reject-nft"));
        _assertPartialNftHeld(id, 3);
        assertEq(custody.erc20Liability(address(erc20)), 20 ether);
    }

    /// RE-ANCHORED (bundle-non-transferable-sep26): a self-bound account can no
    /// longer hold the claim at all. Before, it got there by a secondary
    /// transfer; now the first exit refuses it (the escrow's own recipient
    /// check) and a transfer to it reverts NonTransferable. Both doors, pinned.
    function test_SelfBoundCurrentHolderCannotRedeem() public {
        uint256 id = deposit();
        address bound =
            registry.createAccount(address(implementation), keccak256("self-bound"), block.chainid, address(control), 1);
        (, OrderParameters memory p) = list(id);
        vm.expectRevert(NewTradeEscrowV2.InvalidRecipient.selector);
        SeaportV2Mock(SEAPORT).fill(p, bound);
        SeaportV2Mock(SEAPORT).fill(p, buyer);
        vm.prank(buyer);
        receipt.approve(CONDUIT, id);
        vm.expectRevert(NewTradeBundle.NonTransferable.selector);
        SeaportV2Mock(SEAPORT).transferReceipt(address(receipt), buyer, bound, id);
        assertEq(receipt.ownerOf(id), buyer);
        assertEq(control.ownerOf(1), address(custody));
    }

    function test_SelfBoundPrimaryRecipientRejectsAtomically() public {
        uint256 id = deposit();
        (, OrderParameters memory p) = list(id);
        address bound = registry.createAccount(
            address(implementation), keccak256("self-bound-primary"), block.chainid, address(control), 1
        );
        vm.expectRevert(NewTradeEscrowV2.InvalidRecipient.selector);
        SeaportV2Mock(SEAPORT).fill(p, bound);
        assertEq(receipt.ownerOf(id), address(escrow));
        assertFalse(receipt.firstExitNotified(id));
        assertFalse(escrow.getBundle(id).everIssued);
        assertEq(control.ownerOf(1), address(custody));
        assertEq(custody.erc20Liability(address(erc20)), 20 ether);
    }

    /// RE-ANCHORED (bundle-non-transferable-sep26): the spoofing account can no
    /// longer receive the claim (the first exit refuses it; a transfer reverts
    /// NonTransferable). The fail-open token probe still holds for a holder that
    /// receives it as the buyer of the first sale.
    function test_SelfBoundSpoofRejectsButRevertingTokenProbeIsExplicitlyFailOpen() public {
        uint256 id = deposit();
        Mock6551SpoofAccount spoof = new Mock6551SpoofAccount(block.chainid, address(control), 1, buyer);
        (, OrderParameters memory p) = list(id);
        vm.expectRevert(NewTradeEscrowV2.InvalidRecipient.selector);
        SeaportV2Mock(SEAPORT).fill(p, address(spoof));
        SeaportV2Mock(SEAPORT).fill(p, buyer);
        vm.prank(buyer);
        receipt.approve(CONDUIT, id);
        vm.expectRevert(NewTradeBundle.NonTransferable.selector);
        SeaportV2Mock(SEAPORT).transferReceipt(address(receipt), buyer, address(spoof), id);
        // Nothing moved: still the buyer's, still Issued, the NFT still in custody
        // (the conduit approval the attempt granted stays; it cannot execute).
        assertEq(receipt.ownerOf(id), buyer);
        assertEq(uint8(escrow.getBundle(id).state), uint8(BundleState.Issued));
        assertTrue(escrow.getBundle(id).everIssued);
        assertEq(control.ownerOf(1), address(custody));

        setUp();
        id = deposit();
        Mock6551RevertingTokenHolder revertingHolder = new Mock6551RevertingTokenHolder();
        issue(id, address(revertingHolder));
        vm.prank(address(revertingHolder));
        address account = escrow.redeemToFreshAccount(id, keccak256("fail-open-token-probe"));
        assertEq(control.ownerOf(1), address(revertingHolder));
        assertEq(custody.accountOwner(account), address(revertingHolder));
    }

    function test_UntrustedAccountPolicyCannotAcceptArbitraryLiveCode() public {
        Mock6551Registry otherRegistry = new Mock6551Registry();
        Mock6551Implementation otherImplementation = new Mock6551Implementation();
        MockTokenboundAccountProxy otherProxy = new MockTokenboundAccountProxy(address(otherImplementation));
        vm.expectRevert(NewTradeEscrowV2.FreshAccountUnavailable.selector);
        escrow.setFreshAccountPolicy(address(otherRegistry), address(otherProxy), address(otherImplementation), true);
        escrow.setTrustedAccountCode(address(otherRegistry), true, true);
        vm.expectRevert(NewTradeEscrowV2.FreshAccountUnavailable.selector);
        escrow.setFreshAccountPolicy(address(otherRegistry), address(otherProxy), address(otherImplementation), true);
        escrow.setTrustedAccountCode(address(otherProxy), false, true);
        vm.expectRevert(NewTradeEscrowV2.FreshAccountUnavailable.selector);
        escrow.setFreshAccountPolicy(address(otherRegistry), address(otherProxy), address(otherImplementation), true);
        escrow.setTrustedAccountCode(address(otherImplementation), false, true);
        escrow.setFreshAccountPolicy(address(otherRegistry), address(otherProxy), address(otherImplementation), true);
        assertTrue(escrow.trustedAccountCode(address(otherRegistry), true));
        assertTrue(escrow.trustedAccountCode(address(otherImplementation), false));
    }

    function test_DivergentRegistryWrongTupleAndInvalidSignerRollback() public {
        Mock6551SpoofAccount spoof = new Mock6551SpoofAccount(block.chainid, address(control), 1, buyer);
        Mock6551DivergentRegistry divergent = new Mock6551DivergentRegistry(address(0x123456789), address(spoof));
        escrow.setTrustedAccountCode(address(divergent), true, true);
        escrow.setFreshAccountPolicy(address(divergent), address(accountProxy), address(implementation), true);
        uint256 id = deposit();
        issue(id, buyer);
        vm.prank(buyer);
        vm.expectRevert();
        escrow.redeemToFreshAccount(id, keccak256("divergent"));
        _assertIssuedRollback(id, buyer);

        setUp();
        Mock6551WrongTupleRegistry wrongTuple = new Mock6551WrongTupleRegistry();
        escrow.setTrustedAccountCode(address(wrongTuple), true, true);
        escrow.setFreshAccountPolicy(address(wrongTuple), address(accountProxy), address(implementation), true);
        id = deposit();
        issue(id, buyer);
        vm.prank(buyer);
        vm.expectRevert();
        escrow.redeemToFreshAccount(id, keccak256("wrong-tuple"));
        _assertIssuedRollback(id, buyer);

        setUp();
        Mock6551InvalidSignerImplementation invalidSigner = new Mock6551InvalidSignerImplementation();
        MockTokenboundAccountProxy invalidSignerProxy = new MockTokenboundAccountProxy(address(invalidSigner));
        escrow.setTrustedAccountCode(address(invalidSignerProxy), false, true);
        escrow.setTrustedAccountCode(address(invalidSigner), false, true);
        escrow.setFreshAccountPolicy(address(registry), address(invalidSignerProxy), address(invalidSigner), true);
        id = deposit();
        issue(id, buyer);
        // partial-release-oct20 (design 4): the signer check is inside the NFT
        // attempt, so the redemption stays Redeeming with everything held.
        vm.prank(buyer);
        escrow.redeemToFreshAccount(id, keccak256("invalid-signer"));
        _assertPartialNftHeld(id, 3);

        setUp();
        Mock6551RevertingOwnerImplementation revoked = new Mock6551RevertingOwnerImplementation();
        MockTokenboundAccountProxy revokedProxy = new MockTokenboundAccountProxy(address(revoked));
        escrow.setTrustedAccountCode(address(revokedProxy), false, true);
        escrow.setTrustedAccountCode(address(revoked), false, true);
        escrow.setFreshAccountPolicy(address(registry), address(revokedProxy), address(revoked), true);
        id = deposit();
        issue(id, buyer);
        // partial-release-oct20: a reverting owner() fails the NFT attempt only.
        vm.prank(buyer);
        escrow.redeemToFreshAccount(id, keccak256("revoked-owner"));
        _assertPartialNftHeld(id, 3);
    }

    /// partial-release-oct20 (F-01): was "...RollsBackEverything". A manifest entry
    /// that will not move no longer undoes the redemption: the NFT leaves, the bad
    /// entry stays held with its liability, the bundle is Redeeming, and anyone's
    /// retry closes it once the token works.
    function test_ERC20ReleaseFailureAfterBurnLeavesEntryHeldAndRetryCloses() public {
        ToggleReleaseFailureERC20 token = new ToggleReleaseFailureERC20();
        escrow.setAssetKind(address(token), AssetKind.ERC20, true);
        token.mint(seller, 9 ether);
        vm.prank(seller);
        token.approve(address(custody), type(uint256).max);
        ManifestEntry[] memory es = new ManifestEntry[](1);
        es[0] = ManifestEntry(AssetKind.ERC20, address(token), 0, 9 ether);
        vm.prank(seller);
        uint256 id = escrow.deposit(address(control), 1, es, deadline);
        issue(id, buyer);
        token.setFailRelease(true);
        vm.prank(buyer);
        address account = escrow.redeemToFreshAccount(id, keccak256("fail20"));
        _assertPartialAfterNft(id, buyer, 1);
        assertEq(token.balanceOf(address(custody)), 9 ether);
        assertEq(custody.erc20Liability(address(token)), 9 ether);
        _retryWhileFailingChangesNothing(id, 1);
        assertEq(token.balanceOf(account), 0);
        token.setFailRelease(false);
        vm.prank(holderC);
        escrow.withdrawRemaining(id, 1, "");
        assertEq(uint8(escrow.getBundle(id).state), uint8(BundleState.Redeemed));
        assertEq(token.balanceOf(account), 9 ether);
        assertEq(token.balanceOf(address(custody)), 0);
        assertEq(custody.erc20Liability(address(token)), 0);
    }

    /// partial-release-oct20 (F-01): see the ERC-20 case.
    function test_ERC721ReleaseFailureAfterBurnLeavesEntryHeldAndRetryCloses() public {
        ToggleReleaseFailureERC721 token = new ToggleReleaseFailureERC721();
        escrow.setAssetKind(address(token), AssetKind.ERC721, true);
        token.mint(seller, 9);
        vm.prank(seller);
        token.setApprovalForAll(address(custody), true);
        ManifestEntry[] memory es = new ManifestEntry[](1);
        es[0] = ManifestEntry(AssetKind.ERC721, address(token), 9, 1);
        vm.prank(seller);
        uint256 id = escrow.deposit(address(control), 1, es, deadline);
        issue(id, buyer);
        token.setFailRelease(true);
        vm.prank(buyer);
        address account = escrow.redeemToFreshAccount(id, keccak256("fail721"));
        _assertPartialAfterNft(id, buyer, 1);
        assertEq(token.ownerOf(9), address(custody));
        assertTrue(custody.erc721Reserved(address(token), 9));
        _retryWhileFailingChangesNothing(id, 1);
        token.setFailRelease(false);
        vm.prank(holderC);
        escrow.withdrawRemaining(id, 1, "");
        assertEq(uint8(escrow.getBundle(id).state), uint8(BundleState.Redeemed));
        assertEq(token.ownerOf(9), account);
        assertFalse(custody.erc721Reserved(address(token), 9));
    }

    /// partial-release-oct20 (F-01): see the ERC-20 case.
    function test_ERC1155ReleaseFailureAfterBurnLeavesEntryHeldAndRetryCloses() public {
        ToggleReleaseFailureERC1155 token = new ToggleReleaseFailureERC1155();
        escrow.setAssetKind(address(token), AssetKind.ERC1155, true);
        token.mint(seller, 9, 7);
        vm.prank(seller);
        token.setApprovalForAll(address(custody), true);
        ManifestEntry[] memory es = new ManifestEntry[](1);
        es[0] = ManifestEntry(AssetKind.ERC1155, address(token), 9, 7);
        vm.prank(seller);
        uint256 id = escrow.deposit(address(control), 1, es, deadline);
        issue(id, buyer);
        token.setFailRelease(true);
        vm.prank(buyer);
        address account = escrow.redeemToFreshAccount(id, keccak256("fail1155"));
        _assertPartialAfterNft(id, buyer, 1);
        assertEq(token.balanceOf(address(custody), 9), 7);
        assertEq(custody.erc1155Liability(address(token), 9), 7);
        _retryWhileFailingChangesNothing(id, 1);
        token.setFailRelease(false);
        vm.prank(holderC);
        escrow.withdrawRemaining(id, 1, "");
        assertEq(uint8(escrow.getBundle(id).state), uint8(BundleState.Redeemed));
        assertEq(token.balanceOf(account, 9), 7);
        assertEq(custody.erc1155Liability(address(token), 9), 0);
    }

    function _assertIssuedRollback(uint256 id, address owner) internal view {
        assertEq(receipt.ownerOf(id), owner);
        assertEq(receipt.getApproved(id), address(0));
        Bundle memory b = escrow.getBundle(id);
        assertEq(uint8(b.state), uint8(BundleState.Issued));
        assertTrue(b.everIssued);
        assertEq(control.ownerOf(1), address(custody));
    }

    /// partial-release-oct20: the redemption went through for the controlling NFT
    /// (now with `nftOwner`) and stopped at the manifest entries in `heldMask`. The
    /// claim is burned and the bundle is Redeeming.
    function _assertPartialAfterNft(uint256 id, address nftOwner, uint256 heldMask) internal {
        Bundle memory b = escrow.getBundle(id);
        assertEq(uint8(b.state), uint8(BundleState.Redeeming));
        assertTrue(b.everIssued);
        assertEq(control.ownerOf(1), nftOwner);
        vm.expectRevert();
        receipt.ownerOf(id);
        (,, uint256 held) = custody.bundleStatus(id);
        assertEq(held, heldMask);
    }

    /// partial-release-oct20: the controlling NFT did not leave on a redemption; it
    /// and every manifest entry are still held (the entries wait for the NFT, design 4).
    function _assertPartialNftHeld(uint256 id, uint256 entries) internal {
        Bundle memory b = escrow.getBundle(id);
        assertEq(uint8(b.state), uint8(BundleState.Redeeming));
        assertEq(control.ownerOf(1), address(custody));
        vm.expectRevert();
        receipt.ownerOf(id);
        (,, uint256 held) = custody.bundleStatus(id);
        assertEq(held, (uint256(1) << 32) | ((uint256(1) << entries) - 1));
    }

    /// A ONE-entry retry by a stranger while the token still fails reverts (single
    /// mode: a failed attempt reverts the whole call) and changes nothing.
    function _retryWhileFailingChangesNothing(uint256 id, uint256 heldMask) internal {
        vm.prank(holderC);
        vm.expectRevert(NewTradeV2VaultV2.ReleaseFailed.selector);
        escrow.withdrawRemaining(id, heldMask, "");
        assertEq(uint8(escrow.getBundle(id).state), uint8(BundleState.Redeeming));
        (,, uint256 held) = custody.bundleStatus(id);
        assertEq(held, heldMask);
    }

    /// RE-ANCHORED (bundle-non-transferable-sep26): a holder can no longer
    /// safe-transfer the claim to a contract that redeems in its callback; the
    /// transfer reverts before any callback and nothing moves.
    function test_SafeTransferCallbackCanAtomicallyRedeem() public {
        uint256 id = deposit();
        issue(id, buyer);
        RedeemingReceiptReceiver receiver = new RedeemingReceiptReceiver(escrow, receipt, keccak256("callback"));
        vm.prank(buyer);
        receipt.approve(CONDUIT, id);
        vm.expectRevert(NewTradeBundle.NonTransferable.selector);
        SeaportV2Mock(SEAPORT).safeTransferReceipt(address(receipt), buyer, address(receiver), id);
        assertEq(receipt.ownerOf(id), buyer);
        assertEq(control.ownerOf(1), address(custody));
        assertEq(receiver.account(), address(0));
    }

    /// RE-ANCHORED (bundle-non-transferable-sep26): an issued claim can no
    /// longer be returned to the escrow at all; the seller's reclaim rights stay
    /// gone whatever is attempted.
    function test_ReclaimBoundaryAndIssuedReturnNeverRestoresSellerRights() public {
        uint256 id = deposit();
        vm.warp(deadline - 1);
        vm.prank(seller);
        vm.expectRevert(NewTradeEscrowV2.Unauthorized.selector);
        escrow.reclaim(id, seller);
        vm.warp(deadline);
        vm.prank(seller);
        escrow.reclaim(id, seller);
        assertEq(control.ownerOf(1), seller);
        assertEq(erc20.balanceOf(seller), 100 ether);
        vm.expectRevert();
        receipt.ownerOf(id);

        setUp();
        id = deposit();
        issue(id, buyer);
        vm.prank(buyer);
        receipt.approve(CONDUIT, id);
        vm.expectRevert(NewTradeBundle.NonTransferable.selector);
        SeaportV2Mock(SEAPORT).transferReceipt(address(receipt), buyer, address(escrow), id);
        vm.warp(deadline);
        vm.prank(seller);
        vm.expectRevert(NewTradeEscrowV2.Unauthorized.selector);
        escrow.reclaim(id, seller);
        assertTrue(escrow.getBundle(id).everIssued);
        assertEq(receipt.ownerOf(id), buyer);
    }

    function test_IssuedClaimRedeemsAfterListingExpiryAndCannotDoubleExit() public {
        uint256 id = deposit();
        issue(id, buyer);
        vm.warp(deadline + 30 days);
        vm.prank(buyer);
        escrow.redeemToFreshAccount(id, keccak256("late"));
        vm.prank(buyer);
        vm.expectRevert();
        escrow.redeemToFreshAccount(id, keccak256("again"));
        vm.prank(seller);
        vm.expectRevert();
        escrow.reclaim(id, seller);
        assertEq(custody.erc20Liability(address(erc20)), 0);
        assertEq(custody.erc1155Liability(address(erc1155), 3), 0);
    }

    function test_AllTwentySevenModeCombinationsAndPaymentPolicyIndependence() public {
        MockERC20 unlisted20 = new MockERC20("Unlisted", "U20", 18);
        MockERC721 unlisted721 = new MockERC721();
        MockERC1155 unlisted1155 = new MockERC1155();

        for (uint256 combination; combination < 27; ++combination) {
            AcceptanceMode mode20 = AcceptanceMode(combination % 3);
            AcceptanceMode mode721 = AcceptanceMode((combination / 3) % 3);
            AcceptanceMode mode1155 = AcceptanceMode((combination / 9) % 3);
            escrow.setAssetAcceptanceMode(AssetKind.ERC20, mode20);
            escrow.setAssetAcceptanceMode(AssetKind.ERC721, mode721);
            escrow.setAssetAcceptanceMode(AssetKind.ERC1155, mode1155);

            assertEq(custody.isAllowed(address(erc20), AssetKind.ERC20), mode20 != AcceptanceMode.Disabled);
            assertEq(custody.isAllowed(address(unlisted20), AssetKind.ERC20), mode20 == AcceptanceMode.Wildcard);
            assertEq(custody.isAllowed(address(control), AssetKind.ERC721), mode721 != AcceptanceMode.Disabled);
            assertEq(custody.isAllowed(address(unlisted721), AssetKind.ERC721), mode721 == AcceptanceMode.Wildcard);
            assertEq(custody.isAllowed(address(erc1155), AssetKind.ERC1155), mode1155 != AcceptanceMode.Disabled);
            assertEq(custody.isAllowed(address(unlisted1155), AssetKind.ERC1155), mode1155 == AcceptanceMode.Wildcard);

            assertTrue(escrow.isPaymentTokenAllowed(address(erc20)));
            assertFalse(escrow.isPaymentTokenAllowed(address(unlisted20)));
        }
    }

    function test_AdminModeAndMembershipEventsRevisionAndAuthorization() public {
        uint256 initial = custody.assetPolicyRevision();
        // partial-release-oct20: the fixture's vault is switched in and its policy
        // replayed through the escrow: revision 1 at initialize, +3 modes, +4 tokens.
        assertEq(initial, 8);
        vm.expectEmit(true, true, true, true, address(escrow));
        emit AssetAcceptanceModeUpdated(AssetKind.ERC20, AcceptanceMode.Allowlist, AcceptanceMode.Wildcard, initial + 1);
        escrow.setAssetAcceptanceMode(AssetKind.ERC20, AcceptanceMode.Wildcard);
        assertEq(custody.assetPolicyRevision(), initial + 1);
        assertEq(uint8(custody.assetAcceptanceMode(AssetKind.ERC20)), uint8(AcceptanceMode.Wildcard));

        MockERC20 token = new MockERC20("Member", "MEM", 18);
        vm.expectEmit(true, true, true, true, address(escrow));
        emit AssetAllowlistMembershipUpdated(address(token), AssetKind.ERC20, true, initial + 2);
        escrow.setAssetKind(address(token), AssetKind.ERC20, true);
        assertTrue(custody.isAssetAllowlisted(address(token), AssetKind.ERC20));
        assertEq(custody.assetPolicyRevision(), initial + 2);

        vm.startPrank(buyer);
        vm.expectRevert();
        escrow.setAssetAcceptanceMode(AssetKind.ERC20, AcceptanceMode.Disabled);
        vm.expectRevert();
        escrow.setAssetKind(address(token), AssetKind.ERC20, false);
        vm.stopPrank();
    }

    function test_WildcardPinsKindsAndRejectsInvalidInternalAndConflictingAssets() public {
        escrow.setAssetAcceptanceMode(AssetKind.ERC20, AcceptanceMode.Wildcard);
        escrow.setAssetAcceptanceMode(AssetKind.ERC721, AcceptanceMode.Wildcard);
        escrow.setAssetAcceptanceMode(AssetKind.ERC1155, AcceptanceMode.Wildcard);
        MockERC20 token20 = new MockERC20("Wildcard", "W20", 18);
        MockERC721 token721 = new MockERC721();
        MockERC721 controller = new MockERC721();
        MockERC1155 token1155 = new MockERC1155();
        controller.mint(seller, 2);
        token721.mint(seller, 8);
        token20.mint(seller, 11 ether);
        token1155.mint(seller, 4, 6);
        vm.startPrank(seller);
        controller.approve(address(custody), 2);
        token721.approve(address(custody), 8);
        token20.approve(address(custody), type(uint256).max);
        token1155.setApprovalForAll(address(custody), true);
        vm.stopPrank();
        ManifestEntry[] memory es = new ManifestEntry[](3);
        es[0] = ManifestEntry(AssetKind.ERC20, address(token20), 0, 11 ether);
        es[1] = ManifestEntry(AssetKind.ERC721, address(token721), 8, 1);
        es[2] = ManifestEntry(AssetKind.ERC1155, address(token1155), 4, 6);
        vm.prank(seller);
        escrow.deposit(address(controller), 2, es, deadline);

        (AssetKind kind20, bool pinned20) = custody.custodyAssetKind(address(token20));
        (AssetKind kind721, bool pinned721) = custody.custodyAssetKind(address(token721));
        (AssetKind kind1155, bool pinned1155) = custody.custodyAssetKind(address(token1155));
        assertTrue(pinned20 && pinned721 && pinned1155);
        assertEq(uint8(kind20), uint8(AssetKind.ERC20));
        assertEq(uint8(kind721), uint8(AssetKind.ERC721));
        assertEq(uint8(kind1155), uint8(AssetKind.ERC1155));

        FalseStandardClaims liar = new FalseStandardClaims();
        assertFalse(custody.isAllowed(address(0), AssetKind.ERC20));
        assertFalse(custody.isAllowed(buyer, AssetKind.ERC721));
        assertFalse(custody.isAllowed(address(custody), AssetKind.ERC1155));
        assertFalse(custody.isAllowed(address(escrow), AssetKind.ERC721));
        assertFalse(custody.isAllowed(address(receipt), AssetKind.ERC721));
        assertFalse(custody.isAllowed(address(liar), AssetKind.ERC20));
        assertFalse(custody.isAllowed(address(liar), AssetKind.ERC721));
        assertFalse(custody.isAllowed(address(liar), AssetKind.ERC1155));
    }

    function test_PolicyTransitionsGateAdmissionAndListingButNeverExistingExitsOrPublishedOrders() public {
        uint256 id = deposit();
        escrow.setAssetAcceptanceMode(AssetKind.ERC20, AcceptanceMode.Disabled);
        vm.prank(seller);
        vm.expectRevert(NewTradeV2Vault.UnsupportedAsset.selector);
        escrow.list(id, address(erc20), PRICE, deadline, 0, payouts());
        vm.warp(deadline);
        vm.prank(seller);
        escrow.reclaim(id, seller);
        assertEq(control.ownerOf(1), seller);

        setUp();
        id = deposit();
        (, OrderParameters memory order) = list(id);
        escrow.setAssetAcceptanceMode(AssetKind.ERC20, AcceptanceMode.Disabled);
        escrow.setAssetAcceptanceMode(AssetKind.ERC721, AcceptanceMode.Disabled);
        escrow.setAssetAcceptanceMode(AssetKind.ERC1155, AcceptanceMode.Disabled);
        SeaportV2Mock(SEAPORT).fill(order, buyer);
        assertEq(receipt.ownerOf(id), buyer);
        vm.prank(buyer);
        escrow.redeemToFreshAccount(id, keccak256("policy-disabled"));
        assertEq(control.ownerOf(1), buyer);
    }

    function test_ManifestThirtyTwoSucceedsAndThirtyThreeRejects() public {
        ManifestEntry[] memory maxEntries = new ManifestEntry[](32);
        for (uint256 i; i < 32; ++i) {
            erc1155.mint(seller, 100 + i, 1);
            maxEntries[i] = ManifestEntry(AssetKind.ERC1155, address(erc1155), 100 + i, 1);
        }
        vm.prank(seller);
        escrow.deposit(address(control), 1, maxEntries, deadline);

        setUp();
        ManifestEntry[] memory tooMany = new ManifestEntry[](33);
        for (uint256 i; i < 33; ++i) {
            erc1155.mint(seller, 200 + i, 1);
            tooMany[i] = ManifestEntry(AssetKind.ERC1155, address(erc1155), 200 + i, 1);
        }
        vm.prank(seller);
        vm.expectRevert(NewTradeV2Vault.InvalidManifest.selector);
        escrow.deposit(address(control), 1, tooMany, deadline);
        assertEq(control.ownerOf(1), seller);
    }

    function components(OrderParameters memory p, uint256 counter) internal pure returns (OrderComponents memory) {
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

    function _prefix(string memory value, uint256 length) internal pure returns (string memory out) {
        bytes memory input = bytes(value);
        bytes memory result = new bytes(length);
        for (uint256 i; i < length; ++i) {
            result[i] = input[i];
        }
        out = string(result);
    }

    function _suffix(string memory value, uint256 start) internal pure returns (bytes memory out) {
        bytes memory input = bytes(value);
        out = new bytes(input.length - start);
        for (uint256 i; i < out.length; ++i) {
            out[i] = input[start + i];
        }
    }

    function _decodeBase64(bytes memory input) internal pure returns (bytes memory out) {
        require(input.length % 4 == 0, "BASE64_LENGTH");
        uint256 padding = input.length == 0 ? 0 : (input[input.length - 1] == "=" ? 1 : 0);
        if (input.length > 1 && input[input.length - 2] == "=") padding++;
        out = new bytes(input.length / 4 * 3 - padding);
        uint256 cursor;
        for (uint256 i; i < input.length; i += 4) {
            uint256 word = (_base64Value(input[i]) << 18) | (_base64Value(input[i + 1]) << 12)
                | (_base64Value(input[i + 2]) << 6) | _base64Value(input[i + 3]);
            if (cursor < out.length) out[cursor++] = bytes1(uint8(word >> 16));
            if (cursor < out.length) out[cursor++] = bytes1(uint8(word >> 8));
            if (cursor < out.length) out[cursor++] = bytes1(uint8(word));
        }
    }

    function _base64Value(bytes1 c) internal pure returns (uint256) {
        uint8 x = uint8(c);
        if (x >= 65 && x <= 90) return x - 65;
        if (x >= 97 && x <= 122) return x - 71;
        if (x >= 48 && x <= 57) return x + 4;
        if (x == 43) return 62;
        if (x == 47) return 63;
        if (x == 61) return 0;
        revert("BASE64_CHAR");
    }
}
