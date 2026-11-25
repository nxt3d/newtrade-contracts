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

/// @notice Deposit-side transfers and checks of the upgradeable vault, linked as an
/// external library (delegatecall) to keep the vault under EIP-170.
library VaultCustodyIn {
    using SafeERC20 for IERC20;
    using NewTradeV2VaultStorage for NewTradeV2VaultStorage.VaultStorage;

    error InvalidManifest();
    error UnsupportedAsset();
    error AssetReserved();
    error TransferMismatch();

    function pullEntry(ManifestEntry calldata e, address source, bool viaAccount) external {
        NewTradeV2VaultStorage.VaultStorage storage $ = NewTradeV2VaultStorage.s();
        if (e.kind == AssetKind.ERC20) {
            uint256 b = IERC20(e.token).balanceOf(address(this));
            uint256 f = IERC20(e.token).balanceOf(source);
            if (f < e.amount) revert TransferMismatch();
            if (viaAccount) {
                IERC6551ExecutableAccount(source).execute(
                    e.token, 0, abi.encodeCall(IERC20.transfer, (address(this), e.amount)), 0
                );
            } else {
                IERC20(e.token).safeTransferFrom(source, address(this), e.amount);
            }
            if (
                IERC20(e.token).balanceOf(source) != f - e.amount
                    || IERC20(e.token).balanceOf(address(this)) != b + e.amount
            ) revert TransferMismatch();
            $.erc20Liability[e.token] += e.amount;
            $.assetLiabilityUnits[e.token] += e.amount;
        } else if (e.kind == AssetKind.ERC721) {
            if (IERC721(e.token).ownerOf(e.tokenId) != source) revert TransferMismatch();
            $.erc721Reserved[e.token][e.tokenId] = true;
            $.assetLiabilityUnits[e.token]++;
            if (viaAccount) {
                $.expected = NewTradeV2VaultStorage.Expected(e.token, source, source, e.tokenId, 1, uint8(AssetKind.ERC721) + 1);
                IERC6551ExecutableAccount(source).execute(
                    e.token,
                    0,
                    abi.encodeWithSignature("safeTransferFrom(address,address,uint256)", source, address(this), e.tokenId),
                    0
                );
                if ($.expected.kind != 0 || IERC721(e.token).ownerOf(e.tokenId) != address(this)) {
                    revert TransferMismatch();
                }
            } else {
                _pull721(e.token, e.tokenId, source, address(this));
            }
        } else {
            uint256 b = IERC1155(e.token).balanceOf(address(this), e.tokenId);
            uint256 f = IERC1155(e.token).balanceOf(source, e.tokenId);
            if (f < e.amount) revert TransferMismatch();
            $.expected = NewTradeV2VaultStorage.Expected(
                e.token, viaAccount ? source : address(this), source, e.tokenId, e.amount, uint8(AssetKind.ERC1155) + 1
            );
            if (viaAccount) {
                IERC6551ExecutableAccount(source).execute(
                    e.token,
                    0,
                    abi.encodeCall(IERC1155.safeTransferFrom, (source, address(this), e.tokenId, e.amount, "")),
                    0
                );
            } else {
                IERC1155(e.token).safeTransferFrom(source, address(this), e.tokenId, e.amount, "");
            }
            if (
                $.expected.kind != 0 || IERC1155(e.token).balanceOf(source, e.tokenId) != f - e.amount
                    || IERC1155(e.token).balanceOf(address(this), e.tokenId) != b + e.amount
            ) revert TransferMismatch();
            $.erc1155Liability[e.token][e.tokenId] += e.amount;
            $.assetLiabilityUnits[e.token] += e.amount;
        }
    }

    function pull721(address token, uint256 id, address source, address operator) external {
        _pull721(token, id, source, operator);
    }

    function _pull721(address token, uint256 id, address source, address operator) private {
        NewTradeV2VaultStorage.VaultStorage storage $ = NewTradeV2VaultStorage.s();
        if (IERC721(token).ownerOf(id) != source) revert TransferMismatch();
        $.expected = NewTradeV2VaultStorage.Expected(token, operator, source, id, 1, uint8(AssetKind.ERC721) + 1);
        IERC721(token).safeTransferFrom(source, address(this), id);
        if ($.expected.kind != 0 || IERC721(token).ownerOf(id) != address(this)) revert TransferMismatch();
    }

    function postcheck(ManifestEntry[] calldata es, address nft, uint256 nftId) external view {
        NewTradeV2VaultStorage.VaultStorage storage $ = NewTradeV2VaultStorage.s();
        if (IERC721(nft).ownerOf(nftId) != address(this)) revert TransferMismatch();
        for (uint256 i; i < es.length; ++i) {
            ManifestEntry calldata e = es[i];
            if (e.kind == AssetKind.ERC20) {
                if (IERC20(e.token).balanceOf(address(this)) < $.erc20Liability[e.token]) revert TransferMismatch();
            } else if (e.kind == AssetKind.ERC721) {
                if (!$.erc721Reserved[e.token][e.tokenId] || IERC721(e.token).ownerOf(e.tokenId) != address(this)) {
                    revert TransferMismatch();
                }
            } else if (IERC1155(e.token).balanceOf(address(this), e.tokenId) < $.erc1155Liability[e.token][e.tokenId]) {
                revert TransferMismatch();
            }
        }
    }

}
