// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {NewTradeBundle} from "../src/NewTradeBundle.sol";
import {NewTradeBundleCard} from "../src/NewTradeBundleCard.sol";
import {BundleImageURI} from "../src/BundleImageURI.sol";
import {INewTradeBundleImage} from "../src/interfaces/INewTradeBundleImage.sol";
import {BundleDeploy} from "./helpers/BundleDeploy.sol";
import {CardTestKit, LegacyBundleJson} from "./helpers/BundleCardHelpers.sol";
import {CardController, CardValidator} from "./BundleCard.t.sol";

// ------------------------------------------------------------ renderers

/// Answers a fixed string, exactly as a well-behaved renderer would.
contract FixedRenderer is INewTradeBundleImage {
    string internal answer;

    constructor(string memory answer_) {
        answer = answer_;
    }

    function imageURI(uint256, address, uint256) external view returns (string memory) {
        return answer;
    }
}

contract RevertingRenderer {
    function imageURI(uint256, address, uint256) external pure returns (string memory) {
        revert("no image");
    }
}

/// Spins until the stipend runs out.
contract GasBurningRenderer {
    function imageURI(uint256, address, uint256) external view returns (string memory) {
        uint256 i;
        while (gasleft() > 0) ++i;
        return "data:never";
    }
}

/// Answers `size` raw bytes (a returndata bomb when large).
contract RawRenderer {
    bytes internal raw;

    constructor(bytes memory raw_) {
        raw = raw_;
    }

    fallback() external {
        bytes memory r = raw;
        assembly {
            return(add(r, 32), mload(r))
        }
    }
}

/// Answers `size` zero bytes without storing them.
contract ReturndataBombRenderer {
    uint256 internal immutable size;

    constructor(uint256 size_) {
        size = size_;
    }

    fallback() external {
        uint256 n = size;
        assembly {
            return(0, n)
        }
    }
}

/// Tries to write state: a staticcall makes that revert.
contract StateWritingRenderer {
    uint256 public calls;

    function imageURI(uint256, address, uint256) external returns (string memory) {
        ++calls;
        return "data:image/png;base64,AAAA";
    }
}

/// Calls back into the Bundle NFT's tokenURI (recursion is bounded by the stipend).
contract ReentrantRenderer {
    NewTradeBundle internal immutable bundle;

    constructor(NewTradeBundle bundle_) {
        bundle = bundle_;
    }

    function imageURI(uint256 id, address, uint256) external view returns (string memory) {
        bundle.tokenURI(id);
        return "https://reentered.invalid/x";
    }
}

/// Exposes the URI rules and the graphics to tests.
contract ImageHarness {
    function isAccepted(bytes memory uri) external pure returns (bool) {
        return BundleImageURI.isAccepted(uri);
    }

    function isJsonSafe(bytes memory s) external pure returns (bool) {
        return BundleImageURI.isJsonSafe(s);
    }

    function card(uint256 id, address nft, uint256 nftId, uint8 graphic) external pure returns (bytes memory) {
        require(graphic == 0, "variant B ships no graphics library");
        return NewTradeBundleCard.svgWith(id, nft, nftId, "");
    }
}

/**
 * bundle-image-modular-upgrade-sep25: the Bundle NFT's image is MODULAR. The
 * JSON stays on chain. The image is `imageBaseURI + id` if set, else the owner-set
 * renderer's URI (V1: an on-chain SVG), else the built-in card - which is also
 * the fallback for ANY unusable answer, so `tokenURI` cannot break. An optional
 * `external_url` (externalBaseURI + id) is ABSENT until set. The rest of the
 * JSON never changes.
 */
