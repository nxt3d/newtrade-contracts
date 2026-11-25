// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {NewTradeEscrowV2} from "../src/NewTradeEscrowV2.sol";
import {NewTradeBundle} from "../src/NewTradeBundle.sol";
import {NewTradeV2Vault} from "./legacy/NewTradeV2Vault.sol";
import {NewTradeV2VaultV2} from "../src/NewTradeV2VaultV2.sol";
import {VaultV2Deploy, VaultV2Views} from "./helpers/VaultV2Deploy.sol";
import {BundleDeploy} from "./helpers/BundleDeploy.sol";
import {
    AcceptanceMode,
    AssetKind,
    Bundle,
    BundleState,
    ManifestEntry,
    Payout,
    ReleaseMode,
    V2Initialization
} from "../src/NewTradeV2Types.sol";
import {OrderParameters} from "../src/interfaces/ISeaport.sol";
import {IERC6551ExecutableAccount} from "../src/interfaces/IERC6551.sol";
import {MockERC20, MockERC721, MockERC1155} from "./mocks/TokenMocks.sol";
import {SeaportV2Mock} from "./helpers/SeaportV2Mock.sol";
import {ConduitMock} from "./helpers/ConduitMock.sol";
import {Mock6551Account, Mock6551Implementation, Mock6551Registry} from "./helpers/ERC6551Mocks.sol";

/// @dev S2: accepts ERC-721 only from ONE collection and nothing else (no ERC-1155 hook).
/// As an `extrasTo` it rejects the manifest's extra ERC-721, so an honest reclaim reverts.
/// Were the two destinations swapped, it would instead be handed the controlling NFT - the one
/// collection it accepts - and the reclaim would succeed. That asymmetry is what lets the
/// atomicity test double as an inversion catcher.
contract SelectiveReceiver {
    address private immutable ACCEPTED;

    constructor(address acceptedCollection) {
        ACCEPTED = acceptedCollection;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        require(msg.sender == ACCEPTED, "SelectiveReceiver: collection refused");
        return 0x150b7a02;
    }
}

/**
 * Reclaim of a MIGRATED bundle — the extras must go back to the ERC-6551
 * account they were pulled from, while the controlling NFT goes to the seller.
 *
 * Written against the `reclaim(uint256 bundleId, address extrasTo)` signature
 * introduced on branch `reclaim-e/s1`. On `main`, where `reclaim` still takes
 * one argument, this file does not compile — which is the point: these tests
 * describe the new behaviour, not the old.
 *
 * Nothing here edits `src/`.
 */
