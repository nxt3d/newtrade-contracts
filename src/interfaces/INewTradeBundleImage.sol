// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice A Bundle NFT image renderer, installed with `NewTradeBundle.setImageRenderer`.
///
/// Returns the FULL image URI for one bundle, of any scheme (`data:…`,
/// `https://…`, `ipfs://…`, …): printable ASCII without `"` or `\`, at most
/// 16 KB. The Bundle NFT calls it with a bounded gas stipend and treats ANY
/// other answer - a revert, running out of gas, an empty or oversized string, a
/// disallowed byte - as "no image", falling back to its built-in card. A
/// renderer can change the picture; it cannot break `tokenURI`.
interface INewTradeBundleImage {
    function imageURI(uint256 bundleId, address nft, uint256 nftId) external view returns (string memory);
}
