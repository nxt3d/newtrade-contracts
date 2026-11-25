// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

interface IERC8048Metadata {
    event MetadataSet(uint256 indexed tokenId, string indexed indexedKey, string key, bytes value);

    function metadata(uint256 tokenId, string calldata key) external view returns (bytes memory);
}

/// @notice Minimal ERC-721T fixture: ERC-721 plus ERC-8048 raw-byte metadata.
contract MockERC721T is ERC721, IERC8048Metadata {
    bytes4 internal constant ERC8048_INTERFACE_ID = 0xdf670be1;

    mapping(uint256 tokenId => mapping(bytes32 keyHash => bytes value)) private records;

    constructor() ERC721("ERC-721T Agent", "AGENT") {}

    function mint(address to, uint256 tokenId) external {
        _mint(to, tokenId);
    }

    function setMetadata(uint256 tokenId, string calldata key, bytes calldata value) external {
        require(msg.sender == ownerOf(tokenId), "NOT_OWNER");
        records[tokenId][keccak256(bytes(key))] = value;
        emit MetadataSet(tokenId, key, key, value);
    }

    function metadata(uint256 tokenId, string calldata key) external view returns (bytes memory) {
        _requireOwned(tokenId);
        return records[tokenId][keccak256(bytes(key))];
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721) returns (bool) {
        return interfaceId == ERC8048_INTERFACE_ID || super.supportsInterface(interfaceId);
    }
}

/// @notice Executable token-bound account fixture that deliberately exposes no
/// owner() or isValidSigner() selector. Authority follows its bound ERC-721.
contract MockERC8048ExecutableAccount is IERC721Receiver, IERC1155Receiver {
    function token() public view returns (uint256 chainId, address tokenContract, uint256 tokenId) {
        assembly ("memory-safe") {
            let p := mload(0x40)
            extcodecopy(address(), p, 45, 128)
            chainId := mload(add(p, 32))
            tokenContract := mload(add(p, 64))
            tokenId := mload(add(p, 96))
        }
    }

    function execute(address target, uint256 value, bytes calldata data, uint8 operation)
        external
        payable
        returns (bytes memory result)
    {
        (uint256 chainId, address tokenContract, uint256 tokenId) = token();
        require(
            operation == 0 && chainId == block.chainid && IERC721(tokenContract).ownerOf(tokenId) == msg.sender, "AUTH"
        );
        (bool ok, bytes memory out) = target.call{value: value}(data);
        require(ok, "CALL");
        return out;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC1155Receiver.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return IERC1155Receiver.onERC1155BatchReceived.selector;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC721Receiver).interfaceId || interfaceId == type(IERC1155Receiver).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }
}
