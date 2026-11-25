// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/// @notice The Bundle NFT's on-chain image: a small static SVG card.
///
/// STATIC FACTS ONLY - the bundle id, the original NFT's token id and its
/// collection address. Nothing that can go stale (state, price, owner) is
/// drawn, so a cached image is never wrong. The manifest's asset count is left
/// out: it is not in `getBundle` and would need a second call.
///
/// NO USER-CONTROLLED STRING reaches the SVG: every variable part is a decimal
/// (`Strings.toString`) or a hex address (`Strings.toChecksumHexString`), so
/// nothing can break out of an attribute or inject markup. The card is
/// base64-encoded into the metadata, so it cannot break the JSON either.
///
/// Internal functions only: the library is inlined into NewTradeBundle, adds
/// no state and no external call, and is split out purely for readability.
library NewTradeBundleCard {
    using Strings for uint256;

    /// Ids longer than this are shortened on the card only (the metadata keeps
    /// every digit): first 8 + "..." + last 4 still fits the 400 px card.
    uint256 internal constant MAX_ID_DIGITS = 16;

    /// The built-in card: exactly `svgWith(…, "")`, byte for byte.
    function svg(uint256 bundleId, address nft, uint256 nftId) internal pure returns (bytes memory) {
        return svgWith(bundleId, nft, nftId, "");
    }

    /// The card with a constant `graphic` fragment drawn in its empty middle
    /// (between the title and the rule). Renderers pass one of `BundleGraphics`.
    function svgWith(uint256 bundleId, address nft, uint256 nftId, bytes memory graphic)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 400" font-family="system-ui,-apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif">',
            '<rect width="400" height="400" fill="#0b0b0f"/>',
            '<rect x="20" y="20" width="360" height="360" rx="16" fill="#141418" stroke="#26262c"/>',
            '<rect x="44" y="44" width="32" height="4" rx="2" fill="#2b8cff"/>',
            '<text x="44" y="100" fill="#e6e6ea" font-size="26" font-weight="600">NewTrade Bundle #',
            shortId(bundleId.toString()),
            "</text>",
            graphic,
            '<line x1="44" y1="260" x2="356" y2="260" stroke="#26262c"/>',
            '<text x="44" y="298" fill="#e6e6ea" font-size="20">Original NFT #',
            shortId(nftId.toString()),
            '</text><text x="44" y="328" fill="#8fa6c8" font-size="14" font-family="ui-monospace,SFMono-Regular,Menlo,Consolas,monospace">',
            shortAddress(nft),
            "</text></svg>"
        );
    }

    /// "0xf4fd&#8230;8953": the first 6 and last 4 characters of the checksummed address.
    function shortAddress(address a) internal pure returns (bytes memory) {
        bytes memory hex_ = bytes(Strings.toChecksumHexString(a));
        return abi.encodePacked(_slice(hex_, 0, 6), "&#8230;", _slice(hex_, 38, 42));
    }

    /// A decimal id as is, or first 8 + "&#8230;" + last 4 when longer than MAX_ID_DIGITS.
    function shortId(string memory decimal) internal pure returns (bytes memory) {
        bytes memory d = bytes(decimal);
        if (d.length <= MAX_ID_DIGITS) return d;
        return abi.encodePacked(_slice(d, 0, 8), "&#8230;", _slice(d, d.length - 4, d.length));
    }

    function _slice(bytes memory b, uint256 from, uint256 to) private pure returns (bytes memory out) {
        out = new bytes(to - from);
        for (uint256 i = from; i < to; ++i) out[i - from] = b[i];
    }
}
