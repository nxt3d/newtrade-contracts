// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

enum AssetKind {
    ERC20,
    ERC721,
    ERC1155
}

/// @notice Admission policy for one asset standard. The zero value is
/// deliberately fail-closed so unconfigured deployments accept no assets.
enum AcceptanceMode {
    Disabled,
    Allowlist,
    Wildcard
}

enum BundleState {
    None,
    Deposited,
    Listed,
    Issued,
    Redeemed,
    Reclaimed,
    /// partial-release-oct20: the claim is burned and the release has begun, but
    /// the vault still holds at least one manifest entry or the controlling NFT.
    /// Closes to Redeemed / Reclaimed through `withdrawRemaining`. Appended so
    /// every existing value keeps its number.
    Redeeming,
    Reclaiming
}

/// @notice Which exit a release belongs to. The vault records it with the
/// destinations: a redemption gates the manifest entries on the controlling
/// NFT having left (D2), a reclaim does not.
enum ReleaseMode {
    Redeem,
    Reclaim
}

enum RedemptionMode {
    FreshAccount
}

struct ManifestEntry {
    AssetKind kind;
    address token;
    uint256 tokenId;
    uint256 amount;
}

struct Payout {
    address payable recipient;
    uint256 amount;
}

struct Bundle {
    address seller;
    address controllingNFT;
    uint256 controllingTokenId;
    bytes32 manifestHash;
    uint64 custodyDeadline;
    BundleState state;
    bytes32 orderHash;
    bytes32 considerationHash;
    address paymentToken;
    uint256 price;
    uint256 orderCounter;
    uint256 orderChainId;
    uint64 issuedAt;
    address firstRecipient;
    bool everIssued;
    address accountRegistry;
    address accountProxy;
    address accountImplementation;
}

/// @notice Creator-royalty economics frozen at `list()` for one bundle. A zero
/// `router` means the bundle was listed without routing (every pre-upgrade
/// bundle, and any listing made while no router is configured) and follows the
/// legacy direct-pay path unchanged. No function may modify a written snapshot.
struct RoyaltySnapshot {
    address router;
    address creator;
    address treasury;
    uint16 serviceFeeBps;
    uint256 grossRoyalty;
    uint256 serviceFeeAmount;
    uint256 creatorNet;
}

struct V2Initialization {
    address admin;
    address treasury;
    uint96 protocolFeeBps;
    address[] paymentTokens;
    address[] assetTokens;
    AssetKind[] assetKinds;
    AcceptanceMode[3] assetAcceptanceModes;
    address accountRegistry;
    address accountProxy;
    address accountImplementation;
    address receipt;
    address vault;
    address transferValidator;
    address seaportZone;
    /// Appended last. Optional: zero leaves royalty routing disabled until the
    /// admin configures a receiver. Must be a NewTradeRoyaltyReceiver bound
    /// (or about to be bound by the bootstrap) to this escrow.
    address royaltyRouter;
}
