// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC2981} from "@openzeppelin/contracts/token/common/ERC2981.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IERC6551Registry, ITokenboundAccountProxy} from "../../src/interfaces/IERC6551.sol";
import {ICreatorToken, ITransferValidator} from "../../src/interfaces/ICreatorToken.sol";

/// @notice Transfer policy for the disposable beta NFT. An NFT may enter an
/// approved custody contract. It may leave custody only when that custody
/// contract is itself the ERC-721 caller; merely being an approved third party
/// is insufficient. The NFT's normal owner/approval checks still apply.
contract FixtureCustodyValidator is ITransferValidator {
    address public immutable admin;
    mapping(address custody => bool approved) public approvedCustody;

    error NotAdmin();
    error InvalidCustody(address custody);
    error TransferDenied(address caller, address from, address to);

    constructor(address admin_) {
        if (admin_ == address(0)) revert NotAdmin();
        admin = admin_;
    }

    function setApprovedCustody(address custody, bool approved) external {
        if (msg.sender != admin) revert NotAdmin();
        if (approved && (custody == address(0) || custody.code.length == 0)) revert InvalidCustody(custody);
        approvedCustody[custody] = approved;
    }

    function validateTransfer(address caller, address from, address to, uint256) external view {
        if (approvedCustody[to]) return;
        if (approvedCustody[from] && caller == from) return;
        revert TransferDenied(caller, from, to);
    }
}

