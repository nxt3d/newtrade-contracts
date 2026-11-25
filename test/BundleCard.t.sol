// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {NewTradeBundle} from "../src/NewTradeBundle.sol";
import {Bundle} from "../src/NewTradeV2Types.sol";
import {BundleDeploy} from "./helpers/BundleDeploy.sol";
import {LegacyBundleJson, CardTestKit, CardHarness} from "./helpers/BundleCardHelpers.sol";

contract CardValidator {
    function validateTransfer(address, address, address, uint256) external pure {}
}

/// The escrow as far as tokenURI sees it: getBundle, and the mint path.
contract CardController {
    mapping(uint256 => Bundle) internal bundles;

    function set(uint256 id, address nft, uint256 nftId, bytes32 manifestHash) external {
        Bundle storage b = bundles[id];
        b.controllingNFT = nft;
        b.controllingTokenId = nftId;
        b.manifestHash = manifestHash;
    }

    function getBundle(uint256 id) external view returns (Bundle memory) {
        return bundles[id];
    }

    function mint(NewTradeBundle token, uint256 id) external {
        token.controllerMint(id);
    }

    function receiptRoyaltyInfo(uint256, uint256) external pure returns (address, uint256) {
        return (address(0), 0);
    }

    function onReceiptFirstExit(address, address, address, uint256) external {}
}

/**
 * bundle-tokenuri-svg-upgrade-sep25: tokenURI gains ONE key, `image`, an
 * on-chain SVG card; every other byte of the metadata JSON is unchanged.
 */
