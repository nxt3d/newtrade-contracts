// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice What the Bundle NFT accepts as a URI in its metadata: an `image`
/// from its renderer or image base URL (anything else is replaced by the
/// built-in card), an `external_url` (anything else omits the key), and - when
/// they are set - the two base URLs themselves.
///
/// JSON SAFETY is the rule: the URI is spliced into the metadata JSON as a
/// string, so it must not contain `"` or `\` (which would end or escape the
/// string) or a control byte (< 0x20, invalid in a JSON string). NON-ASCII
/// (>= 0x80) and DEL are rejected too: a URI carries them percent-encoded, so a
/// raw one is either a mistake or an attempt at something.
///
/// ANY SCHEME (user decision): `data:`, `https:`, `ipfs:`, `ar:`, ... - and a
/// scheme-less string - are all accepted. The contract guarantees valid JSON, not
/// a resolvable URI: which schemes a wallet or marketplace follows is its call,
/// and the owner who sets the value chooses what it points at.
library BundleImageURI {
    /// Longest accepted image URI. A card-sized SVG is ~1-2 KB of base64; 16 KB
    /// leaves room for a richer picture while keeping `tokenURI` bounded.
    uint256 internal constant MAX_BYTES = 16_384;

    /// Non-empty, at most MAX_BYTES, and JSON-safe.
    function isAccepted(bytes memory uri) internal pure returns (bool) {
        if (uri.length == 0 || uri.length > MAX_BYTES) return false;
        return isJsonSafe(uri);
    }

    /// Printable ASCII (0x20-0x7E) without `"` and `\`.
    function isJsonSafe(bytes memory s) internal pure returns (bool) {
        for (uint256 i; i < s.length; ++i) {
            bytes1 c = s[i];
            if (c < 0x20 || c > 0x7e || c == '"' || c == "\\") return false;
        }
        return true;
    }
}
