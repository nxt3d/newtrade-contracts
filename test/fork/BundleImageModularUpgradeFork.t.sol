// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {BundleForkBase} from "./BundleForkBase.sol";
import {CardTestKit} from "../helpers/BundleCardHelpers.sol";
import {
    FixedRenderer,
    RevertingRenderer,
    GasBurningRenderer,
    ReturndataBombRenderer
} from "../BundleImageModular.t.sol";

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
 * The LIVE Base Bundle NFT upgraded, IN A FORK ONLY, from the card implementation
 * 0x9Cc1…0207 to the MODULAR image implementation (bundle-image-modular-upgrade-sep25).
 *
 * WHAT THIS PROVES, on the real proxy with the owner READ LIVE (== 0xF8e0):
 *  - the upgrade alone changes nothing: tokenURI(3) is byte-identical, and the
 *    19 observed facts and the 4 transfer/mint/burn outcomes are identical;
 *  - (a FixedRenderer stands in for the configured renderer 0x4519…56c5, whose source is not included)
 *  - installing a renderer changes ONLY the image (the rest of the JSON
 *    is the pre-image fixture) and emits ImageRendererSet + ERC-4906;
 *  - an image base URL wins over the renderer (`…/img/3`); an external base URL
 *    adds `"external_url": …/claim/8453/3` right after the image; clearing each
 *    restores the live tokenURI byte for byte; every setter emits its event and
 *    ERC-4906;
 *  - only the owner can change any of the three settings (0xc3F9, the escrow, a
 *    stranger revert);
 *  - hostile renderers (revert, empty, 64 KiB, JSON injection, endless loop,
 *    a control byte, an EOA) all fall back to EXACTLY today's live tokenURI;
 *  - any scheme is served: an ipfs:// image base and an ar:// external base
 *    appear as set;
 *  - the rollback to 0x9Cc1… restores today's tokenURI exactly.
 *
 * WHAT IT DOES NOT PROVE: nothing is broadcast. The owner is IMPERSONATED.
 *
 * RUN (read-only; the URL comes from YOUR environment, never from the repo):
 *   forge test --match-contract BundleImageModularUpgradeForkTest \
 *     --fork-url "$RPC_8453" --fork-block-number 51785106
 * Without a fork every test returns early: a run WITHOUT a URL proves nothing.
 */
