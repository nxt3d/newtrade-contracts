// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AcceptanceMode, AssetKind, ManifestEntry, ReleaseMode} from "../NewTradeV2Types.sol";

/// @notice What NewTradeEscrowV2 asks of its vault. The upgradeable vault
/// (NewTradeV2VaultV2) implements it; the escrow stores it in the existing
/// `_vault` slot (an address; the slot and offset do not change).
///
/// partial-release-oct20 (F-01): custody leaves per entry. `beginRelease`
/// records the destinations once and attempts every entry; `releaseRemaining`
/// retries the entries named in `mask`. Both answer whether the bundle is now
/// closed (every manifest entry and the controlling NFT released).
interface INewTradeVaultV2 {
    // ---- admission policy (unchanged shape) ----
    function assetPolicyRevision() external view returns (uint256);
    function assetAcceptanceMode(AssetKind kind) external view returns (AcceptanceMode);
    function isAssetAllowlisted(address token, AssetKind kind) external view returns (bool);
    function setAssetKind(address token, AssetKind kind, bool allowed) external returns (uint256 revision);
    function setAssetAcceptanceMode(AssetKind kind, AcceptanceMode mode)
        external
        returns (AcceptanceMode oldMode, uint256 revision);
    function setMigrationEnabled(bool enabled) external;
    function migrationNonceUsed(address seller, bytes32 nonce) external view returns (bool);
    function requireBundleAllowed(uint256 bundleId, address nft) external view;

    // ---- custody in (unchanged shape) ----
    function deposit(uint256 bundleId, address seller, address nft, uint256 nftId, ManifestEntry[] calldata entries)
        external
        returns (bytes32 hash);
    function depositFromAccount(
        uint256 bundleId,
        address seller,
        address source,
        address nft,
        uint256 nftId,
        ManifestEntry[] calldata entries,
        bytes32 nonce
    ) external returns (bytes32 hash);
    function getManifest(uint256 id) external view returns (ManifestEntry[] memory);

    // ---- ERC-6551 (unchanged shape) ----
    function computeAccount(address registry, address implementation, bytes32 salt, address nft, uint256 nftId)
        external
        view
        returns (address);
    function createFreshAccount(
        address registry,
        address accountProxy,
        address implementation,
        bytes32 salt,
        address nft,
        uint256 nftId,
        address buyer
    ) external returns (address account);
    function selfBound(address account, address nft, uint256 nftId) external view returns (bool);

    // ---- custody out (per entry) ----
    /// Records `extrasTo` / `nftTo` for `bundleId` once and attempts every entry.
    function beginRelease(uint256 bundleId, ReleaseMode mode, address extrasTo, address nftTo)
        external
        returns (bool closed);
    /// Retries the entries whose bits are set in `mask` (bit 32 = the controlling
    /// NFT). `actor` is the escrow's caller; `data` empty = plain retry, anyone.
    function releaseRemaining(uint256 bundleId, uint256 mask, address actor, bytes calldata data)
        external
        returns (bool closed);
}
