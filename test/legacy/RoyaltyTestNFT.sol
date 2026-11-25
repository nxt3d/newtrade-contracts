// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC2981} from "@openzeppelin/contracts/token/common/ERC2981.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * A TEST collection for Prem's option B proof run on Base
 * (escrow-option-b-sep26): a plain ERC-721 whose ERC-2981 answer is a fixed
 * `bps` share of any sale price to one `receiver` - e.g. 250 bps to
 * 0xc3F96C409d26272fDB592c0d04e1D771A7df032e.
 *
 * 6551-friendly by being a standard ERC-721: an ERC-6551 account for
 * (chainId, this, tokenId) is created through the registry the escrow's
 * fresh-account policy pins, independently of this contract.
 *
 * Owner-only mint; no transfer restrictions, no metadata beyond the name.
 * Not a production collection.
 */
contract RoyaltyTestNFT is ERC721, ERC2981, Ownable {
    constructor(address receiver, uint96 bps) ERC721("NewTrade Royalty Test", "NTRT") Ownable(msg.sender) {
        _setDefaultRoyalty(receiver, bps);
    }

    function mint(address to, uint256 tokenId) external onlyOwner {
        _mint(to, tokenId);
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721, ERC2981) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
