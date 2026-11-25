// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {NewTradeEscrowV2} from "../src/NewTradeEscrowV2.sol";
import {NewTradeEscrowV2Seeder} from "./legacy/NewTradeEscrowV2Seeder.sol";
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
import {OrderParameters} from "../src/interfaces/ISeaport.sol";
import {MockERC20, MockERC721, MockERC721Royalty, MockERC1155} from "./mocks/TokenMocks.sol";
import {SeaportV2Mock} from "./helpers/SeaportV2Mock.sol";
import {ConduitMock} from "./helpers/ConduitMock.sol";
import {Mock6551Registry, Mock6551Implementation, ToggleReleaseFailureERC20} from "./helpers/ERC6551Mocks.sol";

contract V2Handler is Test {
    address constant SEAPORT = 0x0000000000000068F116a894984e2DB1123eB395;
    address constant CONDUIT = 0x1E0049783F008A0085193E00003D00cd54003c71;
    NewTradeEscrowV2 public escrow;
    NewTradeV2VaultV2 public vault;
    /// f01-release-test-fixes: the manifest ERC-20 can be made to refuse transfers
    /// for one redemption, so the run reaches the partial (Redeeming) state.
    ToggleReleaseFailureERC20 public erc20;
    MockERC721 public nft;
    MockERC1155 public erc1155;
    NewTradeBundle public receipt;
    uint256[] public ids;
    uint256 public depositSuccess;
    uint256 public listSuccess;
    uint256 public issueSuccess;
    /// bundle-non-transferable-sep26: holder-to-holder moves after the first sale that were REFUSED (NonTransferable).
    uint256 public transferRefused;
    uint256 public redeemSuccess;
    /// One-bit retries of a still-failing token that reverted ReleaseFailed, as they must.
    uint256 public failedSingleRetry;
    uint256 public reclaimSuccess;
    /// f01-release-test-fixes: redemptions left Redeeming (ERC-20 entry held) and
    /// the retries that closed them.
    uint256 public partialRedeemSuccess;
    uint256 public retryCloseSuccess;
    mapping(uint256 => bool) public partialSeen;
    mapping(uint256 => bool) public issuedSeen;
    mapping(uint256 => bool) public terminalSeen;
    mapping(uint256 => bool) public approvalMustBeClear;

    // Migrated bundles (depositFromAccount): the ERC-6551 account the manifest came from, and a
    // ghost ledger of what every reclaimed migrated bundle must have put back into it.
    Mock6551Registry public registry;
    address public accountImplementation;
    uint256 public migratedDepositSuccess;
    uint256 public migratedReclaimSuccess;
    mapping(uint256 => address) public sourceOf;
    mapping(uint256 => uint256) public controlTokenOf;
    mapping(address => uint256) public returned20;
    mapping(address => uint256) public returned1155;
    address[] public sources;

    constructor(
        NewTradeEscrowV2 e,
        NewTradeV2VaultV2 v,
        NewTradeBundle r,
        ToggleReleaseFailureERC20 t,
        MockERC721 n,
        MockERC1155 m,
        Mock6551Registry reg,
        address implementation
    ) {
        registry = reg;
        accountImplementation = implementation;
        escrow = e;
        vault = v;
        receipt = r;
        erc20 = t;
        nft = n;
        erc1155 = m;
        t.approve(address(v), type(uint256).max);
        n.setApprovalForAll(address(v), true);
        m.setApprovalForAll(address(v), true);
        depositMixed(1, 1);
    }

    function depositMixed(uint96 rawAmount, uint32 raw1155) public {
        uint256 amount = bound(uint256(rawAmount), 1, 1e24);
        uint256 qty = bound(uint256(raw1155), 1, 1e9);
        uint256 tokenId = ids.length + 1;
        nft.mint(address(this), tokenId);
        erc20.mint(address(this), amount);
        erc1155.mint(address(this), 1, qty);
        ManifestEntry[] memory es = new ManifestEntry[](2);
        es[0] = ManifestEntry(AssetKind.ERC20, address(erc20), 0, amount);
        es[1] = ManifestEntry(AssetKind.ERC1155, address(erc1155), 1, qty);
        uint256 id = escrow.deposit(address(nft), tokenId, es, uint64(block.timestamp + 1 days));
        ids.push(id);
        depositSuccess++;
    }

    /// The ERC-6551 path: the manifest sits in the NFT's token-bound account and is pulled out of
    /// it by `depositFromAccount`. This handler is the seller; the account needs no approvals
    /// because the vault takes the controlling NFT first and thereby becomes the account's owner.
    function depositMigrated(uint96 rawAmount, uint32 raw1155) public {
        uint256 amount = bound(uint256(rawAmount), 1, 1e24);
        uint256 qty = bound(uint256(raw1155), 1, 1e9);
        uint256 tokenId = ids.length + 1;
        nft.mint(address(this), tokenId);
        address source =
            registry.createAccount(accountImplementation, keccak256("invariant"), block.chainid, address(nft), tokenId);
        erc20.mint(source, amount);
        erc1155.mint(source, 1, qty);
        ManifestEntry[] memory es = new ManifestEntry[](2);
        es[0] = ManifestEntry(AssetKind.ERC20, address(erc20), 0, amount);
        es[1] = ManifestEntry(AssetKind.ERC1155, address(erc1155), 1, qty);
        uint256 id = escrow.depositFromAccount(
            source, address(nft), tokenId, es, uint64(block.timestamp + 1 days), keccak256(abi.encode("n", tokenId))
        );
        ids.push(id);
        sourceOf[id] = source;
        controlTokenOf[id] = tokenId;
        sources.push(source);
        depositSuccess++;
        migratedDepositSuccess++;
    }

    function reclaimOne(uint256 seed) public {
        if (ids.length == 0) return;
        uint256 id = ids[seed % ids.length];
        Bundle memory b = escrow.getBundle(id);
        if (b.state != BundleState.Deposited) return;
        vm.warp(b.custodyDeadline);
        address source = sourceOf[id];
        if (source == address(0)) {
            escrow.reclaim(id, address(this));
        } else {
            // A migrated bundle goes home: extras back into the account they came from.
            ManifestEntry[] memory es = escrow.getManifest(id);
            escrow.reclaim(id, source);
            returned20[source] += es[0].amount;
            returned1155[source] += es[1].amount;
            migratedReclaimSuccess++;
        }
        terminalSeen[id] = true;
        reclaimSuccess++;
    }

    function sourceCount() external view returns (uint256) {
        return sources.length;
    }

    function listOne(uint256 seed) public {
        if (ids.length == 0) return;
        uint256 id = ids[seed % ids.length];
        Bundle memory b = escrow.getBundle(id);
        if (b.state != BundleState.Deposited || block.timestamp >= b.custodyDeadline) return;
        Payout[] memory ps = new Payout[](1);
        ps[0] = Payout(payable(address(escrow)), 1 ether);
        escrow.list(id, address(0), 1 ether, b.custodyDeadline, 0, ps);
        listSuccess++;
    }

    function issueOne(uint256 seed, address recipient) public {
        if (ids.length == 0) return;
        uint256 id = ids[seed % ids.length];
        Bundle memory b = escrow.getBundle(id);
        if (b.state != BundleState.Listed || block.timestamp >= b.custodyDeadline) return;
        recipient = address(uint160(bound(uint256(uint160(recipient)), 0x1000, type(uint160).max)));
        if (recipient == address(escrow) || recipient == address(receipt)) return;
        (OrderParameters memory p,,,,) = escrow.getOrder(id);
        SeaportV2Mock(SEAPORT).fill(p, recipient);
        issuedSeen[id] = true;
        approvalMustBeClear[id] = true;
        issueSuccess++;
    }

    function transferOne(uint256 seed, address next) public {
        if (ids.length == 0) return;
        uint256 id = ids[seed % ids.length];
        Bundle memory b = escrow.getBundle(id);
        if (b.state != BundleState.Issued) return;
        address owner = receipt.ownerOf(id);
        next = address(uint160(bound(uint256(uint160(next)), 0x1000, type(uint160).max)));
        if (next == owner || next == address(escrow) || next == address(receipt)) return;
        _refusedMove(id, owner, next);
    }

    /// bundle-non-transferable-sep26: any move of an issued claim by its holder
    /// - through the validator-approved conduit - must revert NonTransferable
    /// and leave the holder unchanged. The approval it needed is revoked after.
    function _refusedMove(uint256 id, address owner, address next) internal {
        vm.prank(owner);
        receipt.approve(CONDUIT, id);
        try SeaportV2Mock(SEAPORT).transferReceipt(address(receipt), owner, next, id) {
            revert("an issued claim moved after its first sale");
        } catch (bytes memory err) {
            require(err.length >= 4 && bytes4(err) == NewTradeBundle.NonTransferable.selector, "refused for another reason");
        }
        require(receipt.ownerOf(id) == owner, "holder changed");
        vm.prank(owner);
        receipt.approve(address(0), id);
        transferRefused++;
    }

    function returnAndExitOne(uint256 seed, address) public {
        if (ids.length == 0) return;
        uint256 id = ids[seed % ids.length];
        if (escrow.getBundle(id).state != BundleState.Issued) return;
        address owner = receipt.ownerOf(id);
        if (owner == address(escrow)) return;
        // A return to the escrow is a holder-to-holder move too: refused, so a
        // second exit can never happen.
        _refusedMove(id, owner, address(escrow));
    }

    /// f01-release-test-fixes: with `failErc20` the manifest ERC-20 refuses the
    /// release, so the redemption burns the claim and stays Redeeming with entry 0
    /// held. Only a redemption that actually closed is recorded as terminal; a
    /// partial one stays active (liability, custody) until `withdrawRemainingOne`.
    function redeemOne(uint256 seed, bytes32 salt, bool failErc20) public {
        if (ids.length == 0) return;
        uint256 id = ids[seed % ids.length];
        if (escrow.getBundle(id).state != BundleState.Issued) return;
        address owner = receipt.ownerOf(id);
        if (failErc20) erc20.setFailRelease(true);
        vm.prank(owner);
        escrow.redeemToFreshAccount(id, salt);
        if (failErc20) erc20.setFailRelease(false);
        issuedSeen[id] = true;
        BundleState s = escrow.getBundle(id).state;
        if (s == BundleState.Redeemed) {
            require(!failErc20, "closed although the ERC-20 refused");
            terminalSeen[id] = true;
        } else {
            require(failErc20 && s == BundleState.Redeeming, "partial redemption not Redeeming");
            (,, uint256 held) = vault.bundleStatus(id);
            require(held == 1, "only the refused ERC-20 entry is held");
            partialSeen[id] = true;
            partialRedeemSuccess++;
        }
        redeemSuccess++;
    }

    /// Anyone's retry of a partial redemption. With the ERC-20 still refusing,
    /// nothing changes and the bundle stays Redeeming; otherwise it closes.
    /// Single mode (decision 1, 2026-11-20): when exactly one bit is held, the
    /// failing retry must REVERT with ReleaseFailed, not succeed as a no-op.
    function withdrawRemainingOne(uint256 seed, address caller, bool stillFailing) public {
        if (ids.length == 0) return;
        uint256 id = ids[seed % ids.length];
        if (escrow.getBundle(id).state != BundleState.Redeeming) return;
        (,, uint256 heldBefore) = vault.bundleStatus(id);
        if (stillFailing) {
            bool oneBit = heldBefore & (heldBefore - 1) == 0;
            erc20.setFailRelease(true);
            vm.prank(caller);
            try escrow.withdrawRemaining(id, heldBefore, "") {
                require(!oneBit, "a failing single retry succeeded");
            } catch (bytes memory err) {
                require(
                    oneBit && bytes4(err) == NewTradeV2VaultV2.ReleaseFailed.selector, "unexpected retry revert"
                );
                failedSingleRetry++;
            }
            erc20.setFailRelease(false);
        } else {
            vm.prank(caller);
            escrow.withdrawRemaining(id, heldBefore, "");
        }
        (,, uint256 heldAfter) = vault.bundleStatus(id);
        if (stillFailing) {
            require(escrow.getBundle(id).state == BundleState.Redeeming, "a failing retry closed the bundle");
            require(heldAfter == heldBefore, "a failing retry changed the held mask");
        } else {
            require(escrow.getBundle(id).state == BundleState.Redeemed, "a healthy retry left the bundle open");
            require(heldAfter == 0, "a healthy retry left entries held");
            terminalSeen[id] = true;
            retryCloseSuccess++;
        }
    }

    function count() external view returns (uint256) {
        return ids.length;
    }

    function idAt(uint256 i) external view returns (uint256) {
        return ids[i];
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return 0x150b7a02;
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return 0xf23a6e61;
    }
}