contract BundleImageModularTest is Test {
    NewTradeBundle bundle;
    CardController controller;
    ImageHarness harness;

    address constant NFT = 0xf4fd1a2Ea84a16Be24848Aa6f4242E9CAab18953;
    bytes32 constant MANIFEST = 0xbdd635db3c38b33ba593a6c357dd902125c8c579fb970f5845636bda8d5f9d6a;
    bytes32 constant IMAGE_SLOT = 0x92e9f748b197c8df37e6f357621b4b56a147841660aafbfb660fb6e6ea2d0d00;
    bytes constant CARD_PREFIX = "data:image/svg+xml;base64,";

    event ImageRendererSet(address indexed previousRenderer, address indexed newRenderer);
    event ImageBaseURISet(string previousBaseURI, string newBaseURI);
    event ExternalBaseURISet(string previousBaseURI, string newBaseURI);
    event BatchMetadataUpdate(uint256 _fromTokenId, uint256 _toTokenId);

    function setUp() public {
        controller = new CardController();
        bundle = BundleDeploy.deploy(address(this), address(0x5EA), address(new CardValidator()), address(this));
        bundle.bindController(address(controller));
        harness = new ImageHarness();
        controller.set(3, NFT, 104, MANIFEST);
        controller.mint(bundle, 3);
    }

    // ------------------------------------------------------------ helpers

    /// (the JSON with exactly `"image":"…",` removed, the image value). Requires exactly one image key.
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

    function _image() internal view returns (bytes memory image) {
        (, image) = _split(bundle.tokenURI(3));
    }

    function _card() internal pure returns (bytes memory) {
        return abi.encodePacked(CARD_PREFIX, Base64.encode(NewTradeBundleCard.svg(3, NFT, 104)));
    }

    function _assertCard(string memory why) internal view {
        assertEq(_image(), _card(), why);
    }

    function _useRenderer(address r) internal {
        bundle.setImageRenderer(r);
    }

    // ------------------------------------------------------------ defaults

    function test_Default_NoRenderer_IsTheBuiltInCard_ByteIdentical() public view {
        assertEq(bundle.imageRenderer(), address(0));
        assertEq(bundle.imageBaseURI(), "");
        assertEq(bundle.externalBaseURI(), "");
        (bytes memory without, bytes memory image) = _split(bundle.tokenURI(3));
        // The image is the card-only implementation's image, byte for byte...
        assertEq(image, _card());
        // ...and the rest is the pre-image JSON (the verbatim 4c202bc builder) plus
        // exactly the non-transferable sentence and attribute (bundle-non-transferable-sep26).
        assertEq(without, LegacyBundleJson.jsonNonTransferable(3, block.chainid, NFT, 104, MANIFEST, address(bundle)));
    }

    function test_TheCardIsSvgWithAnEmptyGraphic() public view {
        assertEq(harness.card(3, NFT, 104, 0), NewTradeBundleCard.svg(3, NFT, 104));
    }

    // ------------------------------------------------------------ the V1 renderer

    // ------------------------------------------------------------ the image base URL

    function test_ImageBaseURI_IsBaseAndId_AndWinsOverTheRenderer() public {
        _useRenderer(address(new FixedRenderer("ipfs://fixed-renderer")));
        (bytes memory withoutBefore, bytes memory rendered) = _split(bundle.tokenURI(3));
        bundle.setImageBaseURI("https://example.invalid/img/");
        assertEq(bundle.imageBaseURI(), "https://example.invalid/img/");
        (bytes memory without, bytes memory image) = _split(bundle.tokenURI(3));
        assertEq(image, bytes("https://example.invalid/img/3"));
        assertEq(without, withoutBefore, "only the image changed");
        // Cleared: back to the renderer; renderer cleared: back to the card.
        bundle.setImageBaseURI("");
        assertEq(_image(), rendered, "base cleared: the renderer again");
        _useRenderer(address(0));
        _assertCard("both cleared: the built-in card");
    }

    function test_ImageBaseURI_WithoutARenderer_AndClearedIsTheCard() public {
        bundle.setImageBaseURI("https://example.invalid/img/");
        assertEq(_image(), bytes("https://example.invalid/img/3"));
        bundle.setImageBaseURI("");
        _assertCard("cleared, no renderer: the built-in card");
    }

    // ------------------------------------------------------------ external_url

    function test_ExternalUrl_AbsentUntilSet_ThenRightAfterTheImage_ThenAbsentAgain() public {
        string memory before = bundle.tokenURI(3);
        assertFalse(CardTestKit.contains(CardTestKit.jsonOf(before), '"external_url"'), "no key while unset");

        bundle.setExternalBaseURI("https://newtrade-app.vercel.app/claim/8453/");
        assertEq(bundle.externalBaseURI(), "https://newtrade-app.vercel.app/claim/8453/");
        bytes memory json = CardTestKit.jsonOf(bundle.tokenURI(3));
        bytes memory key = '"external_url":"https://newtrade-app.vercel.app/claim/8453/3",';
        int256 at = CardTestKit.indexOf(json, key, 0);
        assertGt(at, 0, "the key, with base + id");
        assertTrue(CardTestKit.indexOf(json, '"external_url"', uint256(at) + 1) < 0, "exactly once");
        // Right after the image, right before the attributes; nothing else moved.
        assertEq(CardTestKit.slice(json, uint256(at) + key.length, uint256(at) + key.length + 14), bytes('"attributes":['));
        bytes memory without = abi.encodePacked(CardTestKit.slice(json, 0, uint256(at)), CardTestKit.slice(json, uint256(at) + key.length, json.length));
        assertEq(without, CardTestKit.jsonOf(before), "the JSON minus the key is exactly the JSON before");
        vm.parseJson(string(json));

        bundle.setExternalBaseURI("");
        assertEq(bundle.tokenURI(3), before, "cleared: byte-identical to before");
    }

    function test_ExternalUrl_WithARendererAndAnImageBase_AllCompose() public {
        _useRenderer(address(new FixedRenderer("ipfs://fixed-renderer")));
        bundle.setImageBaseURI("https://example.invalid/img/");
        bundle.setExternalBaseURI("https://example.invalid/claim/");
        bytes memory json = CardTestKit.jsonOf(bundle.tokenURI(3));
        assertTrue(CardTestKit.contains(json, '"image":"https://example.invalid/img/3","external_url":"https://example.invalid/claim/3","attributes":['));
        vm.parseJson(string(json));
    }

    // ------------------------------------------------------------ base URL validation

    function test_BaseURIs_RejectedAtSetTime() public {
        // JSON safety and length are the rules; the scheme is free (see the next test).
        string[7] memory bad = [
            "https://a\"b/",
            "https://a\\b/",
            "https://a\nb/",
            "ipfs://a\tb/",
            "ar://a\x7fb/",
            "https://caf\xc3\xa9/",
            "\x00"
        ];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(NewTradeBundle.InvalidBaseURI.selector);
            bundle.setImageBaseURI(bad[i]);
            vm.expectRevert(NewTradeBundle.InvalidBaseURI.selector);
            bundle.setExternalBaseURI(bad[i]);
        }
        bytes memory max = new bytes(256);
        for (uint256 i; i < 256; ++i) max[i] = "a";
        for (uint256 i; i < 8; ++i) max[i] = bytes("https://")[i];
        bundle.setImageBaseURI(string(max));
        bundle.setExternalBaseURI(string(max));
        vm.expectRevert(NewTradeBundle.InvalidBaseURI.selector);
        bundle.setImageBaseURI(string(abi.encodePacked(max, "a")));
        vm.expectRevert(NewTradeBundle.InvalidBaseURI.selector);
        bundle.setExternalBaseURI(string(abi.encodePacked(max, "a")));
    }

    function test_AnyScheme_ForBothBases_IsAcceptedAndServed() public {
        // ipfs:// and ar:// (and any other scheme) are served as set: the rule is
        // valid JSON, not a scheme allowlist (user decision).
        bundle.setImageBaseURI("ipfs://bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi/");
        bundle.setExternalBaseURI("ar://Qm-Arweave-TxId_0123456789abcdef/");
        bytes memory json = CardTestKit.jsonOf(bundle.tokenURI(3));
        assertTrue(CardTestKit.contains(json, '"image":"ipfs://bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi/3","external_url":"ar://Qm-Arweave-TxId_0123456789abcdef/3","attributes":['));
        vm.parseJson(string(json));

        // http:, data: and upper-case schemes too.
        bundle.setImageBaseURI("http://example.invalid/img/");
        assertEq(_image(), bytes("http://example.invalid/img/3"));
        bundle.setImageBaseURI("HTTPS://example.invalid/img/");
        assertEq(_image(), bytes("HTTPS://example.invalid/img/3"));

        // A scheme-less string passes as well: the contract guarantees the JSON is
        // valid, not that the value resolves. A relative path is the owner's
        // choice, and what a marketplace makes of it is the marketplace's.
        bundle.setImageBaseURI("img/");
        bundle.setExternalBaseURI("bundles/");
        json = CardTestKit.jsonOf(bundle.tokenURI(3));
        assertTrue(CardTestKit.contains(json, '"image":"img/3","external_url":"bundles/3","attributes":['));
        vm.parseJson(string(json));
    }

    /// A short string (< 32 bytes) sits in one slot: its bytes | length * 2.
    function _storeShortString(bytes32 slot, bytes memory s) internal {
        require(s.length < 32);
        vm.store(address(bundle), slot, bytes32(s) | bytes32(s.length * 2));
    }

    function test_BaseURIs_RenderTimeCheck_IsDefenceInDepth() public {
        // Unsafe bases written straight into the namespace (no setter accepts them).
        string memory before = bundle.tokenURI(3);
        _storeShortString(bytes32(uint256(IMAGE_SLOT) + 1), 'https://a"b/');
        _storeShortString(bytes32(uint256(IMAGE_SLOT) + 2), 'https://a"b/');
        assertEq(bundle.imageBaseURI(), 'https://a"b/');
        assertEq(bundle.externalBaseURI(), 'https://a"b/');
        assertEq(bundle.tokenURI(3), before, "the card, and no external_url: byte-identical to unset");
        vm.parseJson(string(CardTestKit.jsonOf(bundle.tokenURI(3))));
    }

    // ------------------------------------------------------------ hostile renderers

    function test_Hostile_Reverts() public {
        _useRenderer(address(new RevertingRenderer()));
        _assertCard("revert -> card");
    }

    function test_Hostile_EmptyAnswer() public {
        _useRenderer(address(new FixedRenderer("")));
        _assertCard("empty -> card");
    }

    function test_Hostile_EOA() public {
        _useRenderer(address(0xE0A));
        _assertCard("no code -> card");
    }

    function test_Hostile_Precompile() public {
        _useRenderer(address(4)); // identity: echoes the calldata, which is not an ABI string
        _assertCard("precompile -> card");
    }

    function test_Hostile_TooLong_AndTheExactLimit() public {
        bytes memory ok = new bytes(BundleImageURI.MAX_BYTES);
        for (uint256 i; i < ok.length; ++i) ok[i] = "A";
        for (uint256 i; i < 5; ++i) ok[i] = bytes("data:")[i];
        _useRenderer(address(new FixedRenderer(string(ok))));
        assertEq(_image(), ok, "exactly 16 KB is accepted");
        _useRenderer(address(new FixedRenderer(string(abi.encodePacked(ok, "A")))));
        _assertCard("16 KB + 1 -> card");
    }

    function test_Hostile_ReturndataBomb_IsSizedNotCopied() public {
        // 64 KiB: cheap for the renderer to answer (~15k gas of its own memory),
        // four times the cap. Refused on returndatasize alone, before any copy.
        _useRenderer(address(new ReturndataBombRenderer(65_536)));
        uint256 g0 = gasleft();
        string memory uri = bundle.tokenURI(3);
        uint256 used = g0 - gasleft();
        (, bytes memory image) = _split(uri);
        assertEq(image, _card(), "64 KiB answer -> card");
        console2.log("tokenURI gas with a 64 KiB answer", used);
        assertLt(used, 600_000, "card-level gas: the 64 KiB was never copied");
    }

    function test_Hostile_ReturndataBomb_700KB_TheBundleNeverPaysToCopyIt() public {
        // ~700 KB: the renderer can still afford it inside its stipend (~1M gas of
        // its own memory). Were it copied, the Bundle would pay that much AGAIN in
        // memory; sized first, it pays nothing beyond the stipend and the card.
        _useRenderer(address(new ReturndataBombRenderer(700_000)));
        uint256 g0 = gasleft();
        string memory uri = bundle.tokenURI(3);
        uint256 used = g0 - gasleft();
        (, bytes memory image) = _split(uri);
        assertEq(image, _card(), "700 KB answer -> card");
        console2.log("tokenURI gas with a 700 KB answer", used);
        assertLt(used, 1_600_000, "the renderer's own ~1M + the card; no second copy");
    }

    function test_Hostile_ReturndataBomb_1MiB_IsCutByTheStipend() public {
        // 1 MiB costs the RENDERER ~2.2M gas of memory: it runs out inside its stipend.
        _useRenderer(address(new ReturndataBombRenderer(1_048_576)));
        uint256 g0 = gasleft();
        string memory uri = bundle.tokenURI(3);
        uint256 used = g0 - gasleft();
        (, bytes memory image) = _split(uri);
        assertEq(image, _card(), "1 MiB answer -> card");
        console2.log("tokenURI gas with a 1 MiB answer", used);
        assertLt(used, bundle.IMAGE_GAS() + 500_000);
    }

    function test_Hostile_InjectionAndBadBytes() public {
        string[8] memory bad = [
            'data:x","name":"pwned',
            "data:x\\u0022",
            "data:x\n",
            "data:x\x00",
            "data:x\x7f",
            "data:caf\xc3\xa9",
            "https://x.invalid/\t",
            "data:\x1b[31m"
        ];
        for (uint256 i; i < bad.length; ++i) {
            _useRenderer(address(new FixedRenderer(bad[i])));
            _assertCard("unsafe byte -> card");
            vm.parseJson(string(CardTestKit.jsonOf(bundle.tokenURI(3))));
        }
    }

    function test_Renderer_AnyScheme_IsServed() public {
        // Any scheme a renderer answers is served as is (user decision): ipfs://,
        // ar://, http://, even a scheme-less or `javascript:` string - each is
        // valid JSON, and which schemes a consumer follows is the consumer's call.
        string[7] memory ok = [
            "ipfs://bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi/3.svg",
            "ar://Qm-Arweave-TxId_0123456789abcdef",
            "http://x.invalid/a.png",
            "https://x.invalid/a.png",
            "hello",
            " data:x",
            "javascript:alert(1)"
        ];
        for (uint256 i; i < ok.length; ++i) {
            _useRenderer(address(new FixedRenderer(ok[i])));
            assertEq(_image(), bytes(ok[i]), "served as answered");
            vm.parseJson(string(CardTestKit.jsonOf(bundle.tokenURI(3))));
        }
    }

    function test_Hostile_BurnsAllGas_IsCutAtTheStipend() public {
        _useRenderer(address(new GasBurningRenderer()));
        uint256 g0 = gasleft();
        string memory uri = bundle.tokenURI(3);
        uint256 used = g0 - gasleft();
        (, bytes memory image) = _split(uri);
        assertEq(image, _card(), "an endless loop -> card");
        console2.log("tokenURI gas with an endless-loop renderer", used);
        assertLt(used, bundle.IMAGE_GAS() + 500_000, "the stipend plus the card, no more");
        assertGt(used, bundle.IMAGE_GAS(), "and the stipend really was spent");
    }

    function test_Hostile_MalformedAbi() public {
        // offset 0x40 instead of 0x20, with a plausible length + bytes where 0x20 would put them:
        // only the offset check refuses it
        _useRenderer(address(new RawRenderer(abi.encode(uint256(0x40), uint256(7), bytes32("data:ok")))));
        _assertCard("bad offset -> card");
        // a length past the end of the return data
        _useRenderer(address(new RawRenderer(abi.encode(uint256(0x20), uint256(100), bytes32("data:")))));
        _assertCard("length overrun -> card");
        // too short to be a string at all
        _useRenderer(address(new RawRenderer(abi.encode(uint256(0x20)))));
        _assertCard("short -> card");
        // a well-formed answer through the raw path is accepted (the decoder is not just refusing everything)
        _useRenderer(address(new RawRenderer(abi.encode("data:ok"))));
        assertEq(_image(), bytes("data:ok"));
    }

    function test_Hostile_WritesState_ViaStaticcall_Reverts() public {
        StateWritingRenderer r = new StateWritingRenderer();
        _useRenderer(address(r));
        _assertCard("a state write under staticcall reverts -> card");
        assertEq(r.calls(), 0);
    }

    function test_Hostile_Reenters_IsBounded_AndFallsBack() public {
        _useRenderer(address(new ReentrantRenderer(bundle)));
        uint256 g0 = gasleft();
        string memory uri = bundle.tokenURI(3);
        uint256 used = g0 - gasleft();
        (, bytes memory image) = _split(uri);
        console2.log("tokenURI gas with a re-entering renderer", used);
        // The inner tokenURI hands ITS renderer call 63/64 of what is left, keeps
        // too little to finish, runs out, and the outer call falls back to the card.
        assertEq(image, _card(), "re-entry -> card");
        assertLt(used, bundle.IMAGE_GAS() + 500_000, "bounded by one stipend");
    }

    // ------------------------------------------------------------ the JSON-safety rule

    function test_IsJsonSafe() public view {
        assertTrue(harness.isJsonSafe(" !#$%&'()*+,-./09:;<=>?@AZ[]^_`az{|}~"));
        assertFalse(harness.isJsonSafe('"'));
        assertFalse(harness.isJsonSafe("\\"));
        assertFalse(harness.isJsonSafe("\x1f"));
        assertFalse(harness.isJsonSafe("\x7f"));
        assertFalse(harness.isJsonSafe("\x80"));
        assertFalse(harness.isJsonSafe("\xff"));
    }

    function testFuzz_IsJsonSafe_MatchesTheRule(bytes1 c) public view {
        bool expected = uint8(c) >= 0x20 && uint8(c) <= 0x7e && c != '"' && c != "\\";
        assertEq(harness.isJsonSafe(abi.encodePacked("data:", c)), expected);
    }

    function testFuzz_AnyRendererAnswer_KeepsTheJsonValid(bytes memory answer) public {
        _useRenderer(address(new FixedRenderer(string(answer))));
        (, bytes memory image) = _split(bundle.tokenURI(3)); // exactly one image key
        assertTrue(keccak256(image) == keccak256(answer) || keccak256(image) == keccak256(_card()), "the answer or the card");
        assertTrue(harness.isAccepted(image));
        vm.parseJson(string(CardTestKit.jsonOf(bundle.tokenURI(3))));
    }

    // ------------------------------------------------------------ events, ERC-4906, access

    function test_SetImageRenderer_EmitsItsEvent_AndBatchMetadataUpdate() public {
        address r = address(new FixedRenderer("ipfs://fixed-renderer"));
        vm.expectEmit(address(bundle));
        emit ImageRendererSet(address(0), r);
        vm.expectEmit(address(bundle));
        emit BatchMetadataUpdate(0, type(uint256).max);
        bundle.setImageRenderer(r);

        // The SAME renderer again re-announces (a refresh without a change).
        vm.expectEmit(address(bundle));
        emit ImageRendererSet(r, r);
        vm.expectEmit(address(bundle));
        emit BatchMetadataUpdate(0, type(uint256).max);
        bundle.setImageRenderer(r);

        vm.expectEmit(address(bundle));
        emit ImageRendererSet(r, address(0));
        vm.expectEmit(address(bundle));
        emit BatchMetadataUpdate(0, type(uint256).max);
        bundle.setImageRenderer(address(0));
    }

    function test_BaseURISetters_EmitTheirEvent_AndBatchMetadataUpdate() public {
        vm.expectEmit(address(bundle));
        emit ImageBaseURISet("", "https://example.invalid/img/");
        vm.expectEmit(address(bundle));
        emit BatchMetadataUpdate(0, type(uint256).max);
        bundle.setImageBaseURI("https://example.invalid/img/");
        vm.expectEmit(address(bundle));
        emit ImageBaseURISet("https://example.invalid/img/", "");
        vm.expectEmit(address(bundle));
        emit BatchMetadataUpdate(0, type(uint256).max);
        bundle.setImageBaseURI("");

        vm.expectEmit(address(bundle));
        emit ExternalBaseURISet("", "https://example.invalid/claim/");
        vm.expectEmit(address(bundle));
        emit BatchMetadataUpdate(0, type(uint256).max);
        bundle.setExternalBaseURI("https://example.invalid/claim/");
        vm.expectEmit(address(bundle));
        emit ExternalBaseURISet("https://example.invalid/claim/", "");
        vm.expectEmit(address(bundle));
        emit BatchMetadataUpdate(0, type(uint256).max);
        bundle.setExternalBaseURI("");
    }

    function test_SupportsERC4906_AndStillEverythingElse() public view {
        assertTrue(bundle.supportsInterface(0x49064906));
        assertTrue(bundle.supportsInterface(0x80ac58cd));
        assertTrue(bundle.supportsInterface(0x5b5e139f));
        assertTrue(bundle.supportsInterface(0x7f5828d0));
        assertFalse(bundle.supportsInterface(0xffffffff));
    }

    function test_OnlyTheOwnerSetsTheImage() public {
        address[3] memory others = [address(0x5713), address(controller), address(0xB0B)];
        for (uint256 i; i < others.length; ++i) {
            vm.startPrank(others[i]);
            vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, others[i]));
            bundle.setImageRenderer(address(1));
            vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, others[i]));
            bundle.setImageBaseURI("https://example.invalid/");
            vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, others[i]));
            bundle.setExternalBaseURI("https://example.invalid/");
            vm.stopPrank();
        }
    }

    // ------------------------------------------------------------ storage

    function test_ImageStorage_IsTheErc7201Slot_FarFromEverythingElse() public {
        bytes32 computed = keccak256(abi.encode(uint256(keccak256("newtrade.storage.NewTradeBundle.image")) - 1))
            & ~bytes32(uint256(0xff));
        assertEq(computed, IMAGE_SLOT, "the constant is the ERC-7201 formula");
        assertGt(uint256(IMAGE_SLOT), 1 << 128, "nowhere near the sequential slots 0-4");
        bytes32[5] memory oz = [
            bytes32(0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00), // Initializable
            0x9016d09d72d40fdae2fd8ceac6b6234c7706214fd39c1cd1e609a0528c199300, // Ownable
            0x237e158222e3e6968b72b9db0d8043aacf074ad9f650f0d1606b4d82ee432c00, // Ownable2Step
            0x80bb2b638cc20bc4d0a60d66940f3ab4a00c1d7b313497ca82fb0b4ab0079300, // ERC721
            0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc // ERC-1967 implementation
        ];
        for (uint256 i; i < oz.length; ++i) {
            uint256 d = uint256(IMAGE_SLOT) > uint256(oz[i]) ? uint256(IMAGE_SLOT) - uint256(oz[i]) : uint256(oz[i]) - uint256(IMAGE_SLOT);
            assertGt(d, 1 << 64, "no overlap with an OpenZeppelin namespace or the implementation slot");
        }

        bytes32[5] memory before;
        for (uint256 i; i < 5; ++i) before[i] = vm.load(address(bundle), bytes32(i));
        address r = address(new FixedRenderer("ipfs://fixed-renderer"));
        bundle.setImageRenderer(r);
        bundle.setImageBaseURI("https://i.invalid/");
        bundle.setExternalBaseURI("https://e.invalid/");
        assertEq(vm.load(address(bundle), IMAGE_SLOT), bytes32(uint256(uint160(r))), "renderer at the namespace's slot 0");
        assertEq(vm.load(address(bundle), bytes32(uint256(IMAGE_SLOT) + 1)), bytes32(bytes("https://i.invalid/")) | bytes32(uint256(18 * 2)), "imageBaseURI at +1");
        assertEq(vm.load(address(bundle), bytes32(uint256(IMAGE_SLOT) + 2)), bytes32(bytes("https://e.invalid/")) | bytes32(uint256(18 * 2)), "externalBaseURI at +2");
        for (uint256 i; i < 5; ++i) assertEq(vm.load(address(bundle), bytes32(i)), before[i], "sequential slots untouched");
    }
}
