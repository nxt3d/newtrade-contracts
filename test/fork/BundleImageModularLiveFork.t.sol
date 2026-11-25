// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {INewTradeBundleImage} from "../../src/interfaces/INewTradeBundleImage.sol";
import {BundleForkBase} from "./BundleForkBase.sol";
import {CardTestKit} from "../helpers/BundleCardHelpers.sol";

/**
 * HISTORICAL SUITE (bundle-fork-repin-sep27): it describes the world at block 51798787,
 * so every test runs ONLY on a fork at exactly that block (`MODULAR_LIVE_SUITES_BLOCK` in
 * BundleForkBase) and is SKIPPED, with the reason, at any other block - e.g. a
 * `forge test --fork-url …` at the head. The live Bundle (0x9182…, non-transferable)
 * is pinned by BundleNonTransferableLiveFork. Run it as its RUN line says:
 *   --fork-block-number 51798787
 *
 * The LIVE Base Bundle NFT AFTER its MODULAR image upgrade
 * (bundle-image-modular-upgrade-sep25; pinned by bundle-fork-tests-post-modular-sep25).
 *
 * THE LIVE WORLD, pinned at block 51,798,787 - after every transaction of the
 * modular deployment (deployments/base-mainnet-2026-09-25-bundle-image-modular-upgrade.md),
 * all sent by the deployer/owner 0xF8e0:
 *   upgradeToAndCall(0x29Da…19d6)         tx 0xd9ee6a3b…7067  block 51,798,691
 *   setImageRenderer(0x4519…56c5)         tx 0x4140547f…b937  block 51,798,695
 *   setExternalBaseURI(…/claim/8453/)     tx 0x1cb5b59e…4edc  block 51,798,718
 *   setImageRenderer(0x4519…56c5) again   tx 0x93ae72a5…f05c  block 51,798,731 (no-op re-set)
 *
 * WHAT THIS PROVES, on the real proxy with the owner READ LIVE (== 0xF8e0):
 *  - the implementation slot holds 0x29Da…, whose runtime (the UUPS `__self`
 *    immutable zeroed) is byte-equal to THIS REPO's `forge build` artifact, and
 *  - the settings: renderer 0x4519…, imageBaseURI "", externalBaseURI the claim base;
 *  - tokenURI(3) parses with keys name, description, image, external_url,
 *    attributes, properties; external_url = base + "3"; the image is exactly the
 *    renderer's answer; every other byte is the pre-image JSON (block 51,774,972);
 *  - ERC-4906 is announced; the 19 observed facts (owner, wiring, validator,
 *    royalty, interfaces, raw storage) equal those at the last pre-upgrade block
 *    51,798,690, read from a second fork of the same RPC;
 *  - the owner re-upgrading to the same implementation changes nothing
 *    observable; 0xc3F9, the escrow and a stranger cannot upgrade;
 *  - each rollback restores the JSON Base served before the matching transaction,
 *    byte for byte (read at that block): setExternalBaseURI("") = block 51,798,717;
 *    then setImageRenderer(0) = block 51,798,690 (the card); and from the live
 *    state upgradeToAndCall(0x9Cc1…) = block 51,798,690, after which upgrading
 *    forward restores today's JSON with the settings intact.
 * Any later change of owner, implementation, renderer or settings fails LOUDLY.
 *
 * WHAT IT DOES NOT PROVE: nothing is broadcast. The owner is IMPERSONATED; the
 * rollbacks here are fork-only rehearsals.
 *
 * RUN (read-only; the URL comes from YOUR environment, never from the repo):
 *   forge test --match-contract BundleImageModularLiveForkTest \
 *     --fork-url "$RPC_8453" --fork-block-number 51798787
 * RPC_8453 must be set: the historical blocks are read from it. Without a fork
 * every test returns early (the proxy has no code): a run WITHOUT a URL proves nothing.
 */