contract V2InvariantTest is StdInvariant, Test {
    using VaultV2Views for NewTradeV2VaultV2;

    address constant SEAPORT = 0x0000000000000068F116a894984e2DB1123eB395;
    address constant CONDUIT = 0x1E0049783F008A0085193E00003D00cd54003c71;
    NewTradeEscrowV2 escrow;
    NewTradeV2VaultV2 vault;
    NewTradeBundle receipt;
    ToggleReleaseFailureERC20 erc20;
    MockERC721 nft;
    MockERC1155 erc1155;
    V2Handler handler;

    function setUp() public {
        vm.etch(SEAPORT, address(new SeaportV2Mock()).code);
        // The conduit is a real operator in this design, so it must exist locally.
        vm.etch(CONDUIT, address(new ConduitMock()).code);
        erc20 = new ToggleReleaseFailureERC20();
        nft = new MockERC721();
        erc1155 = new MockERC1155();
        address[] memory pays = new address[](1);
        pays[0] = address(0);
        address[] memory ats = new address[](3);
        ats[0] = address(erc20);
        ats[1] = address(nft);
        ats[2] = address(erc1155);
        AssetKind[] memory aks = new AssetKind[](3);
        aks[0] = AssetKind.ERC20;
        aks[1] = AssetKind.ERC721;
        aks[2] = AssetKind.ERC1155;
        AcceptanceMode[3] memory modes = [AcceptanceMode.Allowlist, AcceptanceMode.Allowlist, AcceptanceMode.Allowlist];
        Mock6551Registry registry = new Mock6551Registry();
        Mock6551Implementation implementation = new Mock6551Implementation();
        receipt = BundleDeploy.deploy(address(this), SEAPORT, SEAPORT, address(this));
        NewTradeV2Vault legacyVault = new NewTradeV2Vault(address(this), address(receipt), ats, aks, modes);
        V2Initialization memory c = V2Initialization(
            address(this),
            address(1),
            0,
            pays,
            ats,
            aks,
            modes,
            address(registry),
            address(implementation),
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
        vault = VaultV2Deploy.switchEscrowMirroring(escrow, address(receipt), ats, aks, modes);
        escrow.setMigrationEnabled(true);
        handler = new V2Handler(escrow, vault, receipt, erc20, nft, erc1155, registry, address(implementation));
        targetContract(address(handler));
    }

    function invariant_AggregateLiabilityEqualsActiveManifestAndIsBacked() public view {
        uint256 expected20;
        uint256 expected1155;
        for (uint256 i; i < handler.count(); ++i) {
            uint256 id = handler.idAt(i);
            Bundle memory b = escrow.getBundle(id);
            assertEq(b.everIssued, handler.issuedSeen(id), "issuance monotonic");
            if (handler.terminalSeen(id)) {
                assertTrue(b.state == BundleState.Redeemed || b.state == BundleState.Reclaimed, "terminal permanent");
            }
            // f01-release-test-fixes: a partial redemption is still active. Its held
            // entries keep their liability and their backing; its claim is burned.
            if (handler.partialSeen(id) && !handler.terminalSeen(id)) {
                assertEq(uint8(b.state), uint8(BundleState.Redeeming), "partial redemption stays Redeeming");
            }
            if (b.state == BundleState.Redeeming || b.state == BundleState.Reclaiming) {
                (,, uint256 held) = vault.bundleStatus(id);
                assertTrue(held != 0, "a partial bundle holds something");
                ManifestEntry[] memory es = escrow.getManifest(id);
                if (held & 1 != 0) expected20 += es[0].amount;
                if (held & 2 != 0) expected1155 += es[1].amount;
                try receipt.ownerOf(id) returns (address) {
                    revert("partial bundle receipt must be burned");
                } catch {}
                if (b.state == BundleState.Redeeming) assertTrue(b.everIssued, "redeeming was issued");
                continue;
            }
            if (b.state == BundleState.Deposited || b.state == BundleState.Listed || b.state == BundleState.Issued) {
                ManifestEntry[] memory es = escrow.getManifest(id);
                expected20 += es[0].amount;
                expected1155 += es[1].amount;
                address owner = receipt.ownerOf(id);
                if (b.state == BundleState.Deposited || b.state == BundleState.Listed) {
                    assertEq(owner, address(escrow), "unissued receipt escrow-held");
                    assertFalse(b.everIssued, "unissued never issued");
                } else {
                    assertTrue(owner != address(0), "issued receipt exists");
                    assertTrue(b.everIssued, "issued permanence");
                }
                if (handler.approvalMustBeClear(id)) assertEq(receipt.getApproved(id), address(0));
            } else {
                try receipt.ownerOf(id) returns (address) {
                    revert("terminal receipt must stay burned");
                } catch {}
                if (b.state == BundleState.Reclaimed) assertFalse(b.everIssued, "issued cannot reclaim");
                if (b.state == BundleState.Redeemed) assertTrue(b.everIssued, "redeemed was issued");
            }
        }
        assertEq(vault.erc20Liability(address(erc20)), expected20);
        assertEq(vault.erc1155Liability(address(erc1155), 1), expected1155);
        assertGe(erc20.balanceOf(address(vault)), expected20);
        assertGe(erc1155.balanceOf(address(vault), 1), expected1155);
        assertGt(handler.depositSuccess(), 0);
    }

    /// Migrated bundles: whatever a reclaimed migrated bundle held is back in the account it was
    /// pulled from, and the controlling NFT is NEVER owned by its own account (which is where a
    /// swapped destination pair would put it) - it is in custody, or with the seller/holder.
    function invariant_MigratedReclaimReturnsExtrasToSourceAndNeverTheNft() public view {
        for (uint256 i; i < handler.count(); ++i) {
            uint256 id = handler.idAt(i);
            address source = handler.sourceOf(id);
            if (source == address(0)) continue;
            uint256 tokenId = handler.controlTokenOf(id);
            assertTrue(nft.ownerOf(tokenId) != source, "controlling NFT inside its own account");
            Bundle memory b = escrow.getBundle(id);
            if (b.state == BundleState.Reclaimed) {
                assertEq(nft.ownerOf(tokenId), address(handler), "reclaimed controlling NFT is with the seller");
            } else if (b.state == BundleState.Redeeming) {
                // f01-release-test-fixes: only the refused ERC-20 is held; the NFT has left custody.
                (,, uint256 held) = vault.bundleStatus(id);
                if (held & (uint256(1) << 32) != 0) {
                    assertEq(nft.ownerOf(tokenId), address(vault), "held controlling NFT is in custody");
                } else {
                    assertTrue(nft.ownerOf(tokenId) != address(vault), "released controlling NFT left custody");
                }
                assertEq(erc20.balanceOf(source), 0, "partial migrated account is empty");
            } else if (b.state != BundleState.Redeemed) {
                assertEq(nft.ownerOf(tokenId), address(vault), "active controlling NFT is in custody");
                assertEq(erc20.balanceOf(source), 0, "active migrated account is empty");
            }
        }
        for (uint256 i; i < handler.sourceCount(); ++i) {
            address source = handler.sources(i);
            assertEq(erc20.balanceOf(source), handler.returned20(source), "source account ERC-20 ledger");
            assertEq(erc1155.balanceOf(source, 1), handler.returned1155(source), "source account ERC-1155 ledger");
        }
    }

    function test_HandlerSuccessfulPaths() public {
        handler.depositMixed(2, 3);
        handler.listOne(0);
        handler.issueOne(0, address(0xBEEF));
        handler.transferOne(0, address(0xCAFE));
        handler.redeemOne(0, keccak256("redeem"), false);
        handler.reclaimOne(1);
        // Migrated path: deposit from an ERC-6551 account, then reclaim back into it.
        handler.depositMigrated(5, 7);
        uint256 migratedId = handler.idAt(handler.count() - 1);
        address source = handler.sourceOf(migratedId);
        handler.reclaimOne(handler.count() - 1);
        assertEq(handler.migratedDepositSuccess(), 1);
        assertEq(handler.migratedReclaimSuccess(), 1);
        assertEq(erc20.balanceOf(source), 5, "extras back in the source account");
        assertEq(erc1155.balanceOf(source, 1), 7, "ERC-1155 back in the source account");
        assertEq(nft.ownerOf(handler.controlTokenOf(migratedId)), address(handler), "NFT back with the seller");
        invariant_MigratedReclaimReturnsExtrasToSourceAndNeverTheNft();
        assertGt(handler.depositSuccess(), 1);
        assertGt(handler.listSuccess(), 0);
        assertGt(handler.issueSuccess(), 0);
        assertGt(handler.transferRefused(), 0);
        assertGt(handler.redeemSuccess(), 0);
        assertGt(handler.reclaimSuccess(), 0);
    }

    /// f01-release-test-fixes: a partial redemption stays active through the
    /// invariant (Redeeming, ERC-20 held with its liability), a failing retry
    /// changes nothing, and a healthy retry closes it to Redeemed.
    function test_HandlerPartialRedeemStaysActiveUntilRetryCloses() public {
        handler.depositMixed(4, 5);
        uint256 i = handler.count() - 1;
        uint256 id = handler.idAt(i);
        handler.listOne(i);
        handler.issueOne(i, address(0xBEEF));
        handler.redeemOne(i, keccak256("partial"), true);
        assertEq(handler.partialRedeemSuccess(), 1);
        assertFalse(handler.terminalSeen(id), "a partial redemption is not terminal");
        assertEq(uint8(escrow.getBundle(id).state), uint8(BundleState.Redeeming));
        assertEq(vault.erc20Liability(address(erc20)), 1 + 4, "held ERC-20 keeps its liability");
        assertEq(vault.erc1155Liability(address(erc1155), 1), 1, "released ERC-1155 left the liability");
        invariant_AggregateLiabilityEqualsActiveManifestAndIsBacked();

        handler.withdrawRemainingOne(i, address(0xCAFE), true);
        assertEq(handler.failedSingleRetry(), 1, "one entry held: the failing retry reverted");
        assertEq(uint8(escrow.getBundle(id).state), uint8(BundleState.Redeeming));
        invariant_AggregateLiabilityEqualsActiveManifestAndIsBacked();

        handler.withdrawRemainingOne(i, address(0xCAFE), false);
        assertEq(handler.retryCloseSuccess(), 1);
        assertTrue(handler.terminalSeen(id));
        assertEq(uint8(escrow.getBundle(id).state), uint8(BundleState.Redeemed));
        assertEq(vault.erc20Liability(address(erc20)), 1);
        invariant_AggregateLiabilityEqualsActiveManifestAndIsBacked();
    }
}

// =============================================================================
// Owed ledger / surplus (escrow-fee-from-proceeds-sep25)
// =============================================================================

/// Forces native value into the escrow, whose receive() accepts Seaport only.
contract StrayNativeSender {
    constructor(address payable to) payable {
        selfdestruct(to);
    }
}

/**
 * Drives every path that moves an escrow balance or the owed ledger: sales
 * (deposit + list + a PAID fill, native or ERC-20, first exit credits
 * item0 - fee), seller withdrawals, admin withdrawSurplus with random amounts
 * (under, at and over the cap), a non-admin withdrawSurplus, stray native
 * (selfdestruct) and stray ERC-20 (a payment token and a never-allowlisted
 * one), fee-bps changes between listings and payment-allowlist flips.
 *
 * Each handler checks its own step and raises a sticky flag on a violation;
 * the invariants read the flags and the ledger. Ghost: the seller set.
 */
contract V2SurplusHandler is Test {
    address constant SEAPORT = 0x0000000000000068F116a894984e2DB1123eB395;
    NewTradeEscrowV2 public escrow;
    MockERC20 public asset;
    MockERC20 public pay;
    MockERC20 public junk;
    /// Option B: the controlling NFT answers ERC-2981; `sell` sets a random rate to a random creator.
    MockERC721Royalty public nft;
    address public admin;
    address public buyer = address(0xB0B0);
    address[3] public sellers = [address(0x5E11E1), address(0x5E11E2), address(0x5E11E3)];
    address[3] public payees = [address(0xFEE1), address(0xFEE2), address(0xFEE3)];
    /// Option B ghost: the creators credited at first exit (a seller may be its own creator too).
    address[2] public creators = [address(0xC0FFE1), address(0xC0FFE2)];
    address[3] public tokens;
    uint256 public nextTokenId = 1;
    /// Ghost of the live fee bps (setUp initialises 250; only setFee changes it).
    uint256 public feeBps = 250;

    // (iii) the cap is exact: over-cap attempts all revert, in-cap attempts all succeed
    bool public overCapSucceeded;
    bool public inCapReverted;
    // (iv) no admin action changes any seller's claimable
    bool public adminMovedSellerClaimable;
    // (v) totalOwed moves only at a first exit (up by the net) or a seller withdrawal (down by the amount)
    bool public totalOwedMovedOutsideLedger;
    bool public nonAdminSucceeded;
    // (vi) balance < totalOwed: every withdrawSurplus reverts with Panic 0x11 (trim 3 fails safe)
    bool public shortfallNotPanic;
    uint256 public shortfallAttempts;
    // Option B: withdrawFor pays the credited account ONLY, and reverts on zero.
    bool public withdrawForPaidWrong;
    bool public withdrawForZeroSucceeded;
    uint256 public creatorCredits;
    uint256 public creatorWithdrawals;
    uint256 public withdrawForCalls;
    uint256 public withdrawForZeroCalls;

    uint256 public sales;
    uint256 public sellerWithdrawals;
    uint256 public surplusWithdrawals;
    uint256 public overCapAttempts;
    uint256 public nonAdminAttempts;
    uint256 public strays;
    uint256 public feeChanges;
    uint256 public allowlistFlips;

    constructor(NewTradeEscrowV2 e, MockERC20 asset_, MockERC20 pay_, MockERC20 junk_, MockERC721Royalty nft_, address admin_) {
        escrow = e;
        asset = asset_;
        pay = pay_;
        junk = junk_;
        nft = nft_;
        admin = admin_;
        tokens = [address(0), address(pay_), address(junk_)];
        vm.prank(buyer);
        pay_.approve(SEAPORT, type(uint256).max);
    }

    function _token(uint256 seed) internal view returns (address) {
        return tokens[seed % 3];
    }

    function _balance(address token) internal view returns (uint256) {
        return token == address(0) ? address(escrow).balance : MockERC20(token).balanceOf(address(escrow));
    }

    /// The ghost set: three sellers and two creators.
    function _claimables(address token) internal view returns (uint256[5] memory c) {
        for (uint256 i; i < 3; ++i) c[i] = escrow.claimable(sellers[i], token);
        for (uint256 i; i < 2; ++i) c[3 + i] = escrow.claimable(creators[i], token);
    }

    function _sameClaimables(uint256[5] memory a, uint256[5] memory b) internal pure returns (bool) {
        return a[0] == b[0] && a[1] == b[1] && a[2] == b[2] && a[3] == b[3] && a[4] == b[4];
    }

    /// Checks (iv)+(v) for an action that must not touch the ledger, for every token.
    modifier ledgerUntouched() {
        uint256[5][3] memory before;
        uint256[3] memory owed;
        for (uint256 t; t < 3; ++t) {
            before[t] = _claimables(tokens[t]);
            owed[t] = escrow.totalOwed(tokens[t]);
        }
        _;
        for (uint256 t; t < 3; ++t) {
            if (!_sameClaimables(before[t], _claimables(tokens[t]))) adminMovedSellerClaimable = true;
            if (escrow.totalOwed(tokens[t]) != owed[t]) totalOwedMovedOutsideLedger = true;
        }
    }

    function sell(uint256 sellerSeed, bool native, uint96 rawPrice, uint96 rawAsset, uint256 creatorSeed, uint16 rawBps) public {
        address seller = sellers[sellerSeed % 3];
        // Option B: a random ERC-2981 rate (0..10 %) to a creator, or to the seller itself.
        address creator = creatorSeed % 3 == 2 ? seller : creators[creatorSeed % 2];
        uint256 bps = bound(uint256(rawBps), 0, 1_000);
        nft.setRoyaltyBps(creator, uint96(bps));
        address token = native ? address(0) : address(pay);
        if (!escrow.isPaymentTokenAllowed(token)) return;
        uint256 price = bound(uint256(rawPrice), 1, 1e24);
        uint256 tokenId = nextTokenId++;
        nft.mint(seller, tokenId);
        uint256 amount = bound(uint256(rawAsset), 1, 1e24);
        asset.mint(seller, amount);
        ManifestEntry[] memory es = new ManifestEntry[](1);
        es[0] = ManifestEntry(AssetKind.ERC20, address(asset), 0, amount);
        uint64 deadline = uint64(block.timestamp + 1 days);
        vm.startPrank(seller);
        uint256 id = escrow.deposit(address(nft), tokenId, es, deadline);
        Payout[] memory ps = new Payout[](1);
        ps[0] = Payout(payable(address(escrow)), price);
        escrow.list(id, token, price, deadline, 10_000, ps);
        vm.stopPrank();
        uint256 fee = price * feeBps / 10_000;
        uint256 royalty = price * bps / 10_000;
        (OrderParameters memory p,,,,) = escrow.getOrder(id);

        uint256 owedBefore = escrow.totalOwed(token);
        uint256 claimBefore = escrow.claimable(seller, token);
        uint256 creatorBefore = escrow.claimable(creator, token);
        if (native) {
            vm.deal(address(this), price);
            SeaportV2Mock(SEAPORT).fillAndPayNative{value: price}(p, buyer);
        } else {
            pay.mint(buyer, price);
            SeaportV2Mock(SEAPORT).fillAndPay(p, buyer, buyer);
        }
        // The whole escrow item less the fee is owed: the seller's net plus the creator's royalty.
        if (escrow.totalOwed(token) != owedBefore + (price - fee)) totalOwedMovedOutsideLedger = true;
        if (creator == seller) {
            if (escrow.claimable(seller, token) != claimBefore + (price - fee)) totalOwedMovedOutsideLedger = true;
        } else {
            if (escrow.claimable(seller, token) != claimBefore + (price - royalty - fee)) totalOwedMovedOutsideLedger = true;
            if (escrow.claimable(creator, token) != creatorBefore + royalty) totalOwedMovedOutsideLedger = true;
        }
        if (royalty != 0) creatorCredits++;
        sales++;
    }

    function sellerWithdraw(uint256 sellerSeed, uint256 tokenSeed) public {
        address seller = sellers[sellerSeed % 3];
        address token = _token(tokenSeed);
        uint256 amount = escrow.claimable(seller, token);
        if (amount == 0) return;
        uint256 owedBefore = escrow.totalOwed(token);
        vm.prank(seller);
        escrow.withdraw(token);
        if (escrow.totalOwed(token) != owedBefore - amount) totalOwedMovedOutsideLedger = true;
        sellerWithdrawals++;
    }

    function creatorWithdraw(uint256 creatorSeed, uint256 tokenSeed) public {
        address creator = creators[creatorSeed % 2];
        address token = _token(tokenSeed);
        uint256 amount = escrow.claimable(creator, token);
        if (amount == 0) return;
        uint256 owedBefore = escrow.totalOwed(token);
        vm.prank(creator);
        escrow.withdraw(token);
        if (escrow.totalOwed(token) != owedBefore - amount) totalOwedMovedOutsideLedger = true;
        creatorWithdrawals++;
    }

    /// A STRANGER calls withdrawFor for any ghost account (or one that is owed nothing).
    function withdrawForAny(uint256 accountSeed, uint256 tokenSeed, uint256 callerSeed) public {
        address token = _token(tokenSeed);
        uint256 k = accountSeed % 6;
        address account = k < 3 ? sellers[k] : k < 5 ? creators[k - 3] : address(0xDEAD0);
        address caller = address(uint160(bound(callerSeed, 0x100000, 0xFFFFFF)));
        uint256 amount = escrow.claimable(account, token);
        uint256 owedBefore = escrow.totalOwed(token);
        uint256 accountBefore = token == address(0) ? account.balance : MockERC20(token).balanceOf(account);
        uint256 callerBefore = token == address(0) ? caller.balance : MockERC20(token).balanceOf(caller);
        vm.prank(caller);
        try escrow.withdrawFor(account, token) returns (uint256 paid) {
            if (amount == 0) { withdrawForZeroSucceeded = true; return; }
            uint256 accountAfter = token == address(0) ? account.balance : MockERC20(token).balanceOf(account);
            uint256 callerAfter = token == address(0) ? caller.balance : MockERC20(token).balanceOf(caller);
            if (paid != amount || accountAfter != accountBefore + amount || callerAfter != callerBefore) withdrawForPaidWrong = true;
            if (escrow.claimable(account, token) != 0) withdrawForPaidWrong = true;
            if (escrow.totalOwed(token) != owedBefore - amount) totalOwedMovedOutsideLedger = true;
            withdrawForCalls++;
        } catch {
            if (amount != 0) withdrawForPaidWrong = true; // a credited account must be payable here
            else withdrawForZeroCalls++;
        }
    }

    function creatorAt(uint256 i) external view returns (address) {
        return creators[i];
    }

    function adminWithdrawSurplus(uint256 tokenSeed, uint256 payeeSeed, uint256 rawAmount) public ledgerUntouched {
        address token = _token(tokenSeed);
        address to = payees[payeeSeed % 3];
        uint256 bal = _balance(token);
        uint256 owed = escrow.totalOwed(token);
        uint256 cap = bal >= owed ? bal - owed : 0;
        // Amounts from 0 through twice the cap plus what is owed: under, at and well over.
        uint256 amount = bound(rawAmount, 0, 2 * cap + owed + 2);
        bool shouldSucceed = amount != 0 && amount <= cap && bal >= owed;
        if (!shouldSucceed) overCapAttempts++;
        vm.prank(admin);
        try escrow.withdrawSurplus(token, to, amount) {
            if (!shouldSucceed) overCapSucceeded = true;
            surplusWithdrawals++;
        } catch {
            if (shouldSucceed) inCapReverted = true;
        }
    }

    function nonAdminWithdrawSurplus(uint256 tokenSeed, uint256 callerSeed, uint256 rawAmount) public ledgerUntouched {
        address token = _token(tokenSeed);
        address caller = callerSeed % 2 == 0 ? sellers[callerSeed % 3] : address(uint160(bound(callerSeed, 0x10000, 0xFFFFFF)));
        if (caller == admin) return;
        uint256 cap = _balance(token) - escrow.totalOwed(token);
        if (cap == 0) return;
        uint256 amount = bound(rawAmount, 1, cap);
        nonAdminAttempts++;
        vm.prank(caller);
        try escrow.withdrawSurplus(token, caller, amount) {
            nonAdminSucceeded = true;
        } catch {}
    }

    /// A shortfall (e.g. a fee-on-transfer or rebasing loss): the balance drops below
    /// totalOwed, the admin tries any amount, then the balance is restored so the
    /// other invariants keep describing a solvent escrow.
    function shortfall(bool native, uint256 rawAmount) public ledgerUntouched {
        address token = native ? address(0) : address(pay);
        uint256 owed = escrow.totalOwed(token);
        if (owed == 0) return;
        uint256 bal = _balance(token);
        if (native) vm.deal(address(escrow), owed - 1);
        else deal(address(pay), address(escrow), owed - 1);
        shortfallAttempts++;
        vm.prank(admin);
        try escrow.withdrawSurplus(token, payees[0], bound(rawAmount, 1, type(uint256).max)) {
            shortfallNotPanic = true;
        } catch (bytes memory err) {
            if (keccak256(err) != keccak256(abi.encodeWithSignature("Panic(uint256)", 0x11))) shortfallNotPanic = true;
        }
        if (native) vm.deal(address(escrow), bal);
        else deal(address(pay), address(escrow), bal);
    }

    function strayNative(uint96 raw) public ledgerUntouched {
        uint256 amount = bound(uint256(raw), 1, 1e22);
        vm.deal(address(this), amount);
        new StrayNativeSender{value: amount}(payable(address(escrow)));
        strays++;
    }

    function strayErc20(bool allowlisted, uint96 raw) public ledgerUntouched {
        uint256 amount = bound(uint256(raw), 1, 1e24);
        (allowlisted ? pay : junk).mint(address(escrow), amount);
        strays++;
    }

    function setFee(uint16 raw) public ledgerUntouched {
        feeBps = bound(uint256(raw), 0, 1_000);
        vm.prank(admin);
        escrow.setProtocolFeeBps(uint96(feeBps));
        feeChanges++;
    }

    function flipAllowlist(bool native) public ledgerUntouched {
        address token = native ? address(0) : address(pay);
        bool allowed = escrow.isPaymentTokenAllowed(token);
        vm.prank(admin);
        escrow.setPaymentTokenAllowed(token, !allowed);
        allowlistFlips++;
    }

    function tokenAt(uint256 i) external view returns (address) {
        return tokens[i];
    }

    function sellerAt(uint256 i) external view returns (address) {
        return sellers[i];
    }

    receive() external payable {}
}

contract V2SurplusInvariantTest is StdInvariant, Test {
    address constant SEAPORT = 0x0000000000000068F116a894984e2DB1123eB395;
    address constant CONDUIT = 0x1E0049783F008A0085193E00003D00cd54003c71;
    NewTradeEscrowV2 escrow;
    NewTradeV2VaultV2 vault;
    NewTradeBundle receipt;
    MockERC20 asset;
    MockERC20 pay;
    MockERC20 junk;
    MockERC721Royalty nft;
    V2SurplusHandler handler;

    function setUp() public {
        vm.etch(SEAPORT, address(new SeaportV2Mock()).code);
        vm.etch(CONDUIT, address(new ConduitMock()).code);
        asset = new MockERC20("A", "A", 18);
        pay = new MockERC20("P", "P", 6);
        junk = new MockERC20("J", "J", 18);
        nft = new MockERC721Royalty();
        address[] memory pays = new address[](2);
        pays[0] = address(0);
        pays[1] = address(pay);
        address[] memory ats = new address[](2);
        ats[0] = address(asset);
        ats[1] = address(nft);
        AssetKind[] memory aks = new AssetKind[](2);
        aks[0] = AssetKind.ERC20;
        aks[1] = AssetKind.ERC721;
        AcceptanceMode[3] memory modes = [AcceptanceMode.Allowlist, AcceptanceMode.Allowlist, AcceptanceMode.Allowlist];
        Mock6551Registry registry = new Mock6551Registry();
        Mock6551Implementation implementation = new Mock6551Implementation();
        receipt = BundleDeploy.deploy(address(this), SEAPORT, SEAPORT, address(this));
        NewTradeV2Vault legacyVault = new NewTradeV2Vault(address(this), address(receipt), ats, aks, modes);
        V2Initialization memory c = V2Initialization(
            address(this),
            address(1),
            250,
            pays,
            ats,
            aks,
            modes,
            address(registry),
            address(implementation),
            address(implementation),
            address(receipt),
            address(legacyVault),
            SEAPORT,
            SEAPORT,
            address(0)
        );
        escrow = NewTradeEscrowV2(
            payable(address(new ERC1967Proxy(address(new NewTradeEscrowV2()), abi.encodeCall(NewTradeEscrowV2.initialize, (c)))))
        );
        receipt.bindController(address(escrow));
        legacyVault.bindController(address(escrow));
        // The production path: the one-shot seeder hop opens the ledger (version 2).
        address[] memory seedTokens = new address[](3);
        seedTokens[0] = address(0);
        seedTokens[1] = address(pay);
        seedTokens[2] = address(junk);
        escrow.upgradeToAndCall(
            address(new NewTradeEscrowV2Seeder()),
            abi.encodeCall(
                NewTradeEscrowV2Seeder.seedAndUpgrade, (address(new NewTradeEscrowV2()), seedTokens, new address[](0))
            )
        );
        // partial-release-oct20: the F-01 switch (version 3) comes after the seed, as live.
        vault = VaultV2Deploy.switchEscrowMirroring(escrow, address(receipt), ats, aks, modes);
        handler = new V2SurplusHandler(escrow, asset, pay, junk, nft, address(this));
        for (uint256 i; i < 3; ++i) {
            address seller = handler.sellerAt(i);
            vm.startPrank(seller);
            asset.approve(address(vault), type(uint256).max);
            nft.setApprovalForAll(address(vault), true);
            vm.stopPrank();
        }
        targetContract(address(handler));
    }

    function _balance(address token) internal view returns (uint256) {
        return token == address(0) ? address(escrow).balance : MockERC20(token).balanceOf(address(escrow));
    }

    /// (i) per token, totalOwed == the sum of every seller's claimable (the ghost set is all sellers).
    function invariant_i_TotalOwedEqualsSumOfClaimable() public view {
        for (uint256 t; t < 3; ++t) {
            address token = handler.tokenAt(t);
            uint256 sum;
            for (uint256 i; i < 3; ++i) sum += escrow.claimable(handler.sellerAt(i), token);
            for (uint256 i; i < 2; ++i) sum += escrow.claimable(handler.creatorAt(i), token);
            assertEq(escrow.totalOwed(token), sum, "(i) totalOwed != sum of claimable (sellers + creators)");
        }
    }

    /// (ii) per token, totalOwed <= balance: every seller can always be paid.
    function invariant_ii_TotalOwedIsBacked() public view {
        for (uint256 t; t < 3; ++t) {
            address token = handler.tokenAt(t);
            assertLe(escrow.totalOwed(token), _balance(token), "(ii) totalOwed > balance");
        }
    }

    /// (iii) the cap is exact: every admin attempt over balance - totalOwed reverted,
    /// and every attempt within it succeeded.
    function invariant_iii_SurplusCapIsExact() public view {
        assertFalse(handler.overCapSucceeded(), "(iii) an over-cap withdrawSurplus succeeded");
        assertFalse(handler.inCapReverted(), "(iii) an in-cap withdrawSurplus reverted");
    }

    /// (iv) no admin (or attempted) action changes any seller's claimable.
    function invariant_iv_AdminNeverMovesSellerClaimable() public view {
        assertFalse(handler.adminMovedSellerClaimable(), "(iv) an admin action changed a seller's claimable");
    }

    /// (v) totalOwed changes only at a first exit (up by item0 - fee) or a seller withdrawal (down).
    function invariant_v_TotalOwedMovesOnlyThroughTheLedger() public view {
        assertFalse(handler.totalOwedMovedOutsideLedger(), "(v) totalOwed moved outside a credit/debit");
    }

    /// (vi) trim 3 fails safe: with balance < totalOwed every withdrawSurplus reverted Panic(0x11).
    function invariant_vi_ShortfallAlwaysRevertsPanic() public view {
        assertFalse(handler.shortfallNotPanic(), "(vi) withdrawSurplus under a shortfall did not revert Panic 0x11");
    }

    /// Role: withdrawSurplus is DEFAULT_ADMIN_ROLE only.
    /// Option B: withdrawFor pays exactly the credited account (never the caller) and reverts on zero.
    function invariant_WithdrawForPaysTheAccountOnly() public view {
        assertFalse(handler.withdrawForPaidWrong(), "withdrawFor paid someone other than the account, or the wrong amount");
    }

    function invariant_WithdrawForOnZeroReverts() public view {
        assertFalse(handler.withdrawForZeroSucceeded(), "withdrawFor succeeded for an account owed nothing");
    }

    function invariant_NonAdminNeverWithdrawsSurplus() public view {
        assertFalse(handler.nonAdminSucceeded(), "non-admin withdrawSurplus succeeded");
    }

    /// Every handler path is reachable (a silent handler would make the invariants vacuous).
    function test_SurplusHandlerPathsAllExecute() public {
        handler.sell(0, true, 1 ether, 1, 0, 250); // 2.5 % to creator 0
        handler.sell(1, false, 5e6, 1, 1, 1_000); // 10 % to creator 1
        handler.shortfall(true, 1);
        handler.shortfall(false, type(uint256).max);
        handler.strayNative(0.5 ether);
        handler.strayErc20(true, 7);
        handler.strayErc20(false, 9);
        handler.adminWithdrawSurplus(0, 0, type(uint256).max); // over the cap
        handler.adminWithdrawSurplus(0, 0, 0.1 ether); // within
        handler.adminWithdrawSurplus(2, 1, 5); // a never-allowlisted token: all of it is surplus
        handler.nonAdminWithdrawSurplus(0, 0, 1);
        handler.sellerWithdraw(0, 0);
        handler.sellerWithdraw(1, 1);
        handler.setFee(1_000);
        handler.flipAllowlist(true);
        handler.flipAllowlist(true);
        handler.sell(2, true, 1 ether, 1, 2, 500); // the seller is its own creator (a real 5 % royalty)
        handler.creatorWithdraw(0, 0);
        handler.withdrawForAny(4, 1, 0x123456); // a stranger pays creator 1 its USDC-like credit
        handler.withdrawForAny(5, 0, 0x123457); // an account owed nothing: reverts
        assertEq(handler.creatorWithdrawals(), 1);
        assertEq(handler.withdrawForCalls(), 1);
        assertEq(handler.withdrawForZeroCalls(), 1);
        assertEq(handler.creatorCredits(), 3);
        assertEq(handler.shortfallAttempts(), 2);
        assertEq(handler.sales(), 3);
        assertEq(handler.sellerWithdrawals(), 2);
        assertEq(handler.surplusWithdrawals(), 2);
        assertEq(handler.overCapAttempts(), 1);
        assertEq(handler.nonAdminAttempts(), 1);
        assertEq(handler.strays(), 3);
        assertEq(handler.allowlistFlips(), 2);
        invariant_i_TotalOwedEqualsSumOfClaimable();
        invariant_ii_TotalOwedIsBacked();
        invariant_iii_SurplusCapIsExact();
        invariant_iv_AdminNeverMovesSellerClaimable();
        invariant_v_TotalOwedMovesOnlyThroughTheLedger();
        invariant_NonAdminNeverWithdrawsSurplus();
        invariant_vi_ShortfallAlwaysRevertsPanic();
    }
}
