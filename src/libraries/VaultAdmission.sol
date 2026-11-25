// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {AcceptanceMode, AssetKind, ManifestEntry} from "../NewTradeV2Types.sol";
import {IERC6551ExecutableAccount} from "../interfaces/IERC6551.sol";
import {NewTradeV2VaultStorage} from "../NewTradeV2VaultStorage.sol";

/// @notice Admission rules of the upgradeable vault, linked as an external library
/// (delegatecall) to keep the vault under EIP-170. Runs in the proxy's storage.
library VaultAdmission {
    using SafeERC20 for IERC20;
    using NewTradeV2VaultStorage for NewTradeV2VaultStorage.VaultStorage;

    error InvalidManifest();
    error UnsupportedAsset();
    error AssetReserved();
    error TransferMismatch();

    function isAllowed(address token, AssetKind kind) external view returns (bool) {
        return _isAllowed(token, kind);
    }

    function _isAllowed(address token, AssetKind kind) private view returns (bool) {
        if (!_eligible(token, kind)) return false;
        NewTradeV2VaultStorage.VaultStorage storage $ = NewTradeV2VaultStorage.s();
        AcceptanceMode mode = $.acceptanceModes[uint8(kind)];
        if (mode == AcceptanceMode.Disabled) return false;
        if (mode == AcceptanceMode.Allowlist && !($.allowlistKindPlusOne[token] == uint8(kind) + 1)) return false;
        uint8 pinned = $.custodyKindPlusOne[token];
        return pinned == 0 || pinned == uint8(kind) + 1 || $.assetLiabilityUnits[token] == 0;
    }


    function validateAndPin(ManifestEntry[] calldata es, address nft, uint256 nftId) external {
        NewTradeV2VaultStorage.VaultStorage storage $ = NewTradeV2VaultStorage.s();
        _pinAssetKind(nft, AssetKind.ERC721);
        uint8 pk;
        address pt;
        uint256 pi;
        for (uint256 i; i < es.length; ++i) {
            ManifestEntry calldata e = es[i];
            if (e.amount == 0 || (e.token == nft && e.kind != AssetKind.ERC721)) revert InvalidManifest();
            if (e.kind == AssetKind.ERC20 && e.tokenId != 0) revert InvalidManifest();
            if (
                e.kind == AssetKind.ERC721
                    && (e.amount != 1 || (e.token == nft && e.tokenId == nftId) || $.erc721Reserved[e.token][e.tokenId])
            ) revert InvalidManifest();
            uint8 k = uint8(e.kind);
            if (
                i != 0
                    && (k < pk || (k == pk && (uint160(e.token) < uint160(pt) || (e.token == pt && e.tokenId <= pi))))
            ) revert InvalidManifest();
            for (uint256 j; j < i; ++j) {
                if (es[j].token == e.token && es[j].kind != e.kind) revert InvalidManifest();
            }
            _pinAssetKind(e.token, e.kind);
            pk = k;
            pt = e.token;
            pi = e.tokenId;
        }
    }

    function _pinAssetKind(address token, AssetKind kind) private {
        NewTradeV2VaultStorage.VaultStorage storage $ = NewTradeV2VaultStorage.s();
        if (!_isAllowed(token, kind)) revert UnsupportedAsset();
        uint8 next = uint8(kind) + 1;
        uint8 pinned = $.custodyKindPlusOne[token];
        if (pinned != 0 && pinned != next && $.assetLiabilityUnits[token] != 0) revert AssetReserved();
        $.custodyKindPlusOne[token] = next;
    }

    function requireEligible(address token, AssetKind kind) external view {
        if (!_eligible(token, kind)) revert UnsupportedAsset();
    }

    function _eligible(address token, AssetKind kind) private view returns (bool) {
        NewTradeV2VaultStorage.VaultStorage storage $ = NewTradeV2VaultStorage.s();
        if (
            token == address(0) || token.code.length == 0 || token == address(this) || token == $.controller
                || token == $.receipt
        ) return false;
        bool erc721 = _supports(token, type(IERC721).interfaceId);
        bool erc1155 = _supports(token, type(IERC1155).interfaceId);
        if (kind == AssetKind.ERC721) return erc721 && !erc1155;
        if (kind == AssetKind.ERC1155) return erc1155 && !erc721;
        return !erc721 && !erc1155;
    }

    function _supports(address token, bytes4 interfaceId) private view returns (bool supported) {
        (bool ok, bytes memory data) = token.staticcall(abi.encodeCall(IERC165.supportsInterface, (interfaceId)));
        if (!ok || data.length < 32) return false;
        uint256 value;
        assembly ("memory-safe") {
            value := mload(add(data, 32))
        }
        return value == 1;
    }

    /// Pulls one manifest entry from `source` into the vault, either by the vault's
    /// own transferFrom (a wallet deposit) or by asking the ERC-6551 `source` to
    /// execute the transfer (a migration). Same pre- and post-checks either way.
}
