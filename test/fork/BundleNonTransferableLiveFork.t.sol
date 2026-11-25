// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {NewTradeBundle} from "../../src/NewTradeBundle.sol";
import {NewTradeEscrowV2} from "../../src/NewTradeEscrowV2.sol";
import {BundleState} from "../../src/NewTradeV2Types.sol";
import {ISeaport, Order, OrderParameters} from "../../src/interfaces/ISeaport.sol";
import {BundleForkBase} from "./BundleForkBase.sol";
import {FeeForkZoneStub, IStrictRegistryArm} from "./EscrowFeeFromProceedsUpgradeFork.t.sol";
import {CardTestKit} from "../helpers/BundleCardHelpers.sol";

/**
 * HISTORICAL SUITE (pinned at block 51,863,600): the Base Bundle NFT AFTER its
 * NON-TRANSFERABLE upgrade (bundle-non-transferable-sep26; pinned by bundle-fork-repin-sep27).
 * The world moved on: since block 61,443,878 the proxy runs the zero-royalty 0x79a6…8a97
 * (deployments/base-mainnet-2026-11-24-bundle-zero-royalty-upgrade.md), and its ownership
 * changed on 2026-11-23/24. Every test runs ONLY on a fork at exactly block 51,863,600 and is
 * SKIPPED, with the reason, at any other block (the head included).
 *
 * THE LIVE WORLD: the owner 0xF8e0 deployed 0x9182dC37…8ab3 at block 51,863,175 and
 * called upgradeToAndCall(0x9182…, 0x) at block 51,863,513
 * (deployments/base-mainnet-2026-09-27-bundle-non-transferable-upgrade.md).
 *
 * WHAT THIS PROVES, on the real proxy with the owner READ LIVE (== 0xF8e0):
 *  - the implementation slot holds 0x9182…, whose runtime (the UUPS `__self`
 *    immutable zeroed) hashes to the deployment report's 5267ae0c…7581;
 *  - the image renderer (0x4519…, its source is not part of this repository),
 *    imageBaseURI "" and externalBaseURI are those Base served the block before
 *    the upgrade (51,863,512, read from a second fork of RPC_8453);
 *  - tokenURI(3) is exactly the pre-upgrade JSON plus the non-transferable
 *    insertions (the redeem-only phrase, the sentence and the Transferable attribute);
 *  - after a REAL Seaport fill of the listed bundle #3 (validator armed, SignedZone
 *    stubbed), its buyer cannot move it: transferFrom, safeTransferFrom and a conduit
 *    move all revert NonTransferable.
 * Any later change of implementation, renderer or settings fails LOUDLY.
 *
 * WHAT IT DOES NOT PROVE: nothing is broadcast; the fill and the probes are fork-only.
 *
 * RUN (read-only; the URL comes from YOUR environment, never from the repo):
 *   forge test --match-contract BundleNonTransferableLiveForkTest \
 *     --fork-url "$RPC_8453" --fork-block-number 51863600
 * Only a fork at exactly block 51,863,600 is the world this suite describes; any other
 * block SKIPS every test with the reason. RPC_8453 must be set: the pre-upgrade block is
 * read from it. Without a fork every test returns early.
 */
