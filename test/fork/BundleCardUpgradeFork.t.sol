// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {NewTradeBundle} from "../../src/NewTradeBundle.sol";
import {BundleForkBase} from "./BundleForkBase.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {CardTestKit} from "../helpers/BundleCardHelpers.sol";

/**
 * HISTORICAL SUITE (bundle-fork-repin-sep27): it describes the world at block 51785106,
 * so every test runs ONLY on a fork at exactly that block (`CARD_SUITES_BLOCK` in
 * BundleForkBase) and is SKIPPED, with the reason, at any other block - e.g. a
 * `forge test --fork-url …` at the head. The live Bundle (0x9182…, non-transferable)
 * is pinned by BundleNonTransferableLiveFork. Run it as its RUN line says:
 *   --fork-block-number 51785106
 *
 * HISTORICAL (pinned at 51,785,106): the world moved on - since block 51,798,691 the proxy runs the modular 0x29Da…19d6; see BundleImageModularLiveFork.
 *
 * The LIVE Base Bundle NFT proxy AFTER its on-chain image upgrade
 * (bundle-tokenuri-svg-upgrade-sep25; re-pinned by bundle-fork-test-post-upgrade-sep25).
 *
 * THE LIVE WORLD, pinned: the proxy runs the card implementation 0x9Cc1…0207
 * (upgrade tx 0x11b21767…d4ae, block 51,785,015, sent by the deployer 0xF8e0,
 * who became the owner by an Ownable2Step accept at block 51,776,515).
 *
 * WHAT THIS PROVES:
 *  - the implementation slot holds 0x9Cc1…, whose masked runtime sha256 is the
 *    deployment record's 519e899c…bf07 (source b2d15e2; at that commit it was
 *    also byte-equal to the `forge build` artifact - the source has since moved
 *    on to the modular image, see BundleImageModularUpgradeFork);
 *  - bundle #3's live metadata is the pre-upgrade JSON (block 51,774,972) plus
 *    exactly one `"image"` key;
 *  - `owner()` is the deployer 0xF8e0 (READ LIVE and asserted), with no transfer
 *    pending; the previous owner 0xc3F9, the escrow and a stranger cannot upgrade;
 *  - the owner upgrading to a fresh deployment of this repo's CURRENT artifact
 *    changes nothing observable but the non-transferable sentence and attribute
 *    (bundle-non-transferable-sep26) (tokenURI(3), the 19 reads, the transfer/mint/burn
 *    outcomes): with no renderer, the image is the same card;
 *  - the rollback to 0x19BE…b40F restores the old JSON exactly, and upgrading
 *    back to 0x9Cc1… restores the image.
 * Any later change of owner or implementation fails these tests LOUDLY.
 *
 * WHAT IT DOES NOT PROVE: nothing is broadcast. The owner is IMPERSONATED with
 * vm.prank; the rollback here is a fork-only rehearsal, never done on chain.
 *
 * RUN (read-only; the URL comes from YOUR environment, never from the repo):
 *   forge test --match-contract BundleCardUpgradeForkTest \
 *     --fork-url "$RPC_8453" --fork-block-number 51785106
 * The fork block must be at or after the upgrade (asserted). Without a fork every
 * test returns early (the proxy has no code): a run WITHOUT a URL proves nothing.
 */