contract BundleImageModularUpgradeForkTest is BundleForkBase {
    address constant NFT = 0xf4fd1a2Ea84a16Be24848Aa6f4242E9CAab18953;

    /// A known JSON-safe answer standing in for the configured renderer (its source is not in this variant).
    string constant FIXED_RENDERER_URI = "ipfs://bafy-fixed-renderer/bundle";

    event ImageRendererSet(address indexed previousRenderer, address indexed newRenderer);
    event ImageBaseURISet(string previousBaseURI, string newBaseURI);
    event ExternalBaseURISet(string previousBaseURI, string newBaseURI);
    event BatchMetadataUpdate(uint256 _fromTokenId, uint256 _toTokenId);

    /// The owner, read live, upgrades to a fresh deployment of this repo's artifact.
    function _upgrade() internal returns (address impl) {
        assertEq(_implementation(), CARD_IMPLEMENTATION, "starts from the live card implementation");
        impl = deployCode(ARTIFACT);
        vm.prank(_liveOwner());
        bundle.upgradeToAndCall(impl, "");
        assertEq(_implementation(), impl);
    }

    function _asOwner() internal {
        vm.prank(_liveOwner());
    }

    /// (the JSON with exactly `"image":"…",` removed, the image value).
    function _split(string memory uri) internal pure returns (bytes memory without, bytes memory image) {
        bytes memory json = CardTestKit.jsonOf(uri);
        bytes memory key = '"image":"';
        int256 at = CardTestKit.indexOf(json, key, 0);
        require(at >= 0, "NO_IMAGE");
        require(CardTestKit.indexOf(json, '"image":', uint256(at) + 1) < 0, "TWO_IMAGES");
        uint256 start = uint256(at) + key.length;
        int256 close = CardTestKit.indexOf(json, '",', start);
        require(close >= 0, "UNCLOSED");
        image = CardTestKit.slice(json, start, uint256(close));
        without = abi.encodePacked(CardTestKit.slice(json, 0, uint256(at)), CardTestKit.slice(json, uint256(close) + 2, json.length));
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

    function test_TheUpgradeAlone_ChangesNothingObservable() public {
        if (!_atPinnedBlock(CARD_SUITES_BLOCK)) return;
        string memory liveUri = bundle.tokenURI(BUNDLE);
        Observed memory beforeUpgrade = _observe();
        bytes32[4] memory probesBefore = _probes();
        assertFalse(bundle.supportsInterface(0x49064906), "the live implementation does not announce ERC-4906");

        _upgrade();

        assertEq(CardTestKit.jsonOf(bundle.tokenURI(BUNDLE)), _withNonTransferable(CardTestKit.jsonOf(liveUri)), "tokenURI(3) byte-identical but for the non-transferable insertions: no renderer -> the same card");
        assertEq(bundle.imageRenderer(), address(0));
        assertEq(bundle.imageBaseURI(), "");
        assertEq(bundle.externalBaseURI(), "");
        // The zero-royalty source quotes (0, 0): only the royalty quote may change (see _withZeroRoyalty).
        Observed memory afterUpgrade = _observe();
        assertGt(beforeUpgrade.royaltyAmount, 0, "the historical world quoted a royalty");
        assertEq(afterUpgrade.royaltyAmount, 0, "this source quotes a zero royalty");
        assertEq(keccak256(abi.encode(afterUpgrade)), keccak256(abi.encode(_withZeroRoyalty(beforeUpgrade))), "the 19 observed facts, but for the zero royalty quote");
        bytes32[4] memory probesAfter = _probes();
        for (uint256 i; i < 4; ++i) assertEq(probesAfter[i], probesBefore[i], "transfer / mint / burn outcome unchanged");
        assertTrue(bundle.supportsInterface(0x49064906), "ERC-4906 announced");
    }

    function test_InstallingARenderer_ChangesOnlyTheImage() public {
        if (!_atPinnedBlock(CARD_SUITES_BLOCK)) return;
        _upgrade();
        Observed memory beforeSet = _observe();
        address renderer = address(new FixedRenderer(FIXED_RENDERER_URI));

        vm.expectEmit(PROXY);
        emit ImageRendererSet(address(0), renderer);
        vm.expectEmit(PROXY);
        emit BatchMetadataUpdate(0, type(uint256).max);
        _asOwner();
        bundle.setImageRenderer(renderer);

        (bytes memory without, bytes memory image) = _split(bundle.tokenURI(BUNDLE));
        assertEq(without, _withNonTransferable(bytes(FIXTURE_JSON)), "every byte but the image is the pre-image JSON (+ the non-transferable insertions)");
        assertEq(image, bytes(FIXED_RENDERER_URI), "the renderer's image");
        vm.parseJson(string(CardTestKit.jsonOf(bundle.tokenURI(BUNDLE))));
        assertEq(keccak256(abi.encode(_observe())), keccak256(abi.encode(beforeSet)), "nothing else moved");
    }

    function test_ImageBaseURI_SetWinsOverTheRenderer_ClearedRestoresTheLiveTokenURI() public {
        if (!_atPinnedBlock(CARD_SUITES_BLOCK)) return;
        string memory liveUri = bundle.tokenURI(BUNDLE);
        _upgrade();
        address v1 = address(new FixedRenderer(FIXED_RENDERER_URI)); // deploy BEFORE the prank: a nested call would consume it
        _asOwner();
        bundle.setImageRenderer(v1);

        vm.expectEmit(PROXY);
        emit ImageBaseURISet("", "https://example.invalid/img/");
        vm.expectEmit(PROXY);
        emit BatchMetadataUpdate(0, type(uint256).max);
        _asOwner();
        bundle.setImageBaseURI("https://example.invalid/img/");
        (bytes memory without, bytes memory image) = _split(bundle.tokenURI(BUNDLE));
        assertEq(image, bytes("https://example.invalid/img/3"));
        assertEq(without, _withNonTransferable(bytes(FIXTURE_JSON)), "every byte but the image is the pre-image JSON (+ the non-transferable insertions)");

        vm.expectEmit(PROXY);
        emit ImageBaseURISet("https://example.invalid/img/", "");
        vm.expectEmit(PROXY);
        emit BatchMetadataUpdate(0, type(uint256).max);
        _asOwner();
        bundle.setImageBaseURI("");
        (, image) = _split(bundle.tokenURI(BUNDLE));
        assertEq(image, bytes(FIXED_RENDERER_URI), "base cleared: the renderer again");
        _asOwner();
        bundle.setImageRenderer(address(0));
        assertEq(CardTestKit.jsonOf(bundle.tokenURI(BUNDLE)), _withNonTransferable(CardTestKit.jsonOf(liveUri)), "renderer removed too: today's tokenURI (+ the non-transferable insertions)");
    }

    function test_ExternalBaseURI_AddsTheKeyAfterTheImage_ClearedRestoresTheLiveTokenURI() public {
        if (!_atPinnedBlock(CARD_SUITES_BLOCK)) return;
        string memory liveUri = bundle.tokenURI(BUNDLE);
        _upgrade();
        string memory claim = "https://newtrade-app.vercel.app/claim/8453/";

        vm.expectEmit(PROXY);
        emit ExternalBaseURISet("", claim);
        vm.expectEmit(PROXY);
        emit BatchMetadataUpdate(0, type(uint256).max);
        _asOwner();
        bundle.setExternalBaseURI(claim);
        bytes memory json = CardTestKit.jsonOf(bundle.tokenURI(BUNDLE));
        bytes memory key = '"external_url":"https://newtrade-app.vercel.app/claim/8453/3",';
        int256 at = CardTestKit.indexOf(json, key, 0);
        assertGt(at, 0, "external_url = base + 3");
        assertEq(CardTestKit.slice(json, uint256(at) + key.length, uint256(at) + key.length + 14), bytes('"attributes":['), "right after the image");
        bytes memory without = abi.encodePacked(CardTestKit.slice(json, 0, uint256(at)), CardTestKit.slice(json, uint256(at) + key.length, json.length));
        assertEq(without, _withNonTransferable(CardTestKit.jsonOf(liveUri)), "the JSON minus the key is today's JSON (+ the non-transferable insertions)");
        vm.parseJson(string(json));

        vm.expectEmit(PROXY);
        emit ExternalBaseURISet(claim, "");
        vm.expectEmit(PROXY);
        emit BatchMetadataUpdate(0, type(uint256).max);
        _asOwner();
        bundle.setExternalBaseURI("");
        assertEq(CardTestKit.jsonOf(bundle.tokenURI(BUNDLE)), _withNonTransferable(CardTestKit.jsonOf(liveUri)), "cleared: today's tokenURI (+ the non-transferable insertions)");
    }

    function test_AnyScheme_IpfsImageBase_ArExternalBase_AreServed() public {
        if (!_atPinnedBlock(CARD_SUITES_BLOCK)) return;
        string memory liveUri = bundle.tokenURI(BUNDLE);
        _upgrade();
        _asOwner();
        bundle.setImageBaseURI("ipfs://bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi/");
        _asOwner();
        bundle.setExternalBaseURI("ar://Qm-Arweave-TxId_0123456789abcdef/");
        bytes memory json = CardTestKit.jsonOf(bundle.tokenURI(BUNDLE));
        bytes memory keys = '"image":"ipfs://bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi/3","external_url":"ar://Qm-Arweave-TxId_0123456789abcdef/3",';
        int256 at = CardTestKit.indexOf(json, keys, 0);
        assertGt(at, 0);
        vm.parseJson(string(json));
        _asOwner();
        bundle.setImageBaseURI("");
        _asOwner();
        bundle.setExternalBaseURI("");
        assertEq(CardTestKit.jsonOf(bundle.tokenURI(BUNDLE)), _withNonTransferable(CardTestKit.jsonOf(liveUri)), "both cleared: today's tokenURI (+ the non-transferable insertions)");
    }

    function test_OnlyTheOwnerSetsTheImage() public {
        if (!_atPinnedBlock(CARD_SUITES_BLOCK)) return;
        _upgrade();
        address[3] memory others = [address(0x5713), ESCROW, PREVIOUS_OWNER];
        for (uint256 i; i < 3; ++i) {
            vm.startPrank(others[i]);
            vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, others[i]));
            bundle.setImageRenderer(address(1));
            vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, others[i]));
            bundle.setImageBaseURI("https://example.invalid/");
            vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, others[i]));
            bundle.setExternalBaseURI("https://example.invalid/");
            vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, others[i]));
            bundle.upgradeToAndCall(CARD_IMPLEMENTATION, "");
            vm.stopPrank();
        }
        assertEq(bundle.imageRenderer(), address(0));
    }

    function test_HostileRenderers_FallBackToExactlyTodaysTokenURI() public {
        if (!_atPinnedBlock(CARD_SUITES_BLOCK)) return;
        string memory liveUri = bundle.tokenURI(BUNDLE);
        _upgrade();
        address[7] memory hostile = [
            address(new RevertingRenderer()),
            address(new FixedRenderer("")),
            address(new ReturndataBombRenderer(65_536)),
            address(new FixedRenderer('data:x","name":"pwned')),
            address(new GasBurningRenderer()),
            address(new FixedRenderer("ipfs://x\n")), // a control byte (any scheme is fine; JSON safety is not)
            address(0xE0A) // an EOA
        ];
        for (uint256 i; i < hostile.length; ++i) {
            _asOwner();
            bundle.setImageRenderer(hostile[i]);
            uint256 g0 = gasleft();
            string memory uri = bundle.tokenURI(BUNDLE);
            assertLt(g0 - gasleft(), bundle.IMAGE_GAS() + 1_000_000, "bounded");
            assertEq(CardTestKit.jsonOf(uri), _withNonTransferable(CardTestKit.jsonOf(liveUri)), "a hostile renderer yields today's tokenURI exactly (+ the non-transferable insertions)");
        }
    }

    function test_RollbackTo9Cc1_RestoresTodaysTokenURI_AndTheConfigWaitsInItsNamespace() public {
        if (!_atPinnedBlock(CARD_SUITES_BLOCK)) return;
        string memory liveUri = bundle.tokenURI(BUNDLE);
        _upgrade();
        address renderer = address(new FixedRenderer(FIXED_RENDERER_URI));
        _asOwner();
        bundle.setImageRenderer(renderer);
        _asOwner();
        bundle.setExternalBaseURI("https://newtrade-app.vercel.app/claim/8453/");
        assertTrue(keccak256(bytes(bundle.tokenURI(BUNDLE))) != keccak256(bytes(liveUri)));

        _asOwner();
        bundle.upgradeToAndCall(CARD_IMPLEMENTATION, "");
        assertEq(_implementation(), CARD_IMPLEMENTATION);
        assertEq(bundle.tokenURI(BUNDLE), liveUri, "rolled back: today's tokenURI exactly (0x9Cc1 ignores the namespace)");

        // Upgrading forward again finds the renderer where it was left.
        address impl = deployCode(ARTIFACT);
        _asOwner();
        bundle.upgradeToAndCall(impl, "");
        assertEq(bundle.imageRenderer(), renderer, "the ERC-7201 config survives a round trip");
        assertEq(bundle.externalBaseURI(), "https://newtrade-app.vercel.app/claim/8453/");
    }
}