/// @notice Disposable Base beta fixture with ERC-2981 royalties, self-contained
/// display metadata, ERC-721C-style validation, ERC-6551 creation and ERC-8048
/// account-index-zero discovery.
contract RevisedBaseBetaFixture is ERC721, ERC2981, ICreatorToken {
    using Strings for uint256;

    bytes4 public constant ERC8048_INTERFACE_ID = 0xdf670be1;
    string public constant BASE_ACCOUNT_INDEX_ZERO = "account[0x0001000002210500][0]";

    address public immutable admin;
    IERC6551Registry public immutable registry;
    address public immutable accountProxy;
    address public immutable accountLogic;
    bytes32 public immutable accountSalt;
    string public image;
    string public description;

    address private transferValidator;
    mapping(uint256 tokenId => address account) public tokenAccount;
    mapping(uint256 tokenId => mapping(bytes32 keyHash => bytes value)) private records;

    event MetadataSet(uint256 indexed tokenId, string indexed indexedKey, string key, bytes value);
    event FixtureMinted(address indexed owner, uint256 indexed tokenId, address indexed account);

    error NotAdmin();
    error WrongChain(uint256 chainId);
    error AccountDerivationMismatch(address predicted, address created);
    error InvalidMetadata();
    error InvalidRoyalty();

    constructor(
        address registry_,
        address accountProxy_,
        address accountLogic_,
        bytes32 accountSalt_,
        address royaltyRecipient_,
        uint96 royaltyBps_,
        string memory image_,
        string memory description_
    ) ERC721("NewTrade Beta NFT", "NTBBE") {
        if (block.chainid != 8453) revert WrongChain(block.chainid);
        if (royaltyRecipient_ == address(0) || royaltyBps_ == 0) revert InvalidRoyalty();
        if (bytes(image_).length == 0 || bytes(description_).length == 0) revert InvalidMetadata();
        admin = msg.sender;
        registry = IERC6551Registry(registry_);
        accountProxy = accountProxy_;
        accountLogic = accountLogic_;
        accountSalt = accountSalt_;
        image = image_;
        description = description_;
        _setDefaultRoyalty(royaltyRecipient_, royaltyBps_);
    }

    function mint(address to, uint256 tokenId) external returns (address account) {
        if (msg.sender != admin) revert NotAdmin();
        _mint(to, tokenId);

        address predicted = registry.account(accountProxy, accountSalt, block.chainid, address(this), tokenId);
        account = registry.createAccount(accountProxy, accountSalt, block.chainid, address(this), tokenId);
        if (account != predicted) revert AccountDerivationMismatch(predicted, account);
        ITokenboundAccountProxy(account).initialize(accountLogic);

        tokenAccount[tokenId] = account;
        bytes memory rawAccount = abi.encodePacked(account);
        records[tokenId][keccak256(bytes(BASE_ACCOUNT_INDEX_ZERO))] = rawAccount;
        emit MetadataSet(tokenId, BASE_ACCOUNT_INDEX_ZERO, BASE_ACCOUNT_INDEX_ZERO, rawAccount);
        emit FixtureMinted(to, tokenId, account);
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        bytes memory json = abi.encodePacked(
            '{"name":"NewTrade Beta NFT #',
            tokenId.toString(),
            '","description":"',
            _escapeJson(description),
            '","image":"',
            _escapeJson(image),
            '"}'
        );
        return string.concat("data:application/json;base64,", Base64.encode(json));
    }

    function metadata(uint256 tokenId, string calldata key) external view returns (bytes memory) {
        _requireOwned(tokenId);
        return records[tokenId][keccak256(bytes(key))];
    }

    function getTransferValidator() external view returns (address validator) {
        return transferValidator;
    }

    function getTransferValidationFunction() external pure returns (bytes4 functionSignature, bool isViewFunction) {
        return (ITransferValidator.validateTransfer.selector, true);
    }

    function setTransferValidator(address validator) external {
        if (msg.sender != admin || validator.code.length == 0) revert NotAdmin();
        address oldValidator = transferValidator;
        transferValidator = validator;
        emit TransferValidatorUpdated(oldValidator, validator);
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721, ERC2981) returns (bool) {
        return interfaceId == ERC8048_INTERFACE_ID || interfaceId == type(ICreatorToken).interfaceId
            || super.supportsInterface(interfaceId);
    }

    function _update(address to, uint256 tokenId, address auth) internal override returns (address from) {
        from = _ownerOf(tokenId);
        address validator = transferValidator;
        if (validator != address(0) && from != address(0) && to != address(0)) {
            ITransferValidator(validator).validateTransfer(msg.sender, from, to, tokenId);
        }
        return super._update(to, tokenId, auth);
    }

    function _escapeJson(string memory input) private pure returns (string memory) {
        bytes memory source = bytes(input);
        bytes memory escaped = new bytes(source.length * 6);
        bytes16 hexSymbols = "0123456789abcdef";
        uint256 length;

        for (uint256 i; i < source.length; ++i) {
            uint8 character = uint8(source[i]);
            if (character == 0x22 || character == 0x5c) {
                escaped[length++] = bytes1(0x5c);
                escaped[length++] = source[i];
            } else if (character == 0x08) {
                escaped[length++] = bytes1(0x5c);
                escaped[length++] = bytes1("b");
            } else if (character == 0x0c) {
                escaped[length++] = bytes1(0x5c);
                escaped[length++] = bytes1("f");
            } else if (character == 0x0a) {
                escaped[length++] = bytes1(0x5c);
                escaped[length++] = bytes1("n");
            } else if (character == 0x0d) {
                escaped[length++] = bytes1(0x5c);
                escaped[length++] = bytes1("r");
            } else if (character == 0x09) {
                escaped[length++] = bytes1(0x5c);
                escaped[length++] = bytes1("t");
            } else if (character < 0x20) {
                escaped[length++] = bytes1(0x5c);
                escaped[length++] = bytes1("u");
                escaped[length++] = bytes1("0");
                escaped[length++] = bytes1("0");
                escaped[length++] = hexSymbols[character >> 4];
                escaped[length++] = hexSymbols[character & 0x0f];
            } else {
                escaped[length++] = source[i];
            }
        }

        assembly ("memory-safe") {
            mstore(escaped, length)
        }
        return string(escaped);
    }
}
