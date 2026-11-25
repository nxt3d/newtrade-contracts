// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {
    AcceptanceMode,
    ManifestEntry,
    Bundle,
    RedemptionMode,
    AssetKind,
    Payout,
    RoyaltySnapshot
} from "./NewTradeV2Types.sol";
import {OrderParameters} from "./interfaces/ISeaport.sol";

interface INewTradeEscrowV2 {
    event BundleDeposited(
        uint256 indexed bundleId,
        uint256 indexed receiptId,
        address indexed seller,
        address controllingNFT,
        uint256 controllingTokenId,
        bytes32 manifestHash,
        uint64 custodyDeadline,
        address accountRegistry,
        address accountProxy,
        address accountImplementation
    );
    event ManifestAsset(
        uint256 indexed bundleId, uint256 indexed index, AssetKind kind, address token, uint256 tokenId, uint256 amount
    );
    event BundleListed(
        uint256 indexed bundleId,
        bytes32 indexed orderHash,
        bytes32 indexed considerationHash,
        address paymentToken,
        uint256 price,
        uint64 custodyDeadline,
        uint256 salt,
        uint256 counter,
        uint256 chainId,
        address protocol
    );
    event SaleConsideration(
        uint256 indexed bundleId, uint256 indexed index, address paymentToken, address indexed recipient, uint256 amount
    );
    event BundleIssued(
        uint256 indexed bundleId, bytes32 indexed orderHash, address indexed firstRecipient, uint64 issuedAt
    );
    event BundleRedeemed(
        uint256 indexed bundleId,
        address indexed holder,
        RedemptionMode mode,
        address assetDestination,
        address controllingNFT,
        uint256 controllingTokenId,
        uint64 redeemedAt
    );
    event BundleReclaimed(uint256 indexed bundleId, address indexed seller, address indexed extrasTo, uint64 reclaimedAt);
    event AssetKindAllowed(address indexed token, AssetKind kind, bool allowed);
    event AssetAcceptanceModeUpdated(
        AssetKind indexed kind, AcceptanceMode oldMode, AcceptanceMode newMode, uint256 indexed policyRevision
    );
    event AssetAllowlistMembershipUpdated(
        address indexed token, AssetKind indexed kind, bool allowed, uint256 indexed policyRevision
    );
    event PaymentTokenAllowed(address indexed token, bool allowed);
    event ProtocolFeeUpdated(uint96 oldFeeBps, uint96 newFeeBps);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event FreshAccountPolicyUpdated(
        address indexed registry, address indexed accountProxy, address indexed implementation, bool enabled
    );
    event TrustedAccountCodeUpdated(address indexed target, bool indexed registry, bytes32 codehash, bool trusted);
    event BundleMigrated(
        uint256 indexed bundleId, address indexed sourceAccount, address indexed seller, bytes32 nonce
    );
    event UpgradesLocked();
    /// RETIRED ROUTING (option B, escrow-option-b-sep26): these three events are
    /// no longer emitted; kept so historical logs keep decoding against this ABI.
    event RoyaltyServiceFeeUpdated(uint16 oldFeeBps, uint16 newFeeBps);
    event RoyaltyRouterUpdated(address indexed oldRouter, address indexed newRouter);
    /// Emitted once per routed listing with the frozen split the first exit will credit.
    event RoyaltyRouted(
        uint256 indexed bundleId,
        address indexed router,
        address indexed creator,
        address treasury,
        uint16 serviceFeeBps,
        uint256 grossRoyalty,
        uint256 serviceFeeAmount,
        uint256 creatorNet
    );

    function deposit(
        address controllingNFT,
        uint256 controllingTokenId,
        ManifestEntry[] calldata entries,
        uint64 custodyDeadline
    ) external returns (uint256 bundleId);
    function depositFromAccount(
        address sourceAccount,
        address controllingNFT,
        uint256 controllingTokenId,
        ManifestEntry[] calldata entries,
        uint64 custodyDeadline,
        bytes32 nonce
    ) external returns (uint256 bundleId);
    function list(
        uint256 bundleId,
        address paymentToken,
        uint256 price,
        uint64 custodyDeadline,
        uint16 maxRoyaltyBps,
        Payout[] calldata exactConsideration
    ) external returns (bytes32 orderHash);
    function redeemToFreshAccount(uint256 bundleId, bytes32 holderSalt) external returns (address account);
    /// @notice Seller exit for an expired, never-issued bundle: controlling NFT to the seller,
    /// manifest assets to `extrasTo` (seller's choice; zero reverts `ZeroAddress`). See NewTradeEscrowV2.reclaim.
    function reclaim(uint256 bundleId, address extrasTo) external;
    function onReceiptFirstExit(address operator, address from, address to, uint256 receiptId) external;
    function previewOrderParameters(
        uint256 bundleId,
        address paymentToken,
        uint256 price,
        uint64 custodyDeadline,
        uint16 maxRoyaltyBps,
        Payout[] calldata exactConsideration,
        uint64 startTime
    ) external view returns (OrderParameters memory);
    function quotePrimaryFees(uint256 bundleId, uint256 price)
        external
        view
        returns (address treasury, uint256 protocolAmount, address royaltyRecipient, uint256 royaltyAmount);
    function getOrder(uint256 bundleId)
        external
        view
        returns (
            OrderParameters memory parameters,
            uint256 counter,
            bytes32 orderHash,
            uint256 chainId,
            address protocol
        );
    function computeManifestHash(address controllingNFT, uint256 controllingTokenId, ManifestEntry[] calldata entries)
        external
        view
        returns (bytes32);
    function computeFreshAccount(uint256 bundleId, address holder, bytes32 holderSalt)
        external
        view
        returns (address account, bytes32 fullSalt);
    function getBundle(uint256 bundleId) external view returns (Bundle memory);
    function getManifest(uint256 bundleId) external view returns (ManifestEntry[] memory);
    function getPayouts(uint256 bundleId) external view returns (Payout[] memory);
    function getRoyaltySnapshot(uint256 bundleId) external view returns (RoyaltySnapshot memory);
    /// @notice Permissionless: pays `account`'s credit in `token` TO `account` (option B).
    function withdrawFor(address account, address token) external returns (uint256 amount);
    function receiptMetadata(uint256 bundleId)
        external
        view
        returns (uint256 chainId, address controllingNFT, uint256 controllingTokenId, bytes32 manifestHash);
    function receipt() external view returns (address);
    function vault() external view returns (address);
    function migrationNonceUsed(address seller, bytes32 nonce) external view returns (bool);
    function isPaymentTokenAllowed(address token) external view returns (bool);
    function setAssetAcceptanceMode(AssetKind kind, AcceptanceMode mode) external;
    function setAssetKind(address token, AssetKind kind, bool allowed) external;
    function setPaymentTokenAllowed(address token, bool allowed) external;
    function setMigrationEnabled(bool enabled) external;
    function setTrustedAccountCode(address target, bool registry, bool trusted) external;
    function trustedAccountCode(address target, bool registry) external view returns (bool);
}
