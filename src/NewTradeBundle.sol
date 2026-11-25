// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Bundle} from "./NewTradeV2Types.sol";
import {ICreatorToken, ITransferValidator} from "./interfaces/ICreatorToken.sol";
import {NewTradeBundleCard} from "./NewTradeBundleCard.sol";
import {BundleImageURI} from "./BundleImageURI.sol";
import {INewTradeBundleImage} from "./interfaces/INewTradeBundleImage.sol";

/// The escrow's selectors keep their legacy `receipt` names as COMPATIBILITY
/// ALIASES: the deployed 0x3FF1...175f collection and the app's pinned escrow
/// ABI call `onReceiptFirstExit` / `receiptRoyaltyInfo` / `receipt()`, and an
/// in-place escrow upgrade must keep serving them. "Receipt" in those names
/// means this Bundle NFT.
interface IBundleController {
    function onReceiptFirstExit(address operator, address from, address to, uint256 bundleId) external;
    function getBundle(uint256 bundleId) external view returns (Bundle memory);
    function receiptRoyaltyInfo(uint256 bundleId, uint256 salePrice) external view returns (address recipient, uint256 amount);
}

/// @notice NewTrade Bundle NFT: the ERC-721C-style claim on a vault-held bundle.
/// The controller alone mints/burns; the configured validator authorizes transfers.
///
/// NAMING. "Bundle" is the product-facing concept (collection name, symbol,
/// metadata, deployment outputs). This contract supersedes the direct-deployed
/// "NewTrade Bundle Receipt V2" (NTBR2) at 0x3FF1...175f, which is NOT renamed.
///
/// UPGRADEABILITY (UUPS behind an ERC1967Proxy, like the escrow)
/// The collection address is the proxy; the implementation carries no state
/// and its initializers are disabled in the constructor. UUPS was chosen over
/// a transparent proxy so there is no third authority (a ProxyAdmin) to
/// discover, secure and hand over: the one ERC-173 owner that marketplaces
/// already resolve is also the only account that can authorize an upgrade.
/// Storage is plain sequential and APPEND-ONLY; the OpenZeppelin parents keep
/// their state in ERC-7201 namespaces so they cannot collide with it.
///
/// OWNERSHIP (ERC-173 / Ownable2Step) serves marketplace discovery and
/// upgrade authority. OpenSea Studio and the LimitBreak registry resolve
/// collection authority through `owner()`; without it a collection cannot be
/// enrolled for creator earnings or manage its registry lists. In THIS
/// implementation the owner cannot mint, burn, approve or rebind the
/// controller - those paths are escrow-only - but because the owner alone
/// authorizes upgrades it can replace this implementation with one that can.
/// The owner is therefore a fully trusted key over every Bundle NFT and, through
/// the escrow's trust in `ownerOf` and the first-exit callback, over every
/// vault-held bundle, and that trust is permanent: ownership cannot be
/// renounced, only transferred, and only by the current key. Deploy it as a
/// multisig or timelock, never a hot wallet.
/// It is deliberately distinct from the escrow's DEFAULT_ADMIN_ROLE that
/// administers fee policy.
contract NewTradeBundle is
    Initializable,
    UUPSUpgradeable,
    ERC721Upgradeable,
    Ownable2StepUpgradeable,
    IERC2981,
    ICreatorToken
{
    using Strings for uint256;

    error ControllerOnly();
    error OwnershipNotRenounceable();
    error InvalidBaseURI();
    /// A claim moves holder-to-holder only once: out of the escrow at its sale.
    error NonTransferable();

    event ImageRendererSet(address indexed previousRenderer, address indexed newRenderer);
    event ImageBaseURISet(string previousBaseURI, string newBaseURI);
    event ExternalBaseURISet(string previousBaseURI, string newBaseURI);
    /// ERC-4906: every token's metadata may have changed.
    event BatchMetadataUpdate(uint256 _fromTokenId, uint256 _toTokenId);

    /// ERC-173 interface id: owner() ^ transferOwnership(address).
    bytes4 private constant ERC173_INTERFACE_ID = 0x7f5828d0;
    /// ERC-4906 interface id.
    bytes4 private constant ERC4906_INTERFACE_ID = 0x49064906;

    /// Gas the image renderer may spend per `tokenURI`. The first renderer
    /// (NewTradeBundleImageV1) needs well under a tenth of it; a renderer that
    /// loops forever is cut here and the built-in card is used instead.
    uint256 public constant IMAGE_GAS = 2_000_000;
    /// Longest accepted image or external base URL (the bundle id is appended).
    uint256 public constant MAX_BASE_URI_BYTES = 256;

    // ---- storage: append only, never reorder or retype -------------------
    address public controller; // slot 0
    address public bootstrap; // slot 1
    address public seaport; // slot 2
    address private _transferValidator; // slot 3
    mapping(uint256 tokenId => bool notified) public firstExitNotified; // slot 4

    // ---- image configuration: an ERC-7201 namespace, NOT a sequential slot ----
    /// @custom:storage-location erc7201:newtrade.storage.NewTradeBundle.image
    struct ImageStorage {
        address renderer; // 0 = none: the built-in card
        string imageBaseURI; // "" = none; when set, image = base + id (wins over the renderer)
        string externalBaseURI; // "" = no external_url key; when set, external_url = base + id
    }

    /// keccak256(abi.encode(uint256(keccak256("newtrade.storage.NewTradeBundle.image")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant IMAGE_STORAGE_LOCATION = 0x92e9f748b197c8df37e6f357621b4b56a147841660aafbfb660fb6e6ea2d0d00;

    function _imageStorage() private pure returns (ImageStorage storage $) {
        assembly {
            $.slot := IMAGE_STORAGE_LOCATION
        }
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        // The implementation itself can never be initialized or owned, so it
        // cannot be hijacked and pointed at by anything.
        _disableInitializers();
    }

    /// @notice Configures the proxy exactly once. The deployment script passes
    /// this call to the ERC1967Proxy constructor so creation and initialization
    /// are one atomic transaction: no account can initialize the proxy first.
    /// @param owner_ Discoverable collection owner and sole upgrade authority.
    /// Never hardcoded: every deployment passes it explicitly, and a zero owner
    /// is rejected by OwnableUpgradeable.
    function initialize(address bootstrap_, address seaport_, address transferValidator_, address owner_)
        external
        initializer
    {
        if (bootstrap_ == address(0) || seaport_ == address(0) || transferValidator_.code.length == 0) {
            revert ControllerOnly();
        }
        __ERC721_init("NewTrade Bundle V2", "NTB2");
        __Ownable_init(owner_);
        __Ownable2Step_init();
        bootstrap = bootstrap_;
        seaport = seaport_;
        _transferValidator = transferValidator_;
        // Indexers learn the initial validator from this event, exactly as
        // LimitBreak's CreatorTokenBase signals its default validator.
        emit TransferValidatorUpdated(address(0), transferValidator_);
    }

    /// @notice Only the collection owner may upgrade. The escrow (controller)
    /// and its admin deliberately cannot: bundle upgrade authority and escrow
    /// fee administration are separate keys.
    function _authorizeUpgrade(address) internal override onlyOwner {}

    /// @notice An ownerless creator token can never be enrolled, managed or
    /// upgraded again, so renunciation is disabled rather than silently fatal.
    function renounceOwnership() public view override onlyOwner {
        revert OwnershipNotRenounceable();
    }

    function bindController(address controller_) external {
        if (msg.sender != bootstrap || controller != address(0) || controller_ == address(0)) revert ControllerOnly();
        controller = controller_;
    }

    function controllerMint(uint256 id) external {
        if (msg.sender != controller) revert ControllerOnly();
        _mint(controller, id);
    }

    function controllerApproveSeaport(uint256 id) external {
        if (msg.sender != controller) revert ControllerOnly();
        _approve(seaport, id, controller);
    }

    function controllerBurn(uint256 id) external {
        if (msg.sender != controller) revert ControllerOnly();
        _burn(id);
    }

    /// @notice Marketplace-facing ERC-2981: no royalty on a Bundle claim.
    /// A claim reverts for an id that does not exist (never minted, or burned at
    /// redemption) and answers (0x0, 0) for every existing one, at any price.
    /// The creator is still paid: under escrow option B the escrow quotes the
    /// CONTROLLING NFT's own ERC-2981 at list() and credits that amount to its
    /// recipient in the owed ledger at the first exit (it never reads this
    /// function). A non-zero answer here made marketplaces (OpenSea) require a
    /// direct creator payout that an escrow order cannot carry, and reject it.
    /// (zero-royalty-wrapper, item 62(3))
    function royaltyInfo(uint256 tokenId, uint256) external view returns (address recipient, uint256 amount) {
        _requireOwned(tokenId);
        return (address(0), 0);
    }

    function getTransferValidator() external view returns (address validator) {
        return _transferValidator;
    }

    /// @notice The token-id validator variant required by OpenSea's ERC-721C flow.
    function getTransferValidationFunction() external pure returns (bytes4 functionSignature, bool isViewFunction) {
        return (ITransferValidator.validateTransfer.selector, true);
    }

    /// @notice The owner (OpenSea Studio's creator-token flow) or the escrow
    /// controller may rotate the validator. A validator is never silently
    /// absent - there is no zero or code-less path and `_update` consults it on
    /// every holder-to-holder transfer - and every rotation is published through
    /// TransferValidatorUpdated. What the new validator enforces is the owner's
    /// responsibility: a permissive contract would pass this guard, so the owner
    /// is trusted not to install one. The first exit is independently bound by
    /// the escrow (conduit operator, escrow sender) regardless of the validator.
    function setTransferValidator(address validator) external {
        if ((msg.sender != controller && msg.sender != owner()) || validator.code.length == 0) revert ControllerOnly();
        address old = _transferValidator;
        _transferValidator = validator;
        emit TransferValidatorUpdated(old, validator);
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721Upgradeable, IERC165) returns (bool) {
        return interfaceId == type(IERC2981).interfaceId || interfaceId == type(ICreatorToken).interfaceId
            || interfaceId == ERC173_INTERFACE_ID || interfaceId == ERC4906_INTERFACE_ID
            || super.supportsInterface(interfaceId);
    }

    // ---- the image: modular, so a new picture never needs an upgrade -------

    // The JSON stays here. Three owner settings shape it, each announced with
    // its own event and ERC-4906 BatchMetadataUpdate:
    //   image        = imageBaseURI + id   if imageBaseURI is set,
    //                  else the renderer's answer (an on-chain SVG),
    //                  else - and whenever the chosen source is unusable - the built-in card;
    //   external_url = externalBaseURI + id, a key that is ABSENT while unset.

    /// @notice Installs the contract that draws the image when no image base URL
    /// is set (`INewTradeBundleImage`, e.g. NewTradeBundleImageV1); `address(0)`
    /// removes it. Its answer is checked on every `tokenURI` and replaced by the
    /// built-in card if unusable, so no renderer can break the metadata.
    function setImageRenderer(address renderer) external onlyOwner {
        ImageStorage storage $ = _imageStorage();
        address previous = $.renderer;
        $.renderer = renderer;
        emit ImageRendererSet(previous, renderer);
        emit BatchMetadataUpdate(0, type(uint256).max);
    }

    /// @notice Serves every image from `baseURI + bundleId` (it wins over the
    /// renderer); "" returns to the renderer / built-in card.
    function setImageBaseURI(string calldata baseURI) external onlyOwner {
        _requireBaseURI(baseURI);
        ImageStorage storage $ = _imageStorage();
        string memory previous = $.imageBaseURI;
        $.imageBaseURI = baseURI;
        emit ImageBaseURISet(previous, baseURI);
        emit BatchMetadataUpdate(0, type(uint256).max);
    }

    /// @notice Adds `"external_url": baseURI + bundleId` to every token's JSON
    /// (e.g. the app's claim page); "" removes the key again.
    function setExternalBaseURI(string calldata baseURI) external onlyOwner {
        _requireBaseURI(baseURI);
        ImageStorage storage $ = _imageStorage();
        string memory previous = $.externalBaseURI;
        $.externalBaseURI = baseURI;
        emit ExternalBaseURISet(previous, baseURI);
        emit BatchMetadataUpdate(0, type(uint256).max);
    }

    function imageRenderer() external view returns (address) {
        return _imageStorage().renderer;
    }

    function imageBaseURI() external view returns (string memory) {
        return _imageStorage().imageBaseURI;
    }

    function externalBaseURI() external view returns (string memory) {
        return _imageStorage().externalBaseURI;
    }

    /// "" (unset) or a base of any scheme: printable ASCII without `"` or `\`, at
    /// most MAX_BASE_URI_BYTES. `tokenURI` checks the result again regardless.
    function _requireBaseURI(string calldata baseURI) private pure {
        bytes memory b = bytes(baseURI);
        if (b.length != 0 && (b.length > MAX_BASE_URI_BYTES || !BundleImageURI.isAccepted(b))) {
            revert InvalidBaseURI();
        }
    }

    /// @notice Immutable, self-contained metadata that identifies this token as
    /// a NewTrade Bundle NFT rather than the underlying collection NFT.
    /// `image` is ONE key after `description`; every other byte of the JSON is
    /// what it was before the image existed (bundle-tokenuri-svg-upgrade-sep25).
    /// Its value comes from `_image`. `external_url`, right after it, is present
    /// only while an external base URL is set, so until then the JSON is exactly
    /// what it was.
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        string memory id = tokenId.toString();
        Bundle memory bundle = IBundleController(controller).getBundle(tokenId);
        uint256 chainId = block.chainid;
        address nft = bundle.controllingNFT;
        uint256 nftId = bundle.controllingTokenId;
        bytes32 manifestHash = bundle.manifestHash;
        bytes memory json = abi.encodePacked(
            '{"name":"NewTrade Bundle #',
            id,
            '","description":"NewTrade Bundle NFT: a redeem-only claim on a vault-held asset bundle. This Bundle NFT is not the underlying collection NFT. This claim can only be redeemed by its holder; it cannot be transferred or resold.",',
            '"image":"',
            _image(tokenId, nft, nftId),
            '",',
            _externalUrl(id),
            _attributes(id, nft, nftId, manifestHash),
            _properties(tokenId, chainId, nft, nftId, manifestHash),
            "}"
        );
        return string.concat("data:application/json;base64,", Base64.encode(json));
    }

    /// The image URI: `imageBaseURI + id` if a base is set; else the renderer's
    /// answer if one is installed; else the built-in card. Whichever source is
    /// chosen must yield an accepted URI (BundleImageURI: any scheme, JSON-safe,
    /// 1 B - 16 KB), or the built-in card is used.
    function _image(uint256 tokenId, address nft, uint256 nftId) private view returns (bytes memory uri) {
        ImageStorage storage $ = _imageStorage();
        bytes memory base = bytes($.imageBaseURI);
        if (base.length != 0) {
            uri = abi.encodePacked(base, tokenId.toString());
            if (BundleImageURI.isAccepted(uri)) return uri;
        } else if ($.renderer != address(0)) {
            uri = _rendered($.renderer, tokenId, nft, nftId);
            if (BundleImageURI.isAccepted(uri)) return uri;
        }
        return abi.encodePacked("data:image/svg+xml;base64,", Base64.encode(NewTradeBundleCard.svg(tokenId, nft, nftId)));
    }

    /// `"external_url":"<base><id>",` while an external base is set and the result
    /// is an accepted URI (any scheme, JSON-safe); otherwise nothing at all (the
    /// key is absent).
    function _externalUrl(string memory id) private view returns (bytes memory) {
        bytes memory base = bytes(_imageStorage().externalBaseURI);
        if (base.length == 0) return "";
        bytes memory url = abi.encodePacked(base, id);
        if (!BundleImageURI.isAccepted(url)) return "";
        return abi.encodePacked('"external_url":"', url, '",');
    }

    /// The renderer's `imageURI` answer, or "" if it failed in any way.
    ///
    /// A LOW-LEVEL staticcall, not try/catch: a try/catch still reverts the CALLER
    /// when the callee has no code or answers bytes that do not decode as a
    /// string. The return data is sized BEFORE it is copied, so an oversized
    /// answer costs nothing, and decoded by hand: offset 0x20, a length of at most
    /// BundleImageURI.MAX_BYTES, and the bytes inside the return data.
    function _rendered(address renderer, uint256 tokenId, address nft, uint256 nftId)
        private
        view
        returns (bytes memory uri)
    {
        bytes memory data = abi.encodeCall(INewTradeBundleImage.imageURI, (tokenId, nft, nftId));
        bool ok;
        uint256 size;
        assembly ("memory-safe") {
            ok := staticcall(IMAGE_GAS, renderer, add(data, 32), mload(data), 0, 0)
            size := returndatasize()
        }
        if (!ok || size < 64 || size > 64 + BundleImageURI.MAX_BYTES) return "";
        bytes memory ret = new bytes(size);
        uint256 offset;
        uint256 length;
        assembly ("memory-safe") {
            returndatacopy(add(ret, 32), 0, size)
            offset := mload(add(ret, 32))
            length := mload(add(ret, 64))
        }
        if (offset != 32 || length > size - 64) return "";
        uri = new bytes(length);
        assembly ("memory-safe") {
            mcopy(add(uri, 32), add(ret, 96), length)
        }
    }

    function _attributes(string memory id, address nft, uint256 nftId, bytes32 manifestHash)
        private
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(
            '"attributes":[{"trait_type":"Asset Type","value":"NewTrade Bundle NFT"},{"trait_type":"Bundle ID","value":"',
            id,
            '"},{"trait_type":"Original NFT Contract","value":"',
            Strings.toHexString(uint160(nft), 20),
            '"},{"trait_type":"Original NFT Token ID","value":"',
            nftId.toString(),
            '"},{"trait_type":"Manifest Hash","value":"',
            Strings.toHexString(uint256(manifestHash), 32),
            '"},{"trait_type":"Transferable","value":"No (redeem only)"}],'
        );
    }

    function _properties(uint256 tokenId, uint256 chainId, address nft, uint256 nftId, bytes32 manifestHash)
        private
        view
        returns (bytes memory)
    {
        string memory chain = chainId.toString();
        bytes memory identity = abi.encodePacked(
            '"properties":{"schema":"newtrade.bundle.v2","chain_id":"',
            chain,
            '","bundle_id":"',
            tokenId.toString(),
            '","original_nft_contract":"',
            Strings.toHexString(uint160(nft), 20),
            '","original_nft_token_id":"',
            nftId.toString()
        );
        return abi.encodePacked(
            identity,
            '","original_asset":"',
            _assetReference(chain, nft, nftId),
            '","bundle_asset":"',
            _assetReference(chain, address(this), tokenId),
            '","manifest_hash":"',
            Strings.toHexString(uint256(manifestHash), 32),
            '"}'
        );
    }

    function _assetReference(string memory chain, address collection, uint256 tokenId)
        private
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(
            "eip155:", chain, "/erc721:", Strings.toHexString(uint160(collection), 20), "/", tokenId.toString()
        );
    }

    /// @dev NON-TRANSFERABLE AFTER THE FIRST SALE (bundle-non-transferable-sep26).
    /// Mint and burn are the controller's (the escrow's) alone. The ONLY
    /// holder-to-holder move is the first exit: the escrow giving the claim to
    /// its buyer through the Seaport fill (`previous == controller`), which the
    /// ERC-721C validator still authorizes and which still notifies the escrow
    /// once. Every other transfer reverts `NonTransferable` BEFORE the validator
    /// is asked - the buyer's own transfer, an approved operator's, a second
    /// marketplace fill - so no validator setting can re-enable resale. Claims
    /// are redeem-only after the first sale: the holder redeems through the
    /// escrow, which burns the token (`controllerBurn`).
    function _update(address to, uint256 tokenId, address auth) internal override returns (address from) {
        address previous = _ownerOf(tokenId);
        if ((previous == address(0) || to == address(0)) && msg.sender != controller) {
            revert ControllerOnly();
        }

        // Mint and burn are escrow-only operations. The one holder-to-holder
        // move - out of the escrow - must be authorized by the ERC-721C-style
        // validator; any other is refused first.
        if (previous != address(0) && to != address(0)) {
            if (previous != controller) revert NonTransferable();
            ITransferValidator(_transferValidator).validateTransfer(auth, previous, to, tokenId);
        }

        from = super._update(to, tokenId, auth);
        if (from == controller && to != address(0) && !firstExitNotified[tokenId]) {
            // Set before the external callback. A callback revert rolls this
            // write and the ERC-721 transfer back atomically.
            firstExitNotified[tokenId] = true;
            IBundleController(controller).onReceiptFirstExit(auth, from, to, tokenId);
        }
    }
}
