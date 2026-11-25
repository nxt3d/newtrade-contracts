// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {AcceptanceMode, AssetKind, ManifestEntry} from "../../src/NewTradeV2Types.sol";
import {
    IERC6551Registry,
    IERC6551Account,
    IERC6551OwnerAccount,
    IERC6551ExecutableAccount,
    ITokenboundAccountProxy
} from "../../src/interfaces/IERC6551.sol";

/// @notice Dedicated asset vault for one V2 escrow deployment. It has no admin
/// or rescue path; only its immutable escrow controller can fund or exit bundles.
contract NewTradeV2Vault is IERC721Receiver, IERC1155Receiver {
    using SafeERC20 for IERC20;

    bytes4 private constant VALID_SIGNER_MAGIC = 0x523e3260;

    error ControllerOnly();
    error InvalidManifest();
    error UnsupportedAsset();
    error AssetReserved();
    error TransferMismatch();
    error InvalidCallback();
    error MigrationUnavailable();

    uint256 public constant MAX_MANIFEST_ENTRIES = 32;
    address public controller;
    address public immutable bootstrap;
    address public immutable receipt;
    mapping(uint256 => ManifestEntry[]) private manifests;
    mapping(address => uint256) public erc20Liability;
    mapping(address => mapping(uint256 => uint256)) public erc1155Liability;
    mapping(address => mapping(uint256 => bool)) public erc721Reserved;
    mapping(address => uint256) public assetLiabilityUnits;
    // Allowlist membership is configuration. custodyKindPlusOne is the single
    // accounting classification pinned while a token has outstanding units.
    mapping(address => uint8) private allowlistKindPlusOne;
    mapping(address => uint8) private custodyKindPlusOne;
    AcceptanceMode[3] private acceptanceModes;
    uint256 private _assetPolicyRevision;
    bool private migrationEnabled;
    mapping(address => mapping(bytes32 => bool)) private migrationNonces;

    struct Expected {
        address token;
        address operator;
        address from;
        uint256 id;
        uint256 amount;
        uint8 kind;
    }

    Expected private expected;

    modifier onlyController() {
        if (msg.sender != controller) revert ControllerOnly();
        _;
    }

    constructor(
        address bootstrap_,
        address receipt_,
        address[] memory tokens,
        AssetKind[] memory kinds,
        AcceptanceMode[3] memory modes
    ) {
        if (tokens.length != kinds.length) revert InvalidManifest();
        bootstrap = bootstrap_;
        receipt = receipt_;
        acceptanceModes = modes;
        _assetPolicyRevision = 1;
        for (uint256 i; i < tokens.length; ++i) {
            _requireEligible(tokens[i], kinds[i]);
            uint8 next = uint8(kinds[i]) + 1;
            if (allowlistKindPlusOne[tokens[i]] != 0 && allowlistKindPlusOne[tokens[i]] != next) {
                revert InvalidManifest();
            }
            allowlistKindPlusOne[tokens[i]] = next;
            custodyKindPlusOne[tokens[i]] = next;
        }
    }

    function bindController(address controller_) external {
        if (msg.sender != bootstrap || controller != address(0) || controller_ == address(0)) revert ControllerOnly();
        controller = controller_;
    }

    function setAssetKind(address token, AssetKind kind, bool allowed)
        external
        onlyController
        returns (uint256 revision)
    {
        _requireEligible(token, kind);
        uint8 oldMembership = allowlistKindPlusOne[token];
        uint8 next = uint8(kind) + 1;
        if (allowed) {
            uint8 pinned = custodyKindPlusOne[token];
            if (pinned != 0 && pinned != next && assetLiabilityUnits[token] != 0) revert AssetReserved();
            if (oldMembership == next && pinned == next) return _assetPolicyRevision;
            allowlistKindPlusOne[token] = next;
            if (assetLiabilityUnits[token] == 0) custodyKindPlusOne[token] = next;
        } else {
            if (oldMembership != next) return _assetPolicyRevision;
            allowlistKindPlusOne[token] = 0;
        }
        revision = ++_assetPolicyRevision;
    }

    function setAssetAcceptanceMode(AssetKind kind, AcceptanceMode mode)
        external
        onlyController
        returns (AcceptanceMode oldMode, uint256 revision)
    {
        oldMode = acceptanceModes[uint8(kind)];
        if (oldMode == mode) return (oldMode, _assetPolicyRevision);
        acceptanceModes[uint8(kind)] = mode;
        revision = ++_assetPolicyRevision;
    }

    function assetAcceptanceMode(AssetKind kind) external view returns (AcceptanceMode) {
        return acceptanceModes[uint8(kind)];
    }

    function assetPolicyRevision() external view returns (uint256) {
        return _assetPolicyRevision;
    }

    function isAssetAllowlisted(address token, AssetKind kind) public view returns (bool) {
        return allowlistKindPlusOne[token] == uint8(kind) + 1;
    }

    function custodyAssetKind(address token) external view returns (AssetKind kind, bool configured) {
        uint8 value = custodyKindPlusOne[token];
        if (value == 0) return (AssetKind.ERC20, false);
        return (AssetKind(value - 1), true);
    }

    function isAllowed(address token, AssetKind kind) public view returns (bool) {
        if (!_eligible(token, kind)) return false;
        AcceptanceMode mode = acceptanceModes[uint8(kind)];
        if (mode == AcceptanceMode.Disabled) return false;
        if (mode == AcceptanceMode.Allowlist && !isAssetAllowlisted(token, kind)) return false;
        uint8 pinned = custodyKindPlusOne[token];
        return pinned == 0 || pinned == uint8(kind) + 1 || assetLiabilityUnits[token] == 0;
    }

    function requireBundleAllowed(uint256 bundleId, address nft) external view {
        if (!isAllowed(nft, AssetKind.ERC721)) revert UnsupportedAsset();
        ManifestEntry[] storage es = manifests[bundleId];
        for (uint256 i; i < es.length; ++i) {
            if (!isAllowed(es[i].token, es[i].kind)) revert UnsupportedAsset();
        }
    }

    function deposit(uint256 bundleId, address seller, address nft, uint256 nftId, ManifestEntry[] calldata entries)
        external
        onlyController
        returns (bytes32 hash)
    {
        return _deposit(bundleId, seller, seller, nft, nftId, entries);
    }

    function depositFromAccount(
        uint256 bundleId,
        address seller,
        address source,
        address nft,
        uint256 nftId,
        ManifestEntry[] calldata entries,
        bytes32 nonce
    ) external onlyController returns (bytes32 hash) {
        if (entries.length > MAX_MANIFEST_ENTRIES || erc721Reserved[nft][nftId]) {
            revert InvalidManifest();
        }
        _validateAndPin(entries, nft, nftId);
        _authenticateMigration(seller, source, nft, nftId, nonce);
        hash = keccak256(abi.encode(uint256(2), block.chainid, controller, nft, nftId, entries));
        erc721Reserved[nft][nftId] = true;
        assetLiabilityUnits[nft]++;
        for (uint256 i; i < entries.length; ++i) {
            manifests[bundleId].push(entries[i]);
        }
        _pull721(nft, nftId, seller, address(this));
        if (IERC721(nft).ownerOf(nftId) != address(this)) revert TransferMismatch();
        for (uint256 i; i < entries.length; ++i) {
            _executeTransfer(entries[i], source);
        }
        _postcheck(entries, nft, nftId);
    }

    function _authenticateMigration(address seller, address source, address nft, uint256 nftId, bytes32 nonce)
        private
    {
        if (
            !migrationEnabled || migrationNonces[seller][nonce] || source.code.length == 0 || source == seller
                || source == address(this) || source == controller || source == receipt
                || IERC721(nft).ownerOf(nftId) != seller
        ) revert MigrationUnavailable();
        try IERC6551Account(source).token() returns (uint256 c, address t, uint256 i) {
            if (c != block.chainid || t != nft || i != nftId) revert MigrationUnavailable();
        } catch {
            revert MigrationUnavailable();
        }
        migrationNonces[seller][nonce] = true;
    }

    function setMigrationEnabled(bool enabled) external onlyController {
        migrationEnabled = enabled;
    }

    function migrationNonceUsed(address seller, bytes32 nonce) external view returns (bool) {
        return migrationNonces[seller][nonce];
    }

    function migrationIsEnabled() external view returns (bool) {
        return migrationEnabled;
    }

    function computeAccount(address registry, address implementation, bytes32 salt, address nft, uint256 nftId)
        external
        view
        returns (address)
    {
        return IERC6551Registry(registry).account(implementation, salt, block.chainid, nft, nftId);
    }

    function createFreshAccount(
        address registry,
        address accountProxy,
        address implementation,
        bytes32 salt,
        address nft,
        uint256 nftId,
        address buyer
    ) external onlyController returns (address account) {
        account = IERC6551Registry(registry).account(accountProxy, salt, block.chainid, nft, nftId);
        if (
            account.code.length != 0 || account == address(this) || account == controller || account == receipt
                || account == buyer
        ) revert MigrationUnavailable();
        address made = IERC6551Registry(registry).createAccount(accountProxy, salt, block.chainid, nft, nftId);
        if (made != account || made.code.length == 0) revert MigrationUnavailable();

        // Step 1: bind Tokenbound's fresh outer proxy to the approved account logic.
        ITokenboundAccountProxy(account).initialize(implementation);

        // Step 2: prove the initialized account is permanently bound to this NFT.
        (uint256 c, address t, uint256 i) = IERC6551Account(account).token();
        if (c != block.chainid || t != nft || i != nftId) revert MigrationUnavailable();
    }

    function accountOwner(address account) external view returns (address) {
        return IERC6551OwnerAccount(account).owner();
    }

    function accountValidSigner(address account, address signer) external view returns (bool) {
        return IERC6551Account(account).isValidSigner(signer, "") == VALID_SIGNER_MAGIC;
    }

    function selfBound(address account, address nft, uint256 nftId) external view returns (bool yes) {
        if (account.code.length == 0) return false;
        try IERC6551Account(account).token() returns (uint256 c, address t, uint256 i) {
            return c == block.chainid && t == nft && i == nftId;
        } catch {
            return false;
        }
    }

    function _deposit(
        uint256 bundleId,
        address seller,
        address source,
        address nft,
        uint256 nftId,
        ManifestEntry[] calldata entries
    ) private returns (bytes32 hash) {
        if (entries.length > MAX_MANIFEST_ENTRIES || erc721Reserved[nft][nftId]) revert InvalidManifest();
        _validateAndPin(entries, nft, nftId);
        if (IERC721(nft).ownerOf(nftId) != seller) revert InvalidManifest();
        hash = keccak256(abi.encode(uint256(2), block.chainid, controller, nft, nftId, entries));
        erc721Reserved[nft][nftId] = true;
        assetLiabilityUnits[nft]++;
        for (uint256 i; i < entries.length; ++i) {
            manifests[bundleId].push(entries[i]);
            _pull(entries[i], source);
        }
        _pull721(nft, nftId, seller, address(this));
        _postcheck(entries, nft, nftId);
    }

    function _validateAndPin(ManifestEntry[] calldata es, address nft, uint256 nftId) private {
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
                    && (e.amount != 1 || (e.token == nft && e.tokenId == nftId) || erc721Reserved[e.token][e.tokenId])
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
        if (!isAllowed(token, kind)) revert UnsupportedAsset();
        uint8 next = uint8(kind) + 1;
        uint8 pinned = custodyKindPlusOne[token];
        if (pinned != 0 && pinned != next && assetLiabilityUnits[token] != 0) revert AssetReserved();
        custodyKindPlusOne[token] = next;
    }

    function _requireEligible(address token, AssetKind kind) private view {
        if (!_eligible(token, kind)) revert UnsupportedAsset();
    }

    function _eligible(address token, AssetKind kind) private view returns (bool) {
        if (
            token == address(0) || token.code.length == 0 || token == address(this) || token == controller
                || token == receipt
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

    function _pull(ManifestEntry calldata e, address source) private {
        if (e.kind == AssetKind.ERC20) {
            uint256 b = IERC20(e.token).balanceOf(address(this));
            uint256 f = IERC20(e.token).balanceOf(source);
            if (f < e.amount) revert TransferMismatch();
            IERC20(e.token).safeTransferFrom(source, address(this), e.amount);
            if (
                IERC20(e.token).balanceOf(source) != f - e.amount
                    || IERC20(e.token).balanceOf(address(this)) != b + e.amount
            ) revert TransferMismatch();
            erc20Liability[e.token] += e.amount;
            assetLiabilityUnits[e.token] += e.amount;
        } else if (e.kind == AssetKind.ERC721) {
            if (IERC721(e.token).ownerOf(e.tokenId) != source) revert TransferMismatch();
            erc721Reserved[e.token][e.tokenId] = true;
            assetLiabilityUnits[e.token]++;
            _pull721(e.token, e.tokenId, source, address(this));
        } else {
            uint256 b = IERC1155(e.token).balanceOf(address(this), e.tokenId);
            uint256 f = IERC1155(e.token).balanceOf(source, e.tokenId);
            if (f < e.amount) revert TransferMismatch();
            expected = Expected(e.token, address(this), source, e.tokenId, e.amount, uint8(AssetKind.ERC1155) + 1);
            IERC1155(e.token).safeTransferFrom(source, address(this), e.tokenId, e.amount, "");
            if (expected.kind != 0) revert TransferMismatch();
            if (
                IERC1155(e.token).balanceOf(source, e.tokenId) != f - e.amount
                    || IERC1155(e.token).balanceOf(address(this), e.tokenId) != b + e.amount
            ) revert TransferMismatch();
            erc1155Liability[e.token][e.tokenId] += e.amount;
            assetLiabilityUnits[e.token] += e.amount;
        }
    }

    function _pull721(address token, uint256 id, address source, address operator) private {
        if (IERC721(token).ownerOf(id) != source) revert TransferMismatch();
        expected = Expected(token, operator, source, id, 1, uint8(AssetKind.ERC721) + 1);
        IERC721(token).safeTransferFrom(source, address(this), id);
        if (expected.kind != 0 || IERC721(token).ownerOf(id) != address(this)) revert TransferMismatch();
    }

    function _executeTransfer(ManifestEntry calldata e, address source) private {
        if (e.kind == AssetKind.ERC20) {
            uint256 b = IERC20(e.token).balanceOf(address(this));
            uint256 f = IERC20(e.token).balanceOf(source);
            if (f < e.amount) revert TransferMismatch();
            IERC6551ExecutableAccount(source).execute(
                e.token, 0, abi.encodeCall(IERC20.transfer, (address(this), e.amount)), 0
            );
            if (
                IERC20(e.token).balanceOf(source) != f - e.amount
                    || IERC20(e.token).balanceOf(address(this)) != b + e.amount
            ) revert TransferMismatch();
            erc20Liability[e.token] += e.amount;
            assetLiabilityUnits[e.token] += e.amount;
        } else if (e.kind == AssetKind.ERC721) {
            if (IERC721(e.token).ownerOf(e.tokenId) != source) revert TransferMismatch();
            erc721Reserved[e.token][e.tokenId] = true;
            assetLiabilityUnits[e.token]++;
            expected = Expected(e.token, source, source, e.tokenId, 1, uint8(AssetKind.ERC721) + 1);
            IERC6551ExecutableAccount(source).execute(
                e.token,
                0,
                abi.encodeWithSignature("safeTransferFrom(address,address,uint256)", source, address(this), e.tokenId),
                0
            );
            if (expected.kind != 0 || IERC721(e.token).ownerOf(e.tokenId) != address(this)) revert TransferMismatch();
        } else {
            uint256 b = IERC1155(e.token).balanceOf(address(this), e.tokenId);
            uint256 f = IERC1155(e.token).balanceOf(source, e.tokenId);
            if (f < e.amount) revert TransferMismatch();
            expected = Expected(e.token, source, source, e.tokenId, e.amount, uint8(AssetKind.ERC1155) + 1);
            IERC6551ExecutableAccount(source).execute(
                e.token,
                0,
                abi.encodeCall(IERC1155.safeTransferFrom, (source, address(this), e.tokenId, e.amount, "")),
                0
            );
            if (
                expected.kind != 0 || IERC1155(e.token).balanceOf(source, e.tokenId) != f - e.amount
                    || IERC1155(e.token).balanceOf(address(this), e.tokenId) != b + e.amount
            ) revert TransferMismatch();
            erc1155Liability[e.token][e.tokenId] += e.amount;
            assetLiabilityUnits[e.token] += e.amount;
        }
    }

    function _postcheck(ManifestEntry[] calldata es, address nft, uint256 nftId) private view {
        if (IERC721(nft).ownerOf(nftId) != address(this)) revert TransferMismatch();
        for (uint256 i; i < es.length; ++i) {
            ManifestEntry calldata e = es[i];
            if (e.kind == AssetKind.ERC20) {
                if (IERC20(e.token).balanceOf(address(this)) < erc20Liability[e.token]) revert TransferMismatch();
            } else if (e.kind == AssetKind.ERC721) {
                if (!erc721Reserved[e.token][e.tokenId] || IERC721(e.token).ownerOf(e.tokenId) != address(this)) {
                    revert TransferMismatch();
                }
            } else if (IERC1155(e.token).balanceOf(address(this), e.tokenId) < erc1155Liability[e.token][e.tokenId]) {
                revert TransferMismatch();
            }
        }
    }

    function release(uint256 bundleId, address nft, uint256 nftId, address extrasTo, address nftTo)
        external
        onlyController
    {
        ManifestEntry[] storage es = manifests[bundleId];
        for (uint256 i; i < es.length; ++i) {
            _release(es[i], extrasTo);
        }
        erc721Reserved[nft][nftId] = false;
        assetLiabilityUnits[nft]--;
        IERC721(nft).safeTransferFrom(address(this), nftTo, nftId);
        if (IERC721(nft).ownerOf(nftId) != nftTo) revert TransferMismatch();
    }

    function _release(ManifestEntry storage e, address to) private {
        if (e.kind == AssetKind.ERC20) {
            uint256 a = IERC20(e.token).balanceOf(address(this));
            uint256 d = IERC20(e.token).balanceOf(to);
            erc20Liability[e.token] -= e.amount;
            assetLiabilityUnits[e.token] -= e.amount;
            IERC20(e.token).safeTransfer(to, e.amount);
            if (
                IERC20(e.token).balanceOf(address(this)) != a - e.amount
                    || IERC20(e.token).balanceOf(to) != d + e.amount
            ) revert TransferMismatch();
        } else if (e.kind == AssetKind.ERC721) {
            erc721Reserved[e.token][e.tokenId] = false;
            assetLiabilityUnits[e.token]--;
            IERC721(e.token).safeTransferFrom(address(this), to, e.tokenId);
            if (IERC721(e.token).ownerOf(e.tokenId) != to) revert TransferMismatch();
        } else {
            uint256 a = IERC1155(e.token).balanceOf(address(this), e.tokenId);
            uint256 d = IERC1155(e.token).balanceOf(to, e.tokenId);
            erc1155Liability[e.token][e.tokenId] -= e.amount;
            assetLiabilityUnits[e.token] -= e.amount;
            IERC1155(e.token).safeTransferFrom(address(this), to, e.tokenId, e.amount, "");
            if (
                IERC1155(e.token).balanceOf(address(this), e.tokenId) != a - e.amount
                    || IERC1155(e.token).balanceOf(to, e.tokenId) != d + e.amount
            ) revert TransferMismatch();
        }
    }

    function getManifest(uint256 id) external view returns (ManifestEntry[] memory) {
        return manifests[id];
    }

    function onERC721Received(address operator, address from, uint256 id, bytes calldata) external returns (bytes4) {
        Expected memory e = expected;
        if (
            operator != e.operator || e.kind != uint8(AssetKind.ERC721) + 1 || e.token != msg.sender || e.from != from
                || e.id != id || e.amount != 1
        ) revert InvalidCallback();
        delete expected;
        return IERC721Receiver.onERC721Received.selector;
    }

    function onERC1155Received(address operator, address from, uint256 id, uint256 amount, bytes calldata)
        external
        returns (bytes4)
    {
        Expected memory e = expected;
        if (
            operator != e.operator || e.kind != uint8(AssetKind.ERC1155) + 1 || e.token != msg.sender || e.from != from
                || e.id != id || e.amount != amount
        ) revert InvalidCallback();
        delete expected;
        return IERC1155Receiver.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert InvalidCallback();
    }

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == type(IERC721Receiver).interfaceId || id == type(IERC1155Receiver).interfaceId
            || id == type(IERC165).interfaceId;
    }
}
