// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title ISeaport (Seaport 1.6 subset)
/// @notice Types and the minimal interface the escrow needs to construct,
///         validate, and cancel listings. Field order is EXACT — it is part of
///         Seaport's EIP-712 order hashing and ABI encoding and must not be
///         reordered.

enum ItemType {
    NATIVE,
    ERC20,
    ERC721,
    ERC1155,
    ERC721_WITH_CRITERIA,
    ERC1155_WITH_CRITERIA
}

enum OrderType {
    FULL_OPEN,
    PARTIAL_OPEN,
    FULL_RESTRICTED,
    PARTIAL_RESTRICTED,
    CONTRACT
}

struct OfferItem {
    ItemType itemType;
    address token;
    uint256 identifierOrCriteria;
    uint256 startAmount;
    uint256 endAmount;
}

struct ConsiderationItem {
    ItemType itemType;
    address token;
    uint256 identifierOrCriteria;
    uint256 startAmount;
    uint256 endAmount;
    address payable recipient;
}

struct OrderParameters {
    address offerer;
    address zone;
    OfferItem[] offer;
    ConsiderationItem[] consideration;
    OrderType orderType;
    uint256 startTime;
    uint256 endTime;
    bytes32 zoneHash;
    uint256 salt;
    bytes32 conduitKey;
    uint256 totalOriginalConsiderationItems;
}

struct Order {
    OrderParameters parameters;
    bytes signature;
}

struct AdvancedOrder {
    OrderParameters parameters;
    uint120 numerator;
    uint120 denominator;
    bytes signature;
    bytes extraData;
}

enum Side {
    OFFER,
    CONSIDERATION
}

struct CriteriaResolver {
    uint256 orderIndex;
    Side side;
    uint256 index;
    uint256 identifier;
    bytes32[] criteriaProof;
}

struct OrderComponents {
    address offerer;
    address zone;
    OfferItem[] offer;
    ConsiderationItem[] consideration;
    OrderType orderType;
    uint256 startTime;
    uint256 endTime;
    bytes32 zoneHash;
    uint256 salt;
    bytes32 conduitKey;
    uint256 counter;
}

interface ISeaport {
    function fulfillOrder(Order calldata order, bytes32 fulfillerConduitKey)
        external
        payable
        returns (bool fulfilled);

    function fulfillAdvancedOrder(
        AdvancedOrder calldata advancedOrder,
        CriteriaResolver[] calldata criteriaResolvers,
        bytes32 fulfillerConduitKey,
        address recipient
    ) external payable returns (bool fulfilled);

    function validate(Order[] calldata orders) external returns (bool validated);

    function cancel(OrderComponents[] calldata orders) external returns (bool cancelled);

    function getOrderHash(OrderComponents calldata order) external view returns (bytes32 orderHash);

    function getCounter(address offerer) external view returns (uint256 counter);

    function incrementCounter() external returns (uint256 newCounter);

    /// @notice Seaport's EIP-712 domain separator, read live rather than
    ///         recomputed: the escrow must sign against the separator the
    ///         deployed Seaport actually uses, on the chain it is actually on.
    function information()
        external
        view
        returns (string memory version, bytes32 domainSeparator, address conduitController);

    function getOrderStatus(bytes32 orderHash)
        external
        view
        returns (bool isValidated, bool isCancelled, uint256 totalFilled, uint256 totalSize);
}
