// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {NewTradeBundleCard} from "../../src/NewTradeBundleCard.sol";

/// The PRE-CARD metadata JSON, VERBATIM from src/NewTradeBundle.sol at commit 4c202bc
/// (`tokenURI` body, `_attributes`, `_properties`, `_assetReference`), with the
/// bundle collection address passed in instead of read from `address(this)`.
/// It is the "before" every card test compares against: the new JSON minus its
/// one `"image":"…",` segment must equal this, byte for byte.
library LegacyBundleJson {
    using Strings for uint256;

    function json(uint256 tokenId, uint256 chainId, address nft, uint256 nftId, bytes32 manifestHash, address bundle)
        internal
        pure
        returns (bytes memory)
    {
        string memory id = tokenId.toString();
        return abi.encodePacked(
            '{"name":"NewTrade Bundle #',
            id,
            '","description":"NewTrade Bundle NFT: a transferable claim on a vault-held asset bundle. This Bundle NFT is not the underlying collection NFT.",',
            _attributes(id, nft, nftId, manifestHash),
            _properties(tokenId, chainId, nft, nftId, manifestHash, bundle),
            "}"
        );
    }

    /// bundle-non-transferable-sep26: the same JSON with EXACTLY two insertions -
    /// one sentence at the end of the description, and one attribute after
    /// "Manifest Hash" - and ONE substitution: "a transferable claim" becomes
    /// "a redeem-only claim". Every other byte is `json` above.
    string internal constant NT_SENTENCE = " This claim can only be redeemed by its holder; it cannot be transferred or resold.";
    string internal constant NT_ATTRIBUTE = ',{"trait_type":"Transferable","value":"No (redeem only)"}';

    function jsonNonTransferable(uint256 tokenId, uint256 chainId, address nft, uint256 nftId, bytes32 manifestHash, address bundle)
        internal
        pure
        returns (bytes memory)
    {
        string memory id = tokenId.toString();
        bytes memory attrs = _attributes(id, nft, nftId, manifestHash);
        // `attrs` ends with '"}],': insert the attribute before its final "],".
        bytes memory head = new bytes(attrs.length - 2);
        for (uint256 i; i < head.length; ++i) head[i] = attrs[i];
        return abi.encodePacked(
            '{"name":"NewTrade Bundle #',
            id,
            '","description":"NewTrade Bundle NFT: a redeem-only claim on a vault-held asset bundle. This Bundle NFT is not the underlying collection NFT.',
            NT_SENTENCE,
            '",',
            head,
            NT_ATTRIBUTE,
            "],",
            _properties(tokenId, chainId, nft, nftId, manifestHash, bundle),
            "}"
        );
    }

    function _attributes(string memory id, address nft, uint256 nftId, bytes32 manifestHash) private pure returns (bytes memory) {
        return abi.encodePacked(
            '"attributes":[{"trait_type":"Asset Type","value":"NewTrade Bundle NFT"},{"trait_type":"Bundle ID","value":"',
            id,
            '"},{"trait_type":"Original NFT Contract","value":"',
            Strings.toHexString(uint160(nft), 20),
            '"},{"trait_type":"Original NFT Token ID","value":"',
            nftId.toString(),
            '"},{"trait_type":"Manifest Hash","value":"',
            Strings.toHexString(uint256(manifestHash), 32),
            '"}],'
        );
    }

    function _properties(uint256 tokenId, uint256 chainId, address nft, uint256 nftId, bytes32 manifestHash, address bundle)
        private
        pure
        returns (bytes memory)
    {
        string memory chain = chainId.toString();
        bytes memory identity = abi.encodePacked(
            '"properties":{"schema":"newtrade.bundle.v2","chain_id":"',
            chain,
            '","bundle_id":"',
            tokenId.toString(),
            '","original_nft_contract":"',
            Strings.toHexString(uint160(nft), 20),
            '","original_nft_token_id":"',
            nftId.toString()
        );
        return abi.encodePacked(
            identity,
            '","original_asset":"',
            _assetReference(chain, nft, nftId),
            '","bundle_asset":"',
            _assetReference(chain, bundle, tokenId),
            '","manifest_hash":"',
            Strings.toHexString(uint256(manifestHash), 32),
            '"}'
        );
    }

    function _assetReference(string memory chain, address collection, uint256 tokenId) private pure returns (bytes memory) {
        return abi.encodePacked("eip155:", chain, "/erc721:", Strings.toHexString(uint160(collection), 20), "/", tokenId.toString());
    }
}