contract BundleNonTransferableLiveForkTest is BundleForkBase {
    uint256 constant BEFORE_UPGRADE_BLOCK = NON_TRANSFERABLE_UPGRADE_BLOCK - 1; // 0x29Da, the modular build
    string constant EXTERNAL_BASE = "https://newtrade-app.vercel.app/claim/8453/";
    /// The non-transferable build's UUPS `__self` immutable: 32 bytes at each offset (artifact immutableReferences).
    uint256 constant NT_RUNTIME_SIZE = 17_210;
    uint256 constant NT_SELF_REF_0 = 6_765;
    uint256 constant NT_SELF_REF_1 = 6_913;
    bytes32 constant NT_RUNTIME_MASKED_SHA256 = 0x5267ae0cbc9e641a922549f6b240fc1dbd32cf6faf8588962342b59a9eb97581;

    address constant SEAPORT = 0x0000000000000068F116a894984e2DB1123eB395;
    address constant VALIDATOR = 0xA000027A9B2802E1ddf7000061001e5c005A0000;
    address constant SIGNED_ZONE = 0x000056F7000000EcE9003ca63978907a00FFD100;
    address constant OPENSEA_CONDUIT = 0x1E0049783F008A0085193E00003D00cd54003c71;

    /// The block this HISTORICAL suite describes (after the non-transferable upgrade at
    /// 51,863,513, before the zero-royalty upgrade at 61,443,878).
    uint256 constant NT_SUITE_BLOCK = 51_863_600;

    /// HISTORICAL-suite gate: runs only on a fork at exactly NT_SUITE_BLOCK; SKIPS (with the
    /// reason) at any other block; returns early without a fork.
    function _live() internal returns (bool) {
        return _atPinnedBlock(NT_SUITE_BLOCK);
    }

    /// `impl`'s runtime with its `__self` immutable zeroed, after checking both references hold `impl`.
    function _masked(address impl) internal view returns (bytes memory code) {
        code = impl.code;
        assertEq(code.length, NT_RUNTIME_SIZE, "runtime size");
        uint256[2] memory refs = [NT_SELF_REF_0, NT_SELF_REF_1];
        for (uint256 i; i < 2; ++i) {
            uint256 at = refs[i];
            bytes32 word;
            assembly { word := mload(add(add(code, 32), at)) }
            assertEq(word, bytes32(uint256(uint160(impl))), "the __self immutable holds the implementation's own address");
            assembly { mstore(add(add(code, 32), at), 0) }
        }
    }

    /// (tokenURI(3), renderer, imageBaseURI, externalBaseURI) as Base served them at `blockNumber`.
    function _settingsAt(uint256 blockNumber)
        internal
        returns (string memory uri, address renderer, string memory imageBase, string memory externalBase)
    {
        uint256 here = vm.activeFork();
        vm.selectFork(vm.createFork(vm.envString("RPC_8453"), blockNumber));
        uri = bundle.tokenURI(BUNDLE);
        renderer = bundle.imageRenderer();
        imageBase = bundle.imageBaseURI();
        externalBase = bundle.externalBaseURI();
        vm.selectFork(here);
    }

    // ------------------------------------------------------------ the live world

    function test_TheLiveProxy_RunsTheRecordedNonTransferableBuild_OwnedByTheDeployer() public {
        if (!_live()) return;
        assertEq(_implementation(), NON_TRANSFERABLE_IMPLEMENTATION, "the proxy runs the non-transferable implementation 0x9182dC37");
        _liveOwner();
        assertEq(bundle.pendingOwner(), address(0), "no ownership transfer pending");
        bytes memory live = _masked(NON_TRANSFERABLE_IMPLEMENTATION);
        // 0x9182 is pinned by the deployment report's masked sha256 below. This repo's Bundle
        // artifact is now the zero-royalty source, so it is not compared here.
        assertEq(sha256(live), NT_RUNTIME_MASKED_SHA256, "masked runtime sha256 = the deployment report's");
    }

    function test_TheImageRendererAndBases_AreThoseBeforeTheUpgrade() public {
        if (!_live()) return;
        (, address rendererBefore, string memory imageBaseBefore, string memory externalBaseBefore) =
            _settingsAt(BEFORE_UPGRADE_BLOCK);
        assertEq(bundle.imageRenderer(), IMAGE_RENDERER_V1, "renderer 0x4519");
        assertEq(bundle.imageRenderer(), rendererBefore, "renderer unchanged by the upgrade");
        assertEq(bundle.imageBaseURI(), "", "no image base");
        assertEq(bundle.imageBaseURI(), imageBaseBefore, "imageBaseURI unchanged");
        assertEq(bundle.externalBaseURI(), EXTERNAL_BASE, "the claim base");
        assertEq(bundle.externalBaseURI(), externalBaseBefore, "externalBaseURI unchanged");
    }

    function test_TokenURI3_IsThePreUpgradeJson_PlusExactlyTheNonTransferableInsertions() public {
        if (!_live()) return;
        (string memory uriBefore,,,) = _settingsAt(BEFORE_UPGRADE_BLOCK);
        bytes memory before = CardTestKit.jsonOf(uriBefore);
        bytes memory today = CardTestKit.jsonOf(bundle.tokenURI(BUNDLE));
        assertFalse(CardTestKit.contains(before, '"Transferable"'), "no Transferable attribute before the upgrade");
        assertTrue(
            CardTestKit.contains(today, '{"trait_type":"Transferable","value":"No (redeem only)"}'),
            "tokenURI(3) carries the Transferable attribute"
        );
        assertEq(today, _withNonTransferable(before), "every other byte is what Base served at block 51,863,512");
    }

    function test_AfterARealSeaportFill_TheBuyerCannotMoveTheClaim() public {
        if (!_live()) return;
        NewTradeEscrowV2 escrow = NewTradeEscrowV2(payable(ESCROW));
        assertEq(uint8(escrow.getBundle(BUNDLE).state), uint8(BundleState.Listed), "bundle #3 is listed");
        address buyer = address(0xB0B0B0B);

        // Arm the strict registry while the SignedZone still has its real code, THEN stub the zone.
        vm.prank(SIGNED_ZONE);
        IStrictRegistryArm(VALIDATOR).beforeAuthorizedTransfer(PROXY, BUNDLE);
        vm.etch(SIGNED_ZONE, address(new FeeForkZoneStub()).code);
        (OrderParameters memory p,,,,) = escrow.getOrder(BUNDLE);
        uint256 price = escrow.getBundle(BUNDLE).price;
        vm.deal(buyer, price);
        vm.prank(buyer);
        assertTrue(ISeaport(SEAPORT).fulfillOrder{value: price}(Order(p, ""), bytes32(0)));
        assertEq(bundle.ownerOf(BUNDLE), buyer, "issued to the buyer");
        assertEq(uint8(escrow.getBundle(BUNDLE).state), uint8(BundleState.Issued));

        vm.prank(buyer);
        vm.expectRevert(NewTradeBundle.NonTransferable.selector);
        bundle.transferFrom(buyer, address(0xB0B), BUNDLE);
        vm.prank(buyer);
        vm.expectRevert(NewTradeBundle.NonTransferable.selector);
        bundle.safeTransferFrom(buyer, address(0xB0B), BUNDLE);
        // A marketplace resale through the OpenSea conduit, with its approval: refused too.
        vm.prank(buyer);
        bundle.approve(OPENSEA_CONDUIT, BUNDLE);
        vm.prank(OPENSEA_CONDUIT);
        vm.expectRevert(NewTradeBundle.NonTransferable.selector);
        bundle.transferFrom(buyer, address(0xB0B), BUNDLE);
        assertEq(bundle.ownerOf(BUNDLE), buyer, "still the buyer's");
    }
}