contract BundleCardUpgradeForkTest is BundleForkBase {
    /// The card implementation's runtime with the UUPS `__self` immutable (32 bytes at
    /// each offset) zeroed: its sha256 is the deployment record's.
    uint256 constant CARD_RUNTIME_SIZE = 14_119;
    uint256 constant SELF_REF_0 = 6_895;
    uint256 constant SELF_REF_1 = 7_043;
    bytes32 constant CARD_RUNTIME_MASKED_SHA256 = 0x519e899cfa2db712fc25f40ca3b92a71141d032d03e793202b9cd5c2c3bdbf07;

    /// `impl`'s runtime with its `__self` immutable zeroed, after checking both
    /// references hold `impl` itself (a UUPS implementation's own address).
    function _maskedRuntime(address impl) internal view returns (bytes memory code) {
        code = impl.code;
        assertEq(code.length, CARD_RUNTIME_SIZE, "runtime size");
        uint256[2] memory refs = [SELF_REF_0, SELF_REF_1];
        for (uint256 i; i < 2; ++i) {
            uint256 at = refs[i];
            bytes32 word;
            assembly { word := mload(add(add(code, 32), at)) }
            assertEq(word, bytes32(uint256(uint160(impl))), "the __self immutable holds the implementation's own address");
            assembly { mstore(add(add(code, 32), at), 0) }
        }
    }

    /// The OLD JSON plus exactly one image, carrying bundle #3's facts.
    function _assertOldJsonPlusImage(bytes memory json) internal pure {
        (bytes memory without, bytes memory b64) = CardTestKit.stripImage(json);
        assertEq(without, bytes(FIXTURE_JSON), "every byte but the image is the pre-upgrade JSON");
        bytes memory svg = CardTestKit.decodeBase64(b64);
        assertTrue(CardTestKit.contains(svg, "NewTrade Bundle #3</text>"));
        assertTrue(CardTestKit.contains(svg, "Original NFT #104</text>"));
        assertTrue(CardTestKit.contains(svg, "0xf4fd&#8230;8953</text>"));
    }

    function test_TheLiveProxyRunsTheCardImplementation_OwnedByTheDeployer() public {
        if (!_atPinnedBlock(CARD_SUITES_BLOCK)) return;
        assertGe(block.number, UPGRADE_BLOCK, "fork at or after the upgrade");
        assertEq(_implementation(), CARD_IMPLEMENTATION, "the proxy runs the card implementation 0x9Cc1");
        address owner = _liveOwner();
        assertEq(bundle.pendingOwner(), address(0), "no transfer pending");
        assertEq(owner.code.length, 0, "the owner is an EOA");
        bytes memory json = CardTestKit.jsonOf(bundle.tokenURI(BUNDLE));
        _assertOldJsonPlusImage(json);
        vm.parseJson(string(json));
    }

    function test_TheDeployedImplementationIsTheRecordedBuild() public {
        if (!_atPinnedBlock(CARD_SUITES_BLOCK)) return;
        bytes memory live = _maskedRuntime(CARD_IMPLEMENTATION);
        assertEq(sha256(live), CARD_RUNTIME_MASKED_SHA256, "0x9Cc1's masked runtime is the deployment record's");
    }

    /// THIS SOURCE is the zero-royalty Bundle (e4b0b52, live as 0x79a6…8a97 since Base block
    /// 61,443,878; deployments/base-mainnet-2026-11-24-bundle-zero-royalty-upgrade.md): it answers
    /// ERC-2981 with (0, 0) for every claim. Upgrading this HISTORICAL world to this source therefore
    /// changes exactly the royalty quote, by design; every other observed fact must be identical.
    /// The suite passed unmodified against the pre-zero-royalty source (0f34fbd) at its pinned block.
    /// Kept in this .t.sol (not BundleForkBase.sol) so the release build, which compiles every
    /// non-.t.sol file, is unaffected.
    function _withZeroRoyalty(Observed memory o) internal pure returns (Observed memory) {
        o.royaltyTo = address(0);
        o.royaltyAmount = 0;
        return o;
    }

    function test_TheOwnerReUpgradingToThisSource_ChangesNothingObservable() public {
        if (!_atPinnedBlock(CARD_SUITES_BLOCK)) return;
        Observed memory beforeUpgrade = _observe();
        bytes32[4] memory probesBefore = _probes();
        string memory uriBefore = bundle.tokenURI(BUNDLE);

        // ---- the upgrade, owner IMPERSONATED, nothing broadcast ----------
        address impl = deployCode(ARTIFACT);
        address owner = _liveOwner();
        vm.prank(owner);
        bundle.upgradeToAndCall(impl, "");
        assertEq(_implementation(), impl);

        // ---- identical: tokenURI (but for bundle-non-transferable-sep26's two
        // insertions, now part of this source), the 19 reads, the probe outcomes
        assertEq(
            CardTestKit.jsonOf(bundle.tokenURI(BUNDLE)),
            _withNonTransferable(CardTestKit.jsonOf(uriBefore)),
            "tokenURI(3) byte-identical but for exactly the non-transferable sentence and attribute"
        );
        Observed memory afterUpgrade = _observe();
        // The zero-royalty source quotes (0, 0); the historical world quoted a non-zero royalty.
        assertGt(beforeUpgrade.royaltyAmount, 0, "the historical world quoted a royalty");
        assertEq(afterUpgrade.royaltyTo, address(0), "this source quotes no royalty recipient");
        assertEq(afterUpgrade.royaltyAmount, 0, "this source quotes a zero royalty");
        assertEq(keccak256(abi.encode(afterUpgrade)), keccak256(abi.encode(_withZeroRoyalty(beforeUpgrade))), "owner, wiring, interfaces, validator, name, balances, storage; only the royalty quote changes");
        assertEq(afterUpgrade.owner, EXPECTED_OWNER);
        assertEq(afterUpgrade.controller, ESCROW);
        bytes32[4] memory probesAfter = _probes();
        for (uint256 i; i < 4; ++i) assertEq(probesAfter[i], probesBefore[i], "transfer / mint / burn outcome unchanged");
    }

    function test_OnlyTheOwnerCanUpgrade() public {
        if (!_atPinnedBlock(CARD_SUITES_BLOCK)) return;
        address impl = deployCode(ARTIFACT);
        assertEq(_liveOwner(), EXPECTED_OWNER);
        // The previous owner, since the accept, is just another account.
        address[3] memory others = [address(0x5713), ESCROW, PREVIOUS_OWNER];
        for (uint256 i; i < 3; ++i) {
            vm.prank(others[i]);
            vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, others[i]));
            bundle.upgradeToAndCall(impl, "");
        }
        assertEq(_implementation(), CARD_IMPLEMENTATION);
    }

    /// A FORK-ONLY rehearsal of the rollback: never done on chain.
    function test_RollbackRestoresTheOldJsonExactly_AndUpgradingBackRestoresTheImage() public {
        if (!_atPinnedBlock(CARD_SUITES_BLOCK)) return;
        string memory liveUri = bundle.tokenURI(BUNDLE);
        address owner = _liveOwner();

        vm.prank(owner);
        bundle.upgradeToAndCall(PREVIOUS_IMPLEMENTATION, "");
        assertEq(_implementation(), PREVIOUS_IMPLEMENTATION);
        bytes memory oldJson = CardTestKit.jsonOf(bundle.tokenURI(BUNDLE));
        assertEq(oldJson, bytes(FIXTURE_JSON), "rolled back: the old JSON exactly");
        assertFalse(CardTestKit.contains(oldJson, '"image"'), "rolled back: no image");

        vm.prank(owner);
        bundle.upgradeToAndCall(CARD_IMPLEMENTATION, "");
        assertEq(_implementation(), CARD_IMPLEMENTATION);
        assertEq(bundle.tokenURI(BUNDLE), liveUri, "upgraded back: the live metadata, image included");
    }
}
