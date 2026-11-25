// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @title Token mocks
/// @notice Deployable test/devnet token mocks shared by the test suite and the
///         devnet deploy script (so there is a single source of truth). These
///         are NOT part of the protocol — they exist only to exercise it.

/// @notice ERC-20 with configurable decimals and open minting. Used as the
///         devnet "devUSD" payment token (6 decimals, USDC-like).
contract MockERC20 is ERC20 {
    uint8 private immutable _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    /// @notice Mint `amount` to `to` (open, for seeding devnet balances).
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Plain ERC-721 with open minting.
contract MockERC721 is ERC721 {
    constructor() ERC721("MockERC721", "M721") {}

    function mint(address to, uint256 tokenId) external {
        _mint(to, tokenId);
    }
}

/// @notice ERC-1155 with open minting.
contract MockERC1155 is ERC1155 {
    constructor() ERC1155("https://mock/{id}") {}

    function mint(address to, uint256 id, uint256 amount) external {
        _mint(to, id, amount, "");
    }
}

/// @notice ERC-721 implementing EIP-2981 royalties, configurable two ways:
///         a fixed wei amount (`setRoyalty`, ignores sale price) or a basis-point
///         rate (`setRoyaltyBps`, returns salePrice * bps / 10_000). A zero
///         receiver yields a zero royalty regardless of mode.
contract MockERC721Royalty is ERC721, IERC2981 {
    address public royaltyReceiver;
    uint256 public royaltyFixed;
    uint96 public royaltyBps;
    bool public useFixed;

    constructor() ERC721("MockRoyalty", "ROY") {}

    function mint(address to, uint256 tokenId) external {
        _mint(to, tokenId);
    }

    /// @notice Set a fixed royalty amount (in wei), independent of sale price.
    function setRoyalty(address receiver, uint256 amount) external {
        royaltyReceiver = receiver;
        royaltyFixed = amount;
        useFixed = true;
    }

    /// @notice Set a basis-point royalty rate over the sale price.
    function setRoyaltyBps(address receiver, uint96 bps) external {
        royaltyReceiver = receiver;
        royaltyBps = bps;
        useFixed = false;
    }

    function royaltyInfo(uint256, uint256 salePrice) external view returns (address, uint256) {
        uint256 amount = useFixed ? royaltyFixed : (salePrice * royaltyBps) / 10_000;
        return (royaltyReceiver, amount);
    }

    function supportsInterface(bytes4 id) public view override(ERC721, IERC165) returns (bool) {
        return id == type(IERC2981).interfaceId || super.supportsInterface(id);
    }
}