contract BundleImageModularLiveForkTest is BundleForkBase {
    uint256 constant PINNED_AFTER_BLOCK = 51_798_731; // the last modular-deployment tx
    uint256 constant BEFORE_UPGRADE_BLOCK = MODULAR_UPGRADE_BLOCK - 1; // the card, 0x9Cc1
    uint256 constant BEFORE_EXTERNAL_BASE_BLOCK = 51_798_717; // renderer set, no external_url yet
    string constant EXTERNAL_BASE = "https://newtrade-app.vercel.app/claim/8453/";
    address constant NFT = 0xf4fd1a2Ea84a16Be24848Aa6f4242E9CAab18953;
    uint256 constant NFT_ID = 104;

    /// The modular implementation's UUPS `__self` immutable: 32 bytes at each offset.
    uint256 constant SELF_REF_0 = 6_949;
    uint256 constant SELF_REF_1 = 7_097;

    // ------------------------------------------------------------ helpers

    function _asOwner() internal {
        vm.prank(_liveOwner());
    }

    /// tokenURI(3) as Base served it at `blockNumber`, read from a second fork of
    /// $RPC_8453; the test's own fork is selected again afterwards.
    function _tokenUriAt(uint256 blockNumber) internal returns (string memory uri) {
        uint256 here = vm.activeFork();
        vm.selectFork(vm.createFork(vm.envString("RPC_8453"), blockNumber));
        uri = bundle.tokenURI(BUNDLE);
        vm.selectFork(here);
    }

    function _observedAt(uint256 blockNumber) internal returns (Observed memory o) {
        uint256 here = vm.activeFork();
        vm.selectFork(vm.createFork(vm.envString("RPC_8453"), blockNumber));
        o = _observe();
        vm.selectFork(here);
    }

    /// Removes exactly one `"<key>":"…",` segment; returns (the JSON without it, the value).
    function _cut(bytes memory json, bytes memory key) internal pure returns (bytes memory without, bytes memory value) {
        bytes memory open = abi.encodePacked('"', key, '":"');
        int256 at = CardTestKit.indexOf(json, open, 0);
        require(at >= 0, "NO_KEY");
        require(CardTestKit.indexOf(json, abi.encodePacked('"', key, '":'), uint256(at) + 1) < 0, "TWO_KEYS");
        uint256 start = uint256(at) + open.length;
        int256 close = CardTestKit.indexOf(json, '",', start);
        require(close >= 0, "UNCLOSED");
        value = CardTestKit.slice(json, start, uint256(close));
        without = abi.encodePacked(CardTestKit.slice(json, 0, uint256(at)), CardTestKit.slice(json, uint256(close) + 2, json.length));
    }

    function _pos(bytes memory json, bytes memory needle) internal pure returns (uint256) {
        int256 at = CardTestKit.indexOf(json, needle, 0);
        require(at >= 0, string(abi.encodePacked("missing ", needle)));
        return uint256(at);
    }

    /// `impl`'s runtime with its `__self` immutable zeroed, after checking both
    /// references hold `impl` itself.
    function _maskedModular(address impl) internal view returns (bytes memory code) {
        code = impl.code;
        uint256[2] memory refs = [SELF_REF_0, SELF_REF_1];
        for (uint256 i; i < 2; ++i) {
            uint256 at = refs[i];
            bytes32 word;
            assembly { word := mload(add(add(code, 32), at)) }
            assertEq(word, bytes32(uint256(uint160(impl))), "the __self immutable holds the implementation's own address");
            assembly { mstore(add(add(code, 32), at), 0) }
        }
    }

    // ------------------------------------------------------------ the live world

    function test_TheLiveProxy_RunsThisRepos_ModularBuild_AndV1Renderer() public {
        if (!_atPinnedBlock(MODULAR_LIVE_SUITES_BLOCK)) return;
        assertGt(block.number, PINNED_AFTER_BLOCK, "fork after the last modular-deployment tx");
        assertEq(_implementation(), MODULAR_IMPLEMENTATION, "the proxy runs the modular implementation 0x29Da");
        // The artifact's runtime carries zeros where the immutable goes: the same mask.
        bytes memory live = _maskedModular(MODULAR_IMPLEMENTATION);
        // RE-ANCHORED (bundle-non-transferable-sep26): this repo's NewTradeBundle
        // source has moved on (non-transferable), so the live 0x29Da is pinned to
        // the masked sha256 of its OWN build (commit 8fd3437) from the deployment
        // report, base-mainnet-2026-09-25-bundle-image-modular-upgrade.md.
        assertEq(
            sha256(live),
            0x0ab1372d5e6ca3e59d1a45459188f6bd105b61725e5d69df9fe855efdc9b97d1,
            "0x29Da is the 8fd3437 modular build (masked runtime sha256 from the deployment report)"
        );
    }

    function test_TheLiveSettings_OwnedByTheDeployer() public {
        if (!_atPinnedBlock(MODULAR_LIVE_SUITES_BLOCK)) return;
        address owner = _liveOwner();
        assertEq(bundle.pendingOwner(), address(0), "no transfer pending");
        assertEq(owner.code.length, 0, "the owner is an EOA");
        assertEq(bundle.imageRenderer(), IMAGE_RENDERER_V1, "renderer");
        assertEq(bundle.imageBaseURI(), "", "no image base");
        assertEq(bundle.externalBaseURI(), EXTERNAL_BASE, "the claim base");
        assertTrue(bundle.supportsInterface(0x49064906), "ERC-4906 announced");
    }

    function test_TheLiveTokenURI_KeysInOrder_TheRenderersImage_TheClaimUrl_AndTheOldJson() public {
        if (!_atPinnedBlock(MODULAR_LIVE_SUITES_BLOCK)) return;
        bytes memory json = CardTestKit.jsonOf(bundle.tokenURI(BUNDLE));
        vm.parseJson(string(json));
        uint256[6] memory at = [
            _pos(json, '"name":'),
            _pos(json, '"description":'),
            _pos(json, '"image":'),
            _pos(json, '"external_url":'),
            _pos(json, '"attributes":'),
            _pos(json, '"properties":')
        ];
        for (uint256 i = 1; i < 6; ++i) assertGt(at[i], at[i - 1], "keys in order name, description, image, external_url, attributes, properties");

        (bytes memory withoutImage, bytes memory image) = _cut(json, "image");
        (bytes memory rest, bytes memory externalUrl) = _cut(withoutImage, "external_url");
        assertEq(externalUrl, bytes(string.concat(EXTERNAL_BASE, "3")), "external_url = base + 3");
        assertEq(image, bytes(INewTradeBundleImage(IMAGE_RENDERER_V1).imageURI(BUNDLE, NFT, NFT_ID)), "the image is the renderer's answer");
        assertEq(rest, bytes(FIXTURE_JSON), "every other byte is the pre-image JSON (block 51,774,972)");
    }

    function test_TheWiring_RoyaltyAndStorage_AreThoseBeforeTheUpgrade() public {
        if (!_atPinnedBlock(MODULAR_LIVE_SUITES_BLOCK)) return;
        Observed memory live = _observe();
        Observed memory before = _observedAt(BEFORE_UPGRADE_BLOCK);
        assertEq(live.controller, before.controller, "controller");
        assertEq(live.seaport, before.seaport, "seaport");
        assertEq(live.validator, before.validator, "transfer validator");
        assertEq(live.royaltyTo, before.royaltyTo, "royalty recipient");
        assertEq(live.royaltyAmount, before.royaltyAmount, "royalty amount");
        assertEq(keccak256(abi.encode(live)), keccak256(abi.encode(before)), "all 19 observed facts, incl. raw slots 0-4 and the OZ namespaces");
    }

    // ------------------------------------------------------------ upgrade authority

    function test_TheOwnerReUpgradingToTheSameImplementation_ChangesNothingObservable() public {
        if (!_atPinnedBlock(MODULAR_LIVE_SUITES_BLOCK)) return;
        string memory uriBefore = bundle.tokenURI(BUNDLE);
        Observed memory beforeUpgrade = _observe();
        bytes32[4] memory probesBefore = _probes();

        _asOwner();
        bundle.upgradeToAndCall(MODULAR_IMPLEMENTATION, "");

        assertEq(_implementation(), MODULAR_IMPLEMENTATION);
        assertEq(bundle.tokenURI(BUNDLE), uriBefore, "tokenURI(3) byte-identical");
        assertEq(keccak256(abi.encode(_observe())), keccak256(abi.encode(beforeUpgrade)), "the 19 observed facts");
        bytes32[4] memory probesAfter = _probes();
        for (uint256 i; i < 4; ++i) assertEq(probesAfter[i], probesBefore[i], "transfer / mint / burn outcome unchanged");
        assertEq(bundle.imageRenderer(), IMAGE_RENDERER_V1);
        assertEq(bundle.externalBaseURI(), EXTERNAL_BASE);
    }

    function test_OnlyTheOwnerCanUpgradeOrChangeTheImage() public {
        if (!_atPinnedBlock(MODULAR_LIVE_SUITES_BLOCK)) return;
        address[3] memory others = [address(0x5713), ESCROW, PREVIOUS_OWNER];
        for (uint256 i; i < 3; ++i) {
            vm.startPrank(others[i]);
            vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, others[i]));
            bundle.upgradeToAndCall(CARD_IMPLEMENTATION, "");
            vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, others[i]));
            bundle.setImageRenderer(address(0));
            vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, others[i]));
            bundle.setImageBaseURI("https://example.invalid/");
            vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, others[i]));
            bundle.setExternalBaseURI("");
            vm.stopPrank();
        }
        assertEq(_implementation(), MODULAR_IMPLEMENTATION);
        assertEq(bundle.imageRenderer(), IMAGE_RENDERER_V1);
        assertEq(bundle.externalBaseURI(), EXTERNAL_BASE);
    }

    // ------------------------------------------------------------ rollbacks (fork-only rehearsals)

    function test_RollbackOfTheSettings_StepByStep_RestoresWhatBaseServedBefore() public {
        if (!_atPinnedBlock(MODULAR_LIVE_SUITES_BLOCK)) return;
        string memory beforeExternal = _tokenUriAt(BEFORE_EXTERNAL_BASE_BLOCK);
        string memory beforeUpgrade = _tokenUriAt(BEFORE_UPGRADE_BLOCK);

        _asOwner();
        bundle.setExternalBaseURI("");
        assertEq(bundle.tokenURI(BUNDLE), beforeExternal, "no external_url: what Base served at block 51,798,717");
        assertFalse(CardTestKit.contains(CardTestKit.jsonOf(bundle.tokenURI(BUNDLE)), '"external_url"'));

        _asOwner();
        bundle.setImageRenderer(address(0));
        assertEq(bundle.tokenURI(BUNDLE), beforeUpgrade, "the built-in card: what the card implementation served at block 51,798,690");
    }

    function test_RollbackTo9Cc1_RestoresTheCardJson_AndUpgradingForwardRestoresTodays() public {
        if (!_atPinnedBlock(MODULAR_LIVE_SUITES_BLOCK)) return;
        string memory today = bundle.tokenURI(BUNDLE);
        string memory beforeUpgrade = _tokenUriAt(BEFORE_UPGRADE_BLOCK);

        _asOwner();
        bundle.upgradeToAndCall(CARD_IMPLEMENTATION, "");
        assertEq(_implementation(), CARD_IMPLEMENTATION);
        assertEq(bundle.tokenURI(BUNDLE), beforeUpgrade, "rolled back: the card JSON of block 51,798,690, no external_url");
        assertFalse(CardTestKit.contains(CardTestKit.jsonOf(bundle.tokenURI(BUNDLE)), '"external_url"'));

        _asOwner();
        bundle.upgradeToAndCall(MODULAR_IMPLEMENTATION, "");
        assertEq(bundle.tokenURI(BUNDLE), today, "forward again: today's JSON");
        assertEq(bundle.imageRenderer(), IMAGE_RENDERER_V1, "the settings waited in their namespace");
        assertEq(bundle.imageBaseURI(), "");
        assertEq(bundle.externalBaseURI(), EXTERNAL_BASE);
    }
}