contract BundleCardTest is Test {
    using CardTestKit for bytes;

    NewTradeBundle bundle;
    CardController controller;
    CardHarness card;

    address constant NFT = 0xf4fd1a2Ea84a16Be24848Aa6f4242E9CAab18953; // bundle #3's original collection on Base
    bytes32 constant MANIFEST = 0xbdd635db3c38b33ba593a6c357dd902125c8c579fb970f5845636bda8d5f9d6a;

    function setUp() public {
        controller = new CardController();
        bundle = BundleDeploy.deploy(address(this), address(0x5EA), address(new CardValidator()), address(0xB0B));
        bundle.bindController(address(controller));
        card = new CardHarness();
    }

    function _mint(uint256 id, address nft, uint256 nftId, bytes32 manifestHash) internal {
        controller.set(id, nft, nftId, manifestHash);
        controller.mint(bundle, id);
    }

    function _legacy(uint256 id, address nft, uint256 nftId, bytes32 manifestHash) internal view returns (bytes memory) {
        // bundle-non-transferable-sep26: the pre-card JSON plus EXACTLY the non-transferable sentence and attribute.
        return LegacyBundleJson.jsonNonTransferable(id, block.chainid, nft, nftId, manifestHash, address(bundle));
    }

    // ------------------------------------------------------------ the JSON

    function test_EveryByteOtherThanTheImageIsTheOldJson() public {
        _mint(3, NFT, 104, MANIFEST);
        bytes memory json = CardTestKit.jsonOf(bundle.tokenURI(3));
        (bytes memory without,) = CardTestKit.stripImage(json);
        assertEq(without, _legacy(3, NFT, 104, MANIFEST), "the JSON minus the image key is byte-for-byte the pre-card JSON");
    }

    function testFuzz_EveryByteOtherThanTheImageIsTheOldJson(uint256 id, address nft, uint256 nftId, bytes32 manifestHash) public {
        id = bound(id, 1, type(uint256).max);
        _mint(id, nft, nftId, manifestHash);
        bytes memory json = CardTestKit.jsonOf(bundle.tokenURI(id));
        (bytes memory without,) = CardTestKit.stripImage(json);
        assertEq(without, _legacy(id, nft, nftId, manifestHash));
    }

    function test_TheImageIsOneNewKeyRightAfterDescription_AndTheJsonIsValid() public {
        _mint(3, NFT, 104, MANIFEST);
        bytes memory json = CardTestKit.jsonOf(bundle.tokenURI(3));
        int256 desc = CardTestKit.indexOf(json, '"description":"', 0);
        int256 image = CardTestKit.indexOf(json, '"image":"', 0);
        int256 attrs = CardTestKit.indexOf(json, '"attributes":[', 0);
        assertTrue(desc >= 0 && image > desc && attrs > image, "order: name, description, image, attributes, properties");
        // Immediately after the description's closing `",`.
        bytes memory beforeImage = CardTestKit.slice(json, uint256(image) - 2, uint256(image));
        assertEq(beforeImage, bytes('",'));
        // Valid JSON, and every key reads back.
        string memory s = string(json);
        vm.parseJson(s);
        assertEq(vm.parseJsonString(s, ".name"), "NewTrade Bundle #3");
        assertEq(vm.parseJsonString(s, ".properties.bundle_id"), "3");
        assertEq(vm.parseJsonString(s, ".attributes[3].value"), "104");
        string memory imageValue = vm.parseJsonString(s, ".image");
        assertEq(CardTestKit.slice(bytes(imageValue), 0, 26), bytes("data:image/svg+xml;base64,"));
    }

    // ------------------------------------------------------------ the SVG

    function test_TheImageDecodesToASmallSvgCard_WithExactlyTheStaticFacts() public {
        _mint(3, NFT, 104, MANIFEST);
        (, bytes memory b64) = CardTestKit.stripImage(CardTestKit.jsonOf(bundle.tokenURI(3)));
        bytes memory svg = CardTestKit.decodeBase64(b64);
        // Base64 round-trip, and it is exactly the library's card.
        assertEq(bytes(Base64.encode(svg)), b64);
        assertEq(svg, card.svg(3, NFT, 104));
        // An SVG document, start to end, and small.
        assertEq(CardTestKit.slice(svg, 0, 4), bytes("<svg"));
        assertEq(CardTestKit.slice(svg, svg.length - 6, svg.length), bytes("</svg>"));
        assertLe(svg.length, 2048, "the card stays under ~2 KB");
        // The facts, exactly.
        assertTrue(svg.contains("NewTrade Bundle #3</text>"), "bundle id");
        assertTrue(svg.contains("Original NFT #104</text>"), "original token id");
        assertTrue(svg.contains("0xf4fd&#8230;8953</text>"), "short original contract (first 6 + last 4, checksummed)");
        // The app's palette.
        for (uint256 i; i < 6; ++i) {
            string[6] memory colors = ["#0b0b0f", "#141418", "#26262c", "#8fa6c8", "#2b8cff", "#e6e6ea"];
            assertTrue(svg.contains(bytes(colors[i])), colors[i]);
        }
        // Nothing that goes stale.
        for (uint256 i; i < 5; ++i) {
            string[5] memory stale = ["Listed", "Issued", "Redeemed", "ETH", "Owner"];
            assertFalse(svg.contains(bytes(stale[i])), stale[i]);
        }
        // No embedded font, no script, no external reference.
        assertFalse(svg.contains("@font-face"));
        assertFalse(svg.contains("<script"));
        assertFalse(svg.contains("href"));
    }

    function test_TheImageValueCanNeverBreakTheJson_OnlyBase64Characters() public {
        _mint(3, NFT, 104, MANIFEST);
        (, bytes memory b64) = CardTestKit.stripImage(CardTestKit.jsonOf(bundle.tokenURI(3)));
        for (uint256 i; i < b64.length; ++i) {
            bytes1 c = b64[i];
            bool ok = (c >= "A" && c <= "Z") || (c >= "a" && c <= "z") || (c >= "0" && c <= "9") || c == "+" || c == "/" || c == "=";
            assertTrue(ok, "only base64 characters: no quote, no backslash");
        }
    }

    /// Every VARIABLE part of the card is digits, hex, or the fixed ellipsis entity:
    /// nothing a holder or a collection controls can open a tag, an attribute or an entity.
    function testFuzz_TheVariablePartsAreDigitsHexAndTheEllipsisOnly(uint256 id, address nft, uint256 nftId) public view {
        bytes[3] memory parts = [card.shortId(Strings.toString(id)), card.shortId(Strings.toString(nftId)), card.shortAddress(nft)];
        for (uint256 p; p < 3; ++p) {
            bytes memory b = parts[p];
            int256 e = CardTestKit.indexOf(b, "&#8230;", 0);
            for (uint256 i; i < b.length; ++i) {
                if (e >= 0 && i >= uint256(e) && i < uint256(e) + 7) continue;
                bytes1 c = b[i];
                bool ok = (c >= "0" && c <= "9") || (c >= "a" && c <= "f") || (c >= "A" && c <= "F") || c == "x";
                assertTrue(ok, "digits / hex only");
            }
        }
        bytes memory svg = card.svg(id == 0 ? 1 : id, nft, nftId);
        assertEq(CardTestKit.slice(svg, svg.length - 6, svg.length), bytes("</svg>"));
        assertLe(svg.length, 2048);
    }

    function test_LongIdsAreShortenedOnTheCardOnly_TheMetadataKeepsEveryDigit() public {
        uint256 longId = type(uint256).max;
        _mint(7, NFT, longId, MANIFEST);
        bytes memory json = CardTestKit.jsonOf(bundle.tokenURI(7));
        (, bytes memory b64) = CardTestKit.stripImage(json);
        bytes memory svg = CardTestKit.decodeBase64(b64);
        string memory full = Strings.toString(longId);
        assertTrue(json.contains(bytes(full)), "the metadata keeps all 78 digits");
        assertFalse(svg.contains(bytes(full)), "the card does not");
        assertTrue(svg.contains(abi.encodePacked("Original NFT #", CardTestKit.slice(bytes(full), 0, 8), "&#8230;", CardTestKit.slice(bytes(full), 74, 78), "</text>")));
        // 16 digits exactly: kept whole.
        assertEq(card.shortId("1234567890123456"), bytes("1234567890123456"));
        assertEq(card.shortId("12345678901234567"), bytes("12345678&#8230;4567"));
    }

    function test_ShortAddressIsTheChecksummedFirst6AndLast4() public view {
        assertEq(card.shortAddress(NFT), bytes("0xf4fd&#8230;8953"));
        assertEq(card.shortAddress(0x59900b207ea703B0bBcF8fD84C5E11dE46826185), bytes("0x5990&#8230;6185"));
        // CHECKSUMMED, not lowercase: an address whose kept characters include letters
        // (the escrow, 0xCc29…f86d) reads differently in the two forms.
        assertEq(card.shortAddress(0xCc29F5c82C8b7c01Cac6036047E7413Df458f86d), bytes("0xCc29&#8230;f86d"));
    }

    function test_TokenUriOfAMissingTokenStillReverts() public {
        vm.expectRevert();
        bundle.tokenURI(99);
    }
}
