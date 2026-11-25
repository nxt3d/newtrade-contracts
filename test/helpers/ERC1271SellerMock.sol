// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {NewTradeEscrowV2} from "../../src/NewTradeEscrowV2.sol";
import {ManifestEntry} from "../../src/NewTradeV2Types.sol";

contract ERC1271SellerMock is IERC1271 {
    bytes4 private constant MAGIC = 0x1626ba7e;
    function isValidSignature(bytes32,bytes memory signature) external pure returns(bytes4){return keccak256(signature)==keccak256(hex"01")?MAGIC:bytes4(0xffffffff);}
    function approveAndDeposit(NewTradeEscrowV2 escrow,address nft,uint256 tokenId,uint64 deadline) external returns(uint256){
        IERC721(nft).approve(escrow.vault(),tokenId); ManifestEntry[] memory empty=new ManifestEntry[](0);
        return escrow.deposit(nft,tokenId,empty,deadline);
    }
}