/// Test-side helpers for the card: base64 decode, the image strip, byte search.
library CardTestKit {
    bytes internal constant IMAGE_KEY = '"image":"data:image/svg+xml;base64,';

    function decodeBase64(bytes memory input) internal pure returns (bytes memory out) {
        require(input.length % 4 == 0, "BASE64_LENGTH");
        uint256 padding = input.length == 0 ? 0 : (input[input.length - 1] == "=" ? 1 : 0);
        if (input.length > 1 && input[input.length - 2] == "=") padding++;
        out = new bytes(input.length / 4 * 3 - padding);
        uint256 cursor;
        for (uint256 i; i < input.length; i += 4) {
            uint256 word = (_v(input[i]) << 18) | (_v(input[i + 1]) << 12) | (_v(input[i + 2]) << 6) | _v(input[i + 3]);
            if (cursor < out.length) out[cursor++] = bytes1(uint8(word >> 16));
            if (cursor < out.length) out[cursor++] = bytes1(uint8(word >> 8));
            if (cursor < out.length) out[cursor++] = bytes1(uint8(word));
        }
    }

    function _v(bytes1 c) private pure returns (uint256) {
        uint8 x = uint8(c);
        if (x >= 65 && x <= 90) return x - 65;
        if (x >= 97 && x <= 122) return x - 71;
        if (x >= 48 && x <= 57) return x + 4;
        if (x == 43) return 62;
        if (x == 47) return 63;
        if (x == 61) return 0;
        revert("BASE64_CHAR");
    }

    function slice(bytes memory b, uint256 from, uint256 to) internal pure returns (bytes memory out) {
        out = new bytes(to - from);
        for (uint256 i = from; i < to; ++i) out[i - from] = b[i];
    }

    function indexOf(bytes memory hay, bytes memory needle, uint256 from) internal pure returns (int256) {
        if (needle.length > hay.length) return -1;
        for (uint256 i = from; i + needle.length <= hay.length; ++i) {
            bool ok = true;
            for (uint256 j; j < needle.length; ++j) if (hay[i + j] != needle[j]) { ok = false; break; }
            if (ok) return int256(i);
        }
        return -1;
    }

    function contains(bytes memory hay, bytes memory needle) internal pure returns (bool) {
        return indexOf(hay, needle, 0) >= 0;
    }

    /// The decoded metadata JSON of a `data:application/json;base64,` token URI.
    function jsonOf(string memory uri) internal pure returns (bytes memory) {
        bytes memory u = bytes(uri);
        bytes memory prefix = "data:application/json;base64,";
        require(u.length > prefix.length && keccak256(slice(u, 0, prefix.length)) == keccak256(prefix), "PREFIX");
        return decodeBase64(slice(u, prefix.length, u.length));
    }

    /// Splits the JSON at its ONE image key: (the JSON with exactly `"image":"…",` removed, the base64 value).
    function stripImage(bytes memory json) internal pure returns (bytes memory without, bytes memory b64) {
        int256 at = indexOf(json, IMAGE_KEY, 0);
        require(at >= 0, "NO_IMAGE");
        require(indexOf(json, '"image":', uint256(at) + 1) < 0, "TWO_IMAGES");
        uint256 start = uint256(at);
        uint256 valueStart = start + IMAGE_KEY.length;
        int256 close = indexOf(json, '",', valueStart);
        require(close >= 0, "UNCLOSED");
        b64 = slice(json, valueStart, uint256(close));
        without = abi.encodePacked(slice(json, 0, start), slice(json, uint256(close) + 2, json.length));
    }
}

/// Exposes the card library's internals to tests.
contract CardHarness {
    function svg(uint256 bundleId, address nft, uint256 nftId) external pure returns (bytes memory) {
        return NewTradeBundleCard.svg(bundleId, nft, nftId);
    }
    function shortAddress(address a) external pure returns (bytes memory) {
        return NewTradeBundleCard.shortAddress(a);
    }
    function shortId(string memory d) external pure returns (bytes memory) {
        return NewTradeBundleCard.shortId(d);
    }
}
