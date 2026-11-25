// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AcceptanceMode, ManifestEntry, ReleaseMode} from "./NewTradeV2Types.sol";

/// @notice The upgradeable vault's storage (partial-release-oct20). ONE ERC-7201
/// namespaced struct, shared by NewTradeV2VaultV2 and its linked libraries
/// (they run by delegatecall, in the proxy's storage). Layout rules, design 2A.4:
/// the struct only grows at its end; `ManifestEntry` is FROZEN (manifests are
/// arrays of it); a struct that is a direct mapping value grows at its end only;
/// an embedded struct never grows; the namespace and slot are fixed for good.
library NewTradeV2VaultStorage {
    struct Expected {
        address token;
        address operator;
        address from;
        uint256 id;
        uint256 amount;
        uint8 kind;
    }

    /// What the vault holds for a bundle: written at deposit, read at release.
    struct Custody {
        address nft;
        uint256 nftId;
        bool exists;
    }

    /// Written once by `beginRelease`; `releasedMask` grows, nothing else changes
    /// except `extrasTo` / `redirected` through the redeemer's redirect (D2-B).
    struct ReleaseRecord {
        bool initialized;
        bool redirected;
        ReleaseMode mode;
        address extrasTo;
        address nftTo;
        uint64 releasedMask;
    }

    /// @custom:storage-location erc7201:newtrade.storage.V2Vault
    struct VaultStorage {
        address controller;
        address receipt;
        bool upgradesLocked;
        bool migrationEnabled;
        AcceptanceMode[3] acceptanceModes;
        uint256 assetPolicyRevision;
        mapping(uint256 => ManifestEntry[]) manifests;
        mapping(uint256 => Custody) custody;
        mapping(uint256 => ReleaseRecord) releases;
        mapping(address => uint256) erc20Liability;
        mapping(address => mapping(uint256 => uint256)) erc1155Liability;
        mapping(address => mapping(uint256 => bool)) erc721Reserved;
        mapping(address => uint256) assetLiabilityUnits;
        mapping(address => uint8) allowlistKindPlusOne;
        mapping(address => uint8) custodyKindPlusOne;
        mapping(address => mapping(bytes32 => bool)) migrationNonces;
        Expected expected;
    }

    // keccak256(abi.encode(uint256(keccak256("newtrade.storage.V2Vault")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant VAULT_STORAGE_LOCATION = 0xf665b1e8eba6b8ee16ab9824c4ab6ffe282cc2ed5a0ef195c2f1a4c78d807200;

    function s() internal pure returns (VaultStorage storage $) {
        assembly ("memory-safe") {
            $.slot := VAULT_STORAGE_LOCATION
        }
    }
}