contract V2ReclaimMigratedTest is Test {
    using VaultV2Views for NewTradeV2VaultV2;

    address private constant SEAPORT = 0x0000000000000068F116a894984e2DB1123eB395;

    NewTradeEscrowV2 private escrow;
    /// partial-release-oct20: the upgradeable vault, switched in as in production (D1).
    NewTradeV2VaultV2 private vault;
    NewTradeBundle private receipt;
    Mock6551Registry private registry;
    Mock6551Implementation private accountImplementation;

    MockERC20 private erc20;
    MockERC721 private control;   // the controlling NFT collection
    MockERC721 private extra721;  // an extra held in the manifest
    MockERC1155 private erc1155;

    address private seller = address(0xA11CE);
    address private stranger = address(0xBAD);
    address private eoaDestination = address(0xD00D);

    uint64 private deadline;

    // Amounts deposited by `_migrate`, asserted back out again on reclaim.
    uint256 private constant ERC20_AMOUNT = 20 ether;
    uint256 private constant ERC1155_ID = 3;
    uint256 private constant ERC1155_AMOUNT = 4;

    function setUp() public {
        vm.etch(SEAPORT, address(new SeaportV2Mock()).code);

        erc20 = new MockERC20("Migrated", "MIG", 18);
        control = new MockERC721();
        extra721 = new MockERC721();
        erc1155 = new MockERC1155();

        address[] memory payments = new address[](1);
        payments[0] = address(0);

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

        receipt = BundleDeploy.deploy(address(this), SEAPORT, SEAPORT, address(this));
        NewTradeV2Vault legacyVault = new NewTradeV2Vault(address(this), address(receipt), tokens, kinds, modes);
        registry = new Mock6551Registry();
        accountImplementation = new Mock6551Implementation();

        V2Initialization memory initialization = V2Initialization(
            address(this),
            address(0xFEE),
            250,
            payments,
            tokens,
            kinds,
            modes,
            address(registry),
            address(accountImplementation),
            address(accountImplementation),
            address(receipt),
            address(legacyVault),
            SEAPORT,
            SEAPORT,
            address(0)
        );
        NewTradeEscrowV2 implementation = new NewTradeEscrowV2();
        escrow = NewTradeEscrowV2(
            payable(
                address(
                    new ERC1967Proxy(
                        address(implementation), abi.encodeCall(NewTradeEscrowV2.initialize, (initialization))
                    )
                )
            )
        );
        receipt.bindController(address(escrow));
        legacyVault.bindController(address(escrow));
        vault = VaultV2Deploy.switchEscrowMirroring(escrow, address(receipt), tokens, kinds, modes);

        // Migration ENABLED for the whole file; the plain-deposit test does not
        // need it off, since `deposit` never consults the flag.
        escrow.setMigrationEnabled(true);

        deadline = uint64(block.timestamp + 1 days);
    }

    // ------------------------------------------------------------- helpers

    /**
     * Mint `nftId` of the controlling collection to the seller, create its
     * ERC-6551 account, fund that account with ERC-20 + ERC-721 + ERC-1155,
     * and deposit all three through `depositFromAccount`.
     *
     * The account needs no approvals: the vault pulls the controlling NFT
     * first, which makes the vault the account's `owner()`, and only then
     * calls `execute` on it to move the extras.
     */
    function _migrate(uint256 nftId) internal returns (uint256 bundleId, address source) {
        control.mint(seller, nftId);
        source = registry.createAccount(
            address(accountImplementation), keccak256("reclaim-migrated"), block.chainid, address(control), nftId
        );

        erc20.mint(source, ERC20_AMOUNT);
        extra721.mint(source, nftId);
        erc1155.mint(source, ERC1155_ID, ERC1155_AMOUNT);

        vm.prank(seller);
        control.setApprovalForAll(address(vault), true);

        ManifestEntry[] memory entries = _entries(nftId);
        vm.prank(seller);
        bundleId = escrow.depositFromAccount(
            source, address(control), nftId, entries, deadline, keccak256(abi.encode("nonce", nftId))
        );

        // Custody actually happened, so the later assertions mean something.
        assertEq(control.ownerOf(nftId), address(vault), "control NFT should be in the vault");
        assertEq(erc20.balanceOf(source), 0, "ERC-20 should have left the account");
        assertEq(extra721.ownerOf(nftId), address(vault), "extra ERC-721 should be in the vault");
        assertEq(erc1155.balanceOf(source, ERC1155_ID), 0, "ERC-1155 should have left the account");
    }

    /// The wallet path: seller holds the assets and deposits them directly.
    function _plainDeposit(uint256 nftId) internal returns (uint256 bundleId) {
        control.mint(seller, nftId);
        erc20.mint(seller, ERC20_AMOUNT);
        extra721.mint(seller, nftId);
        erc1155.mint(seller, ERC1155_ID, ERC1155_AMOUNT);

        vm.startPrank(seller);
        control.setApprovalForAll(address(vault), true);
        erc20.approve(address(vault), type(uint256).max);
        extra721.setApprovalForAll(address(vault), true);
        erc1155.setApprovalForAll(address(vault), true);
        bundleId = escrow.deposit(address(control), nftId, _entries(nftId), deadline);
        vm.stopPrank();
    }

    function _entries(uint256 nftId) internal view returns (ManifestEntry[] memory entries) {
        entries = new ManifestEntry[](3);
        entries[0] = ManifestEntry(AssetKind.ERC20, address(erc20), 0, ERC20_AMOUNT);
        entries[1] = ManifestEntry(AssetKind.ERC721, address(extra721), nftId, 1);
        entries[2] = ManifestEntry(AssetKind.ERC1155, address(erc1155), ERC1155_ID, ERC1155_AMOUNT);
    }

    /// Every extras assertion in one place: `to` holds all three, and the
    /// vault's books are back to zero for them.
    function _assertExtrasLandedAt(address to, uint256 nftId) internal view {
        assertEq(erc20.balanceOf(to), ERC20_AMOUNT, "ERC-20 destination");
        assertEq(extra721.ownerOf(nftId), to, "ERC-721 destination");
        assertEq(erc1155.balanceOf(to, ERC1155_ID), ERC1155_AMOUNT, "ERC-1155 destination");

        assertEq(erc20.balanceOf(address(vault)), 0, "vault ERC-20 drained");
        assertEq(erc1155.balanceOf(address(vault), ERC1155_ID), 0, "vault ERC-1155 drained");
        assertEq(vault.erc20Liability(address(erc20)), 0, "erc20Liability cleared");
        assertEq(vault.erc1155Liability(address(erc1155), ERC1155_ID), 0, "erc1155Liability cleared");
        assertFalse(vault.erc721Reserved(address(extra721), nftId), "extra erc721Reserved cleared");
        assertFalse(vault.erc721Reserved(address(control), nftId), "control erc721Reserved cleared");
        assertEq(vault.assetLiabilityUnits(address(erc20)), 0, "erc20 units cleared");
        assertEq(vault.assetLiabilityUnits(address(extra721)), 0, "extra erc721 units cleared");
        assertEq(vault.assetLiabilityUnits(address(erc1155)), 0, "erc1155 units cleared");
        assertEq(vault.assetLiabilityUnits(address(control)), 0, "control units cleared");
    }

    /// The bundle is terminal and the wrapper is gone.
    function _assertReclaimedAndBurned(uint256 bundleId) internal {
        assertEq(uint8(escrow.getBundle(bundleId).state), uint8(BundleState.Reclaimed), "state should be Reclaimed");
        vm.expectRevert();
        receipt.ownerOf(bundleId);
    }

    // --------------------------------------------------------------- tests

    /// T1 — extras return to the account they were pulled from, and nowhere else.
    function test_MigratedReclaim_ExtrasReturnToSourceAccount() public {
        uint256 nftId = 11;
        (uint256 bundleId, address source) = _migrate(nftId);

        vm.warp(deadline);
        vm.prank(seller);
        escrow.reclaim(bundleId, source);

        // Exactly the pre-deposit position of the account, restored.
        _assertExtrasLandedAt(source, nftId);

        // The seller's wallet received NONE of the extras. This is the half of
        // T1 that fails if extras are routed to the seller instead.
        assertEq(erc20.balanceOf(seller), 0, "seller must not receive the ERC-20");
        assertTrue(extra721.ownerOf(nftId) != seller, "seller must not receive the extra ERC-721");
        assertEq(erc1155.balanceOf(seller, ERC1155_ID), 0, "seller must not receive the ERC-1155");

        _assertReclaimedAndBurned(bundleId);
    }

    /// T2 — the inversion catcher. The controlling NFT goes to the seller's
    /// wallet, NOT into the account that is bound to it.
    function test_MigratedReclaim_NftReturnsToSellerWallet_NotIntoItsAccount() public {
        uint256 nftId = 12;
        (uint256 bundleId, address source) = _migrate(nftId);

        vm.warp(deadline);
        vm.prank(seller);
        escrow.reclaim(bundleId, source);

        assertEq(control.ownerOf(nftId), seller, "controlling NFT must land with the seller");
        assertTrue(control.ownerOf(nftId) != source, "controlling NFT must NOT land in its own account");

        // With the two destinations swapped the NFT would be owned by the
        // account that derives its owner from that same NFT. Assert the
        // ownership chain still terminates at the seller.
        assertEq(Mock6551Account(payable(source)).owner(), seller, "account owner must resolve to the seller");

        _assertReclaimedAndBurned(bundleId);
    }

    /// T3 — after reclaim the account is still bound to the same NFT and the
    /// seller can drive it again.
    function test_MigratedReclaim_AccountStillBoundAndControlledBySeller() public {
        uint256 nftId = 13;
        (uint256 bundleId, address source) = _migrate(nftId);

        vm.warp(deadline);
        vm.prank(seller);
        escrow.reclaim(bundleId, source);

        (uint256 boundChain, address boundToken, uint256 boundId) = Mock6551Account(payable(source)).token();
        assertEq(boundChain, block.chainid, "bound chain id");
        assertEq(boundToken, address(control), "bound collection");
        assertEq(boundId, nftId, "bound token id");

        // Control is real, not nominal: the seller moves an asset back out.
        vm.prank(seller);
        IERC6551ExecutableAccount(source).execute(
            address(erc20), 0, abi.encodeCall(IERC20.transfer, (seller, ERC20_AMOUNT)), 0
        );
        assertEq(erc20.balanceOf(seller), ERC20_AMOUNT, "seller withdrew the ERC-20 from the account");
        assertEq(erc20.balanceOf(source), 0, "account balance moved out");
    }

    /// T4 — the wallet path is untouched: passing the seller as `extrasTo`
    /// reproduces today's behaviour exactly.
    function test_PlainDepositReclaim_Unchanged() public {
        uint256 nftId = 14;
        uint256 bundleId = _plainDeposit(nftId);

        vm.warp(deadline);
        vm.prank(seller);
        escrow.reclaim(bundleId, seller);

        _assertExtrasLandedAt(seller, nftId);
        assertEq(control.ownerOf(nftId), seller, "controlling NFT back to the seller");
        _assertReclaimedAndBurned(bundleId);
    }

    /// T9 — authorization is unchanged for a migrated bundle. The new argument
    /// does not open any of the four existing doors.
    function test_MigratedReclaim_AuthorizationUnchanged() public {
        uint256 nftId = 15;
        (uint256 bundleId, address source) = _migrate(nftId);

        // (a) before the deadline, even for the seller.
        vm.prank(seller);
        vm.expectRevert(NewTradeEscrowV2.Unauthorized.selector);
        escrow.reclaim(bundleId, source);

        // (b) a non-seller, after the deadline.
        vm.warp(deadline);
        vm.prank(stranger);
        vm.expectRevert(NewTradeEscrowV2.Unauthorized.selector);
        escrow.reclaim(bundleId, source);

        // (c) a stranger cannot redirect the extras to themselves either.
        vm.prank(stranger);
        vm.expectRevert(NewTradeEscrowV2.Unauthorized.selector);
        escrow.reclaim(bundleId, stranger);

        // Nothing moved on any refused attempt.
        assertEq(control.ownerOf(nftId), address(vault), "NFT still in custody");
        assertEq(erc20.balanceOf(address(vault)), ERC20_AMOUNT, "extras still in custody");

        // (d) the seller succeeds once...
        vm.prank(seller);
        escrow.reclaim(bundleId, source);
        _assertReclaimedAndBurned(bundleId);

        // ...and cannot reclaim the same bundle twice.
        vm.prank(seller);
        vm.expectRevert(NewTradeEscrowV2.Unauthorized.selector);
        escrow.reclaim(bundleId, source);
    }

    /// E-a — a zero destination is refused rather than burning the assets.
    function test_MigratedReclaim_ZeroExtrasToReverts() public {
        uint256 nftId = 16;
        (uint256 bundleId,) = _migrate(nftId);

        vm.warp(deadline);
        vm.prank(seller);
        // A missing destination has its own error (review finding F-1): `Unauthorized` would
        // send the seller looking at their wallet instead of at the destination field.
        vm.expectRevert(NewTradeEscrowV2.ZeroAddress.selector);
        escrow.reclaim(bundleId, address(0));

        // The refusal is atomic: custody and the wrapper are intact, and the
        // bundle can still be reclaimed properly afterwards.
        assertEq(uint8(escrow.getBundle(bundleId).state), uint8(BundleState.Deposited), "state untouched");
        assertEq(receipt.ownerOf(bundleId), address(escrow), "wrapper not burned");
        assertEq(control.ownerOf(nftId), address(vault), "NFT still in custody");
        assertEq(erc20.balanceOf(address(vault)), ERC20_AMOUNT, "extras still in custody");
        assertEq(erc20.balanceOf(address(0)), 0, "nothing sent to the zero address");
    }

    /// E-b — `extrasTo` is a free choice, not merely "the source account":
    /// an arbitrary EOA works, and the NFT still goes to the seller.
    function test_MigratedReclaim_ArbitraryEoaDestination() public {
        uint256 nftId = 17;
        (uint256 bundleId, address source) = _migrate(nftId);

        vm.warp(deadline);
        vm.prank(seller);
        escrow.reclaim(bundleId, eoaDestination);

        _assertExtrasLandedAt(eoaDestination, nftId);
        assertEq(control.ownerOf(nftId), seller, "controlling NFT still goes to the seller");

        // Neither the seller's wallet nor the source account received extras.
        assertEq(erc20.balanceOf(seller), 0, "seller received no extras");
        assertEq(erc20.balanceOf(source), 0, "source account received no extras");
        assertEq(erc1155.balanceOf(source, ERC1155_ID), 0, "source account received no ERC-1155");

        _assertReclaimedAndBurned(bundleId);
    }

    // ------------------------------------------------------------------
    // S2 - inversion catchers (seniordev). Each of T6, T7, T8 was shown to FAIL
    // when the two destinations of `_burnAndRelease` are deliberately swapped;
    // the mutation table is in the S2 report.
    // ------------------------------------------------------------------

    address private constant CONDUIT = 0x1E0049783F008A0085193E00003D00cd54003c71;
    address private buyer = address(0xB0B);

    /// List at 1 ether (2.5% protocol fee to the treasury of `setUp`) and issue the claim to `buyer`.
    function _listAndIssue(uint256 bundleId) internal {
        vm.etch(CONDUIT, address(new ConduitMock()).code);
        Payout[] memory payouts = new Payout[](2);
        payouts[0] = Payout(payable(address(escrow)), 0.975 ether);
        payouts[1] = Payout(payable(address(0xFEE)), 0.025 ether);
        vm.prank(seller);
        escrow.list(bundleId, address(0), 1 ether, deadline, 0, payouts);
        (OrderParameters memory p,,,,) = escrow.getOrder(bundleId);
        SeaportV2Mock(SEAPORT).fill(p, buyer);
        assertEq(receipt.ownerOf(bundleId), buyer, "claim should be issued to the buyer");
    }

    /// T6 - the rename touched the redeem call site too. Redemption must still send the manifest
    /// assets to the FRESH account and the controlling NFT to the HOLDER, for a migrated and for a
    /// plain bundle, and must never touch the original source account.
    function test_Redeem_DestinationsUnchangedByRename() public {
        (uint256 migratedId, address source) = _migrate(21);
        _listAndIssue(migratedId);
        bytes32 salt = keccak256("t6-migrated");
        (address predicted,) = escrow.computeFreshAccount(migratedId, buyer, salt);
        vm.prank(buyer);
        address fresh = escrow.redeemToFreshAccount(migratedId, salt);

        assertEq(fresh, predicted, "fresh account is the predicted one");
        assertTrue(fresh != source, "fresh account is not the source account");
        _assertExtrasLandedAt(fresh, 21);
        assertEq(control.ownerOf(21), buyer, "controlling NFT goes to the holder, not into the fresh account");
        assertEq(erc20.balanceOf(buyer), 0, "holder wallet receives no extras");
        assertEq(erc20.balanceOf(source), 0, "source account untouched by redemption");
        assertEq(erc1155.balanceOf(source, ERC1155_ID), 0, "source account untouched by redemption (1155)");
        assertEq(uint8(escrow.getBundle(migratedId).state), uint8(BundleState.Redeemed));
    }

    function test_Redeem_PlainBundleDestinationsUnchangedByRename() public {
        uint256 plainId = _plainDeposit(22);
        _listAndIssue(plainId);
        bytes32 salt = keccak256("t6-plain");
        vm.prank(buyer);
        address fresh = escrow.redeemToFreshAccount(plainId, salt);

        _assertExtrasLandedAt(fresh, 22);
        assertEq(control.ownerOf(22), buyer, "controlling NFT goes to the holder");
        assertEq(erc20.balanceOf(buyer), 0, "holder wallet receives no extras");
        assertEq(erc20.balanceOf(seller), 0, "seller receives nothing on redemption");
    }

    /// T7 - pins the EXACT external call the escrow makes into the vault, argument by argument.
    /// partial-release-oct20: the call is now beginRelease(bundleId, mode, extrasTo, nftTo); the
    /// vault reads the NFT from its own custody record. Distinct addresses are used for the two
    /// destinations in every case, so a positional swap cannot produce the same calldata.
    function test_Reclaim_VaultReleaseCalldataPinsDestinations_Migrated() public {
        (uint256 bundleId, address source) = _migrate(23);
        vm.warp(deadline);
        vm.expectCall(
            address(vault), abi.encodeCall(NewTradeV2VaultV2.beginRelease, (bundleId, ReleaseMode.Reclaim, source, seller)), 1
        );
        vm.prank(seller);
        escrow.reclaim(bundleId, source);
    }

    function test_Reclaim_VaultReleaseCalldataPinsDestinations_PlainToOtherAddress() public {
        uint256 bundleId = _plainDeposit(24);
        vm.warp(deadline);
        vm.expectCall(
            address(vault),
            abi.encodeCall(NewTradeV2VaultV2.beginRelease, (bundleId, ReleaseMode.Reclaim, eoaDestination, seller)),
            1
        );
        vm.prank(seller);
        escrow.reclaim(bundleId, eoaDestination);
    }

    function test_Redeem_VaultReleaseCalldataPinsDestinations() public {
        (uint256 bundleId,) = _migrate(25);
        _listAndIssue(bundleId);
        bytes32 salt = keccak256("t7-redeem");
        (address predicted,) = escrow.computeFreshAccount(bundleId, buyer, salt);
        vm.expectCall(
            address(vault), abi.encodeCall(NewTradeV2VaultV2.beginRelease, (bundleId, ReleaseMode.Redeem, predicted, buyer)), 1
        );
        vm.prank(buyer);
        escrow.redeemToFreshAccount(bundleId, salt);
    }

    /// T8 - partial-release-oct20 (F-01): was "RevertsAtomicallyIfDestinationRejects". A refused
    /// entry no longer undoes the reclaim: what the destination accepts leaves, what it refuses
    /// stays held, the bundle is Reclaiming. The destination accepts only the controlling
    /// collection, so under swapped destinations it would take the controlling NFT and the
    /// extras would go to the seller: every assertion below would fail.
    ///
    /// CONSEQUENCE, recorded on purpose: the reclaim destination is fixed at the first call and
    /// a reclaim has no redirect (D2-B is the redeemer's only), so the refused entries cannot
    /// leave while this destination refuses them. Open item for the redirect decision (owner).
    function test_MigratedReclaim_RefusingDestinationKeepsRefusedEntriesHeld() public {
        (uint256 bundleId,) = _migrate(26);
        SelectiveReceiver rejecting = new SelectiveReceiver(address(control));

        vm.warp(deadline);
        vm.prank(seller);
        escrow.reclaim(bundleId, address(rejecting));

        assertEq(uint8(escrow.getBundle(bundleId).state), uint8(BundleState.Reclaiming), "partial");
        vm.expectRevert();
        receipt.ownerOf(bundleId);
        assertEq(control.ownerOf(26), seller, "controlling NFT went to the seller");
        assertEq(erc20.balanceOf(address(rejecting)), ERC20_AMOUNT, "ERC-20 has no hook: it left");
        assertEq(vault.erc20Liability(address(erc20)), 0);
        assertEq(extra721.ownerOf(26), address(vault), "refused ERC-721 still held");
        assertTrue(vault.erc721Reserved(address(extra721), 26));
        assertEq(erc1155.balanceOf(address(vault), ERC1155_ID), ERC1155_AMOUNT, "refused ERC-1155 still held");
        assertEq(vault.erc1155Liability(address(erc1155), ERC1155_ID), ERC1155_AMOUNT);
        (,, uint256 held) = vault.bundleStatus(bundleId);
        assertEq(held, 6, "entries 1 and 2 held");

        // A retry by anyone goes to the RECORDED destination and is refused again.
        vm.prank(stranger);
        escrow.withdrawRemaining(bundleId, 6, "");
        (,, held) = vault.bundleStatus(bundleId);
        assertEq(held, 6);
        // The seller cannot start a second reclaim to another address.
        vm.prank(seller);
        vm.expectRevert(NewTradeEscrowV2.Unauthorized.selector);
        escrow.reclaim(bundleId, seller);

        // Decision 2 (2026-11-20): the seller alone redirects what is still held, although
        // the controlling NFT has already left. Nobody else can, the refusing destination
        // included.
        bytes memory cmd = abi.encode(uint8(1), seller);
        vm.prank(stranger);
        vm.expectRevert(NewTradeV2VaultV2.NotRedeemer.selector);
        escrow.withdrawRemaining(bundleId, 6, cmd);
        vm.prank(address(rejecting));
        vm.expectRevert(NewTradeV2VaultV2.NotRedeemer.selector);
        escrow.withdrawRemaining(bundleId, 6, cmd);
        uint256 sellerErc20 = erc20.balanceOf(seller);
        vm.prank(seller);
        escrow.withdrawRemaining(bundleId, 6, cmd);
        assertEq(uint8(escrow.getBundle(bundleId).state), uint8(BundleState.Reclaimed), "closed");
        assertEq(extra721.ownerOf(26), seller);
        assertEq(erc1155.balanceOf(seller, ERC1155_ID), ERC1155_AMOUNT);
        assertFalse(vault.erc721Reserved(address(extra721), 26));
        assertEq(vault.erc1155Liability(address(erc1155), ERC1155_ID), 0);
        // The entry released before the redirect stays where it went.
        assertEq(erc20.balanceOf(address(rejecting)), ERC20_AMOUNT);
        assertEq(erc20.balanceOf(seller), sellerErc20);
    }

    /// Protocol addresses as `extrasTo` (S3; op O-1; decision 2026-11-20). The vault refuses
    /// itself, the escrow and the claim collection as a first destination, so the reclaim
    /// reverts whole - claim not burned, nothing recorded - and the seller chooses again.
    /// Was "...ToTheVaultItselfKeepsEveryEntryHeld" / "...ToTheEscrowKeepsNftEntriesHeld".
    function test_Reclaim_ToAProtocolAddressRevertsAndTheSellerChoosesAgain() public {
        (uint256 bundleId,) = _migrate(27);
        vm.warp(deadline);
        address[3] memory refused = [address(vault), address(escrow), address(receipt)];
        for (uint256 i; i < 3; ++i) {
            vm.prank(seller);
            vm.expectRevert(NewTradeV2VaultV2.InvalidDestination.selector);
            escrow.reclaim(bundleId, refused[i]);
        }
        assertEq(uint8(escrow.getBundle(bundleId).state), uint8(BundleState.Deposited));
        assertEq(receipt.ownerOf(bundleId), address(escrow), "claim not burned");
        assertEq(control.ownerOf(27), address(vault));
        (,, uint256 held) = vault.bundleStatus(bundleId);
        assertEq(held, (uint256(1) << 32) | 7);
        assertEq(vault.erc20Liability(address(erc20)), ERC20_AMOUNT);
        assertEq(erc20.balanceOf(address(escrow)), 0);

        vm.prank(seller);
        escrow.reclaim(bundleId, seller);
        assertEq(uint8(escrow.getBundle(bundleId).state), uint8(BundleState.Reclaimed));
        assertEq(control.ownerOf(27), seller);
        assertEq(extra721.ownerOf(27), seller);
    }

    /// An ERC-20-only manifest used to be strandable in the escrow (ERC-20 has no receiver
    /// hook). The escrow is now refused as a first destination, so the reclaim reverts and the
    /// tokens stay claimable. Was "...ToTheEscrowStrandsSellersOwnTokens".
    function test_Reclaim_Erc20OnlyManifestToTheEscrowIsRefused() public {
        control.mint(seller, 29);
        erc20.mint(seller, ERC20_AMOUNT);
        ManifestEntry[] memory entries = new ManifestEntry[](1);
        entries[0] = ManifestEntry(AssetKind.ERC20, address(erc20), 0, ERC20_AMOUNT);
        vm.startPrank(seller);
        control.setApprovalForAll(address(vault), true);
        erc20.approve(address(vault), type(uint256).max);
        uint256 bundleId = escrow.deposit(address(control), 29, entries, deadline);
        vm.stopPrank();

        vm.warp(deadline);
        vm.prank(seller);
        vm.expectRevert(NewTradeV2VaultV2.InvalidDestination.selector);
        escrow.reclaim(bundleId, address(escrow));

        assertEq(erc20.balanceOf(address(escrow)), 0, "nothing reached the escrow");
        assertEq(vault.erc20Liability(address(erc20)), ERC20_AMOUNT, "still owed by the vault");
        vm.prank(seller);
        escrow.reclaim(bundleId, seller);
        assertEq(vault.erc20Liability(address(erc20)), 0);
        assertEq(control.ownerOf(29), seller);
    }

    /// Review finding F-2 - authorization admits `Deposited | Listed`, but every other reclaim test
    /// starts from `Deposited` or passes the seller (which hides a swapped destination). A LISTED,
    /// never-sold, expired bundle must also send its extras to a third address and its NFT to the seller.
    function test_ListedBundleReclaim_ExtrasToChosenDestination_NftToSeller() public {
        (uint256 bundleId, address source) = _migrate(30);
        Payout[] memory payouts = new Payout[](2);
        payouts[0] = Payout(payable(address(escrow)), 0.975 ether);
        payouts[1] = Payout(payable(address(0xFEE)), 0.025 ether);
        vm.prank(seller);
        escrow.list(bundleId, address(0), 1 ether, deadline, 0, payouts);
        assertEq(uint8(escrow.getBundle(bundleId).state), uint8(BundleState.Listed), "precondition: Listed");

        vm.warp(deadline);
        vm.expectCall(
            address(vault), abi.encodeCall(NewTradeV2VaultV2.beginRelease, (bundleId, ReleaseMode.Reclaim, source, seller)), 1
        );
        vm.prank(seller);
        escrow.reclaim(bundleId, source);

        _assertExtrasLandedAt(source, 30);
        assertEq(control.ownerOf(30), seller, "controlling NFT goes to the seller");
        assertEq(erc20.balanceOf(seller), 0, "seller wallet receives no extras");
        _assertReclaimedAndBurned(bundleId);
    }
}
