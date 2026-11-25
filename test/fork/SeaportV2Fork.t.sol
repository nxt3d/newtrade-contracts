// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {NewTradeEscrowV2} from "../../src/NewTradeEscrowV2.sol";
import {NewTradeBundle} from "../../src/NewTradeBundle.sol";
import {BundleDeploy} from "../helpers/BundleDeploy.sol";
import {NewTradeV2Vault} from "../legacy/NewTradeV2Vault.sol";
import {NewTradeV2VaultV2} from "../../src/NewTradeV2VaultV2.sol";
import {VaultV2Deploy} from "../helpers/VaultV2Deploy.sol";
import {
    AcceptanceMode,
    AssetKind,
    BundleState,
    ManifestEntry,
    Payout,
    V2Initialization
} from "../../src/NewTradeV2Types.sol";
import {
    ISeaport,
    Order,
    AdvancedOrder,
    CriteriaResolver,
    OrderParameters,
    OrderComponents,
    OfferItem,
    ConsiderationItem,
    ItemType,
    OrderType
} from "../../src/interfaces/ISeaport.sol";
import {MockERC20, MockERC721} from "../mocks/TokenMocks.sol";
import {Mock6551Registry, Mock6551Implementation} from "../helpers/ERC6551Mocks.sol";

struct FulfillmentComponent {
    uint256 orderIndex;
    uint256 itemIndex;
}

struct ReceivedItem {
    ItemType itemType;
    address token;
    uint256 identifier;
    uint256 amount;
    address payable recipient;
}

struct Execution {
    ReceivedItem item;
    address offerer;
    bytes32 conduitKey;
}

/// @dev Declared in the test rather than in src/interfaces/ISeaport.sol on
/// purpose: the aggregation case needs this surface, and src must stay
/// byte-identical to the commit under independent review.
interface ISeaportAggregate {
    function fulfillAvailableAdvancedOrders(
        AdvancedOrder[] calldata advancedOrders,
        CriteriaResolver[] calldata criteriaResolvers,
        FulfillmentComponent[][] calldata offerFulfillments,
        FulfillmentComponent[][] calldata considerationFulfillments,
        bytes32 fulfillerConduitKey,
        address recipient,
        uint256 maximumFulfilled
    ) external payable returns (bool[] memory availableOrders, Execution[] memory executions);
}

interface ISeaportInformation {
    function information()
        external
        view
        returns (string memory version, bytes32 domainSeparator, address conduitController);
}

/// @dev Local fork fixture that returns the selector Seaport supplied. This
/// isolates Seaport's restricted-order mechanics from SignedZone API-issued
/// extraData, which requires an offchain OpenSea authorization.
contract ForkPermissiveZone {
    fallback() external {
        assembly ("memory-safe") {
            mstore(0, shl(224, shr(224, calldataload(0))))
            return(0, 32)
        }
    }
}

contract ForkPermissiveTransferValidator {
    function validateTransfer(address, address, address, uint256) external pure {}
}

contract SeaportV2ForkTest is Test {
    address constant SEAPORT = 0x0000000000000068F116a894984e2DB1123eB395;
    address constant SIGNED_ZONE = 0x000056F7000000EcE9003ca63978907a00FFD100;
    address constant STRICT_TRANSFER_VALIDATOR = 0xA000027A9B2802E1ddf7000061001e5c005A0000;
    address seller = address(0xA11CE);
    address buyer = address(0xB0B);
    address recipient = address(0xBEEF);
    address treasury = address(0xFEE);
    uint256 constant PRICE = 1 ether;
    NewTradeEscrowV2 escrow;
    NewTradeBundle receipt;
    MockERC20 payment;
    MockERC721 nft;
    bool forked;
    uint64 deadline;

    function setUp() public {
        forked = SEAPORT.code.length > 0;
        if (!forked) return;
        payment = new MockERC20("Pay", "PAY", 18);
        nft = new MockERC721();
        address[] memory pays = new address[](2);
        pays[0] = address(payment);
        pays[1] = address(0);
        address[] memory assets = new address[](1);
        assets[0] = address(nft);
        AssetKind[] memory kinds = new AssetKind[](1);
        kinds[0] = AssetKind.ERC721;
        AcceptanceMode[3] memory modes = [AcceptanceMode.Allowlist, AcceptanceMode.Allowlist, AcceptanceMode.Allowlist];
        Mock6551Registry registry = new Mock6551Registry();
        Mock6551Implementation implementation = new Mock6551Implementation();
        ForkPermissiveZone zone = new ForkPermissiveZone();
        ForkPermissiveTransferValidator validator = new ForkPermissiveTransferValidator();
        receipt = BundleDeploy.deploy(address(this), SEAPORT, address(validator), address(this));
        NewTradeV2Vault legacyVault = new NewTradeV2Vault(address(this), address(receipt), assets, kinds, modes);
        V2Initialization memory c = V2Initialization(
            address(this),
            treasury,
            250,
            pays,
            assets,
            kinds,
            modes,
            address(registry),
            address(implementation),
            address(implementation),
            address(receipt),
            address(legacyVault),
            address(validator),
            address(zone),
            address(0)
        );
        NewTradeEscrowV2 impl = new NewTradeEscrowV2();
        escrow =
            NewTradeEscrowV2(payable(address(new ERC1967Proxy(address(impl), abi.encodeCall(NewTradeEscrowV2.initialize, (c))))));
        receipt.bindController(address(escrow));
        legacyVault.bindController(address(escrow));
        NewTradeV2VaultV2 vault = VaultV2Deploy.switchEscrowMirroring(escrow, address(receipt), assets, kinds, modes);
        nft.mint(seller, 1);
        vm.prank(seller);
        nft.approve(address(vault), 1);
        deadline = uint64(block.timestamp + 1 days);
        vm.prank(seller);
        escrow.deposit(address(nft), 1, new ManifestEntry[](0), deadline);
    }

    // escrow-fee-from-proceeds-sep25: the protocol fee (250 bps = 0.025) is not a
    // consideration item. The escrow item carries it and the first exit deducts it,
    // so the fee stays in the escrow as surplus. The second recipient stands in for
    // a marketplace fee (bundle #2's shape), which gives Seaport two recipients to
    // aggregate.
    address marketFee = address(0x0FEE5EA);
    uint256 constant ITEM0 = 0.99 ether;
    uint256 constant MARKET_FEE = 0.01 ether;
    uint256 constant PROTOCOL_FEE = 0.025 ether;
    uint256 constant SELLER_NET = ITEM0 - PROTOCOL_FEE; // 0.965

    function ps() internal view returns (Payout[] memory out) {
        out = new Payout[](2);
        out[0] = Payout(payable(address(escrow)), ITEM0);
        out[1] = Payout(payable(marketFee), MARKET_FEE);
    }

    function listed() internal returns (OrderParameters memory p) {
        vm.prank(seller);
        escrow.list(1, address(payment), PRICE, deadline, 0, ps());
        (p,,,,) = escrow.getOrder(1);
    }

    function fund() internal {
        payment.mint(buyer, PRICE + 1 ether);
        vm.prank(buyer);
        payment.approve(SEAPORT, type(uint256).max);
    }

    function test_RealSeaportV16_EmptySignaturePrevalidatedRestrictedSale() public {
        if (!forked) {
            vm.skip(true);
            return;
        }
        OrderParameters memory p = listed();
        fund();
        vm.prank(buyer);
        assertTrue(ISeaport(SEAPORT).fulfillOrder(Order(p, ""), bytes32(0)));
        assertEq(receipt.ownerOf(1), buyer);
        assertEq(uint8(escrow.getBundle(1).state), uint8(BundleState.Issued));
        // ERC20 payout, against REAL Seaport: the marketplace fee is paid directly
        // as a consideration item; the escrow item arrives at the escrow - the
        // offerer - and the seller is credited item0 - fee for withdrawal. The
        // treasury is paid nothing at sale time.
        assertEq(payment.balanceOf(marketFee), MARKET_FEE);
        assertEq(payment.balanceOf(treasury), 0);
        assertEq(payment.balanceOf(address(escrow)), ITEM0);
        assertEq(payment.balanceOf(seller), 0);
        assertEq(escrow.claimable(seller, address(payment)), SELLER_NET);
        assertEq(escrow.totalOwed(address(payment)), SELLER_NET);
        vm.prank(seller);
        assertEq(escrow.withdraw(address(payment)), SELLER_NET);
        assertEq(payment.balanceOf(seller), SELLER_NET);
        assertEq(payment.balanceOf(address(escrow)), PROTOCOL_FEE, "the fee stays as surplus");
        assertEq(escrow.totalOwed(address(payment)), 0);
        // The credit is consumed. A second withdrawal REVERTS rather than
        // quietly transferring nothing, so a caller cannot mistake an empty
        // balance for a successful payout.
        assertEq(escrow.claimable(seller, address(payment)), 0);
        vm.prank(seller);
        vm.expectRevert(NewTradeEscrowV2.InvalidState.selector);
        escrow.withdraw(address(payment));
        assertEq(payment.balanceOf(seller), SELLER_NET);
        // Nobody else can withdraw against this sale.
        vm.prank(buyer);
        vm.expectRevert(NewTradeEscrowV2.InvalidState.selector);
        escrow.withdraw(address(payment));
    }

    function test_RealSeaportV16_RecipientDifferentFromFulfiller() public {
        if (!forked) {
            vm.skip(true);
            return;
        }
        OrderParameters memory p = listed();
        fund();
        AdvancedOrder memory a = AdvancedOrder(p, 1, 1, "", "");
        CriteriaResolver[] memory criteria = new CriteriaResolver[](0);
        vm.prank(buyer);
        assertTrue(ISeaport(SEAPORT).fulfillAdvancedOrder(a, criteria, bytes32(0), recipient));
        assertEq(receipt.ownerOf(1), recipient);
        assertEq(escrow.getBundle(1).firstRecipient, recipient);
    }

    function test_RealSeaportV16_NativePayment() public {
        if (!forked) {
            vm.skip(true);
            return;
        }
        vm.prank(seller);
        escrow.list(1, address(0), PRICE, deadline, 0, ps());
        (OrderParameters memory p,,,,) = escrow.getOrder(1);
        vm.deal(buyer, PRICE);
        uint256 sellerBefore = seller.balance;
        uint256 marketFeeBefore = marketFee.balance;
        vm.prank(buyer);
        assertTrue(ISeaport(SEAPORT).fulfillOrder{value: PRICE}(Order(p, ""), bytes32(0)));
        assertEq(receipt.ownerOf(1), buyer);
        // Native payout, against REAL Seaport. This is the case receive() had to
        // be added for: Seaport sends the escrow's consideration item as raw
        // ether. It is accepted but NOT accounted there - the credit is written
        // in the first-exit callback, where the bundle is known.
        assertEq(marketFee.balance - marketFeeBefore, MARKET_FEE);
        assertEq(address(escrow).balance, ITEM0);
        assertEq(seller.balance - sellerBefore, 0);
        assertEq(escrow.claimable(seller, address(0)), SELLER_NET);
        vm.prank(seller);
        assertEq(escrow.withdraw(address(0)), SELLER_NET);
        assertEq(seller.balance - sellerBefore, SELLER_NET);
        assertEq(address(escrow).balance, PROTOCOL_FEE, "the fee stays as surplus");
        assertEq(escrow.claimable(seller, address(0)), 0);
    }

    function test_RealSeaportV16_FailedPaymentRollsBackReceiptAndFirstExit() public {
        if (!forked) {
            vm.skip(true);
            return;
        }
        OrderParameters memory p = listed();
        vm.prank(buyer);
        vm.expectRevert();
        ISeaport(SEAPORT).fulfillOrder(Order(p, ""), bytes32(0));
        assertEq(receipt.ownerOf(1), address(escrow));
        assertFalse(receipt.firstExitNotified(1));
        assertFalse(escrow.getBundle(1).everIssued);
    }

    function test_RealSeaportV16_ExactEndTimeIsExpired() public {
        if (!forked) {
            vm.skip(true);
            return;
        }
        OrderParameters memory p = listed();
        fund();
        vm.warp(deadline);
        vm.prank(buyer);
        vm.expectRevert();
        ISeaport(SEAPORT).fulfillOrder(Order(p, ""), bytes32(0));
        assertEq(receipt.ownerOf(1), address(escrow));
        assertFalse(receipt.firstExitNotified(1));
    }

    /// RE-ANCHORED (bundle-non-transferable-sep26): an owner-signed, paid
    /// secondary resale through REAL Seaport v1.6 now fails - the claim is
    /// non-transferable after its first sale - nothing moves and nothing is
    /// paid; the first buyer still redeems.
    function test_RealSeaportV16_OwnerSignedPaidSecondaryResaleReverts_TheFirstBuyerRedeems() public {
        if (!forked) {
            vm.skip(true);
            return;
        }
        uint256 secondarySellerKey = 0xBEE123;
        address secondarySeller = vm.addr(secondarySellerKey);
        OrderParameters memory primary = listed();
        fund();
        AdvancedOrder memory advanced = AdvancedOrder(primary, 1, 1, "", "");
        vm.prank(buyer);
        assertTrue(
            ISeaport(SEAPORT).fulfillAdvancedOrder(advanced, new CriteriaResolver[](0), bytes32(0), secondarySeller)
        );

        uint256 secondaryPrice = 0.4 ether;
        Order memory secondary = _signedSecondaryOrder(secondarySellerKey, secondaryPrice);

        vm.prank(secondarySeller);
        receipt.approve(SEAPORT, 1);
        payment.mint(recipient, secondaryPrice);
        vm.prank(recipient);
        payment.approve(SEAPORT, secondaryPrice);
        vm.prank(recipient);
        vm.expectRevert();
        ISeaport(SEAPORT).fulfillOrder(secondary, bytes32(0));

        assertEq(receipt.ownerOf(1), secondarySeller);
        assertEq(payment.balanceOf(secondarySeller), 0);
        assertEq(payment.balanceOf(recipient), secondaryPrice);
        assertEq(escrow.getBundle(1).firstRecipient, secondarySeller);
        vm.prank(secondarySeller);
        escrow.redeemToFreshAccount(1, keccak256("first-buyer"));
        assertEq(nft.ownerOf(1), secondarySeller);
    }

    function _signedSecondaryOrder(uint256 sellerKey, uint256 salePrice) internal returns (Order memory order) {
        address offerer = vm.addr(sellerKey);
        OfferItem[] memory offer = new OfferItem[](1);
        offer[0] = OfferItem(ItemType.ERC721, address(receipt), 1, 1, 1);
        ConsiderationItem[] memory consideration = new ConsiderationItem[](1);
        consideration[0] =
            ConsiderationItem(ItemType.ERC20, address(payment), 0, salePrice, salePrice, payable(offerer));
        OrderParameters memory p = OrderParameters(
            offerer,
            address(0),
            offer,
            consideration,
            OrderType.FULL_OPEN,
            0,
            deadline,
            bytes32(0),
            uint256(keccak256("secondary-sale")),
            bytes32(0),
            1
        );
        OrderComponents memory c = OrderComponents(
            p.offerer,
            p.zone,
            p.offer,
            p.consideration,
            p.orderType,
            p.startTime,
            p.endTime,
            p.zoneHash,
            p.salt,
            p.conduitKey,
            ISeaport(SEAPORT).getCounter(offerer)
        );
        bytes32 orderHash = ISeaport(SEAPORT).getOrderHash(c);
        (, bytes32 domainSeparator,) = ISeaportInformation(SEAPORT).information();
        bytes32 digest = keccak256(abi.encodePacked(bytes2(0x1901), domainSeparator, orderHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(sellerKey, digest);
        order = Order(p, abi.encodePacked(r, s, v));
    }

    function test_RealSeaportV16_FullOpenTipSupportedAndPartialRejected() public {
        if (!forked) {
            vm.skip(true);
            return;
        }
        OrderParameters memory base = listed();
        fund();
        AdvancedOrder memory partialOrder = AdvancedOrder(base, 1, 2, "", "");
        CriteriaResolver[] memory criteria = new CriteriaResolver[](0);
        vm.prank(buyer);
        vm.expectRevert();
        ISeaport(SEAPORT).fulfillAdvancedOrder(partialOrder, criteria, bytes32(0), buyer);
        ConsiderationItem[] memory tipped = new ConsiderationItem[](base.consideration.length + 1);
        for (uint256 i; i < base.consideration.length; ++i) {
            tipped[i] = base.consideration[i];
        }
        tipped[base.consideration.length] =
            ConsiderationItem(ItemType.ERC20, address(payment), 0, 1, 1, payable(recipient));
        base.consideration = tipped;
        vm.prank(buyer);
        assertTrue(ISeaport(SEAPORT).fulfillOrder(Order(base, ""), bytes32(0)));
        assertEq(payment.balanceOf(recipient), 1);
    }

    function test_RealSeaportV16_EveryHashedFieldMutationRejected() public {
        if (!forked) {
            vm.skip(true);
            return;
        }
        OrderParameters memory canonical = listed();
        fund();
        OrderParameters memory p = _clone(canonical);
        p.offerer = buyer;
        _reject(p);
        p = _clone(canonical);
        p.zone = recipient;
        _reject(p);
        p = _clone(canonical);
        p.offer[0].itemType = ItemType.ERC1155;
        _reject(p);
        p = _clone(canonical);
        p.offer[0].token = address(nft);
        _reject(p);
        p = _clone(canonical);
        p.offer[0].identifierOrCriteria = 2;
        _reject(p);
        p = _clone(canonical);
        p.offer[0].startAmount = 2;
        _reject(p);
        p = _clone(canonical);
        p.offer[0].endAmount = 2;
        _reject(p);
        p = _clone(canonical);
        p.consideration[0].itemType = ItemType.NATIVE;
        _reject(p);
        p = _clone(canonical);
        p.consideration[0].token = address(0);
        _reject(p);
        p = _clone(canonical);
        p.consideration[0].identifierOrCriteria = 1;
        _reject(p);
        p = _clone(canonical);
        p.consideration[0].startAmount -= 1;
        _reject(p);
        p = _clone(canonical);
        p.consideration[0].endAmount -= 1;
        _reject(p);
        p = _clone(canonical);
        p.consideration[0].recipient = payable(recipient);
        _reject(p);
        p = _clone(canonical);
        ConsiderationItem memory first = p.consideration[0];
        p.consideration[0] = p.consideration[1];
        p.consideration[1] = first;
        _reject(p);
        p = _clone(canonical);
        p.orderType = OrderType.FULL_OPEN;
        _reject(p);
        p = _clone(canonical);
        p.startTime = 1;
        _reject(p);
        p = _clone(canonical);
        p.endTime += 1;
        _reject(p);
        p = _clone(canonical);
        p.zoneHash = bytes32(uint256(1));
        _reject(p);
        p = _clone(canonical);
        p.salt += 1;
        _reject(p);
        p = _clone(canonical);
        p.conduitKey = bytes32(uint256(1));
        _reject(p);

        // Prove the rejected mutations did not corrupt the reference order in
        // memory and that each failure above was isolated from the others.
        (OrderParameters memory freshCanonical,,,,) = escrow.getOrder(1);
        vm.prank(buyer);
        assertTrue(ISeaport(SEAPORT).fulfillOrder(Order(freshCanonical, ""), bytes32(0)));
        assertEq(receipt.ownerOf(1), buyer);
    }

    function test_RealSeaportV16_CounterChangeInvalidatesAndApprovalAloneDoesNotAuthorize() public {
        if (!forked) {
            vm.skip(true);
            return;
        }
        OrderParameters memory p = listed();
        fund();
        vm.prank(address(escrow));
        ISeaport(SEAPORT).incrementCounter();
        vm.prank(buyer);
        vm.expectRevert();
        ISeaport(SEAPORT).fulfillOrder(Order(p, ""), bytes32(0));
        assertEq(receipt.ownerOf(1), address(escrow));
        assertFalse(escrow.getBundle(1).everIssued);
    }

    function test_BaseCanonicalSignedZoneAndStrictValidatorAreDeployed() public view {
        if (!forked) return;
        assertGt(SIGNED_ZONE.code.length, 0);
        assertGt(STRICT_TRANSFER_VALIDATOR.code.length, 0);
    }


    // ---------------------------------------------------------------- section 5
    // Multi-order aggregation, and reentrancy on the withdrawal path.

    /**
     * Seaport aggregates same-recipient NATIVE consideration across orders into
     * ONE transfer. This is the reason `receive()` accounts for nothing: the
     * amount arriving there is not per-bundle and would be a wrong credit. The
     * credit is written per bundle in the first-exit callback instead.
     *
     * This test would fail if the escrow ever credited on receipt, because it
     * would see 1.98 ether once and have no idea which bundle it belonged to.
     */
    function test_RealSeaportV16_AggregatedNativeFulfilmentCreditsEachBundleSeparately() public {
        if (!forked) return;

        // A second bundle from the same seller, so both orders pay the same two
        // recipients and Seaport has something to aggregate.
        nft.mint(seller, 2);
        vm.startPrank(seller);
        nft.approve(address(vault2()), 2);
        escrow.deposit(address(nft), 2, new ManifestEntry[](0), deadline);
        escrow.list(1, address(0), PRICE, deadline, 0, ps());
        escrow.list(2, address(0), PRICE, deadline, 0, ps());
        vm.stopPrank();

        (OrderParameters memory p1,,,,) = escrow.getOrder(1);
        (OrderParameters memory p2,,,,) = escrow.getOrder(2);

        AdvancedOrder[] memory orders = new AdvancedOrder[](2);
        orders[0] = AdvancedOrder(p1, 1, 1, "", "");
        orders[1] = AdvancedOrder(p2, 1, 1, "", "");

        // One offer fulfilment per order (the two receipts are distinct items),
        // and ONE consideration fulfilment per recipient spanning both orders -
        // that is what makes Seaport aggregate.
        FulfillmentComponent[][] memory offerF = new FulfillmentComponent[][](2);
        offerF[0] = new FulfillmentComponent[](1);
        offerF[0][0] = FulfillmentComponent(0, 0);
        offerF[1] = new FulfillmentComponent[](1);
        offerF[1][0] = FulfillmentComponent(1, 0);

        FulfillmentComponent[][] memory considerationF = new FulfillmentComponent[][](2);
        considerationF[0] = new FulfillmentComponent[](2);
        considerationF[0][0] = FulfillmentComponent(0, 0); // escrow, order 0
        considerationF[0][1] = FulfillmentComponent(1, 0); // escrow, order 1
        considerationF[1] = new FulfillmentComponent[](2);
        considerationF[1][0] = FulfillmentComponent(0, 1); // market fee, order 0
        considerationF[1][1] = FulfillmentComponent(1, 1); // market fee, order 1

        vm.deal(buyer, 2 * PRICE);
        uint256 marketFeeBefore = marketFee.balance;
        vm.prank(buyer);
        (bool[] memory available, Execution[] memory executions) = ISeaportAggregate(SEAPORT)
            .fulfillAvailableAdvancedOrders{value: 2 * PRICE}(
            orders, new CriteriaResolver[](0), offerF, considerationF, bytes32(0), buyer, 2
        );
        assertTrue(available[0] && available[1], "both orders must fill");

        // Prove aggregation ACTUALLY happened rather than inferring it from the
        // end balances, which would look identical after two separate transfers.
        // Two offer executions plus TWO consideration executions, not four: one
        // per recipient, each carrying the summed amount.
        assertEq(executions.length, 4, "expected 2 offer + 2 aggregated consideration executions");
        uint256 toEscrow;
        uint256 considerationExecutions;
        for (uint256 i; i < executions.length; ++i) {
            if (executions[i].item.itemType == ItemType.NATIVE) {
                considerationExecutions++;
                if (executions[i].item.recipient == address(escrow)) {
                    toEscrow = executions[i].item.amount;
                }
            }
        }
        assertEq(considerationExecutions, 2, "native consideration must be aggregated per recipient");
        assertEq(toEscrow, 2 * ITEM0, "the escrow must receive both bundles' shares in ONE execution");

        assertEq(receipt.ownerOf(1), buyer);
        assertEq(receipt.ownerOf(2), buyer);
        assertEq(uint8(escrow.getBundle(1).state), uint8(BundleState.Issued));
        assertEq(uint8(escrow.getBundle(2).state), uint8(BundleState.Issued));

        // Aggregated: the escrow received both items, and the market-fee recipient
        // both of its own, each as a single transfer.
        assertEq(address(escrow).balance, 2 * ITEM0);
        assertEq(marketFee.balance - marketFeeBefore, 2 * MARKET_FEE);

        // Credited per bundle nonetheless (each less its own frozen fee), and
        // withdrawable as the exact sum; both fees stay as surplus.
        assertEq(escrow.claimable(seller, address(0)), 2 * SELLER_NET);
        uint256 sellerBefore = seller.balance;
        vm.prank(seller);
        assertEq(escrow.withdraw(address(0)), 2 * SELLER_NET);
        assertEq(seller.balance - sellerBefore, 2 * SELLER_NET);
        assertEq(address(escrow).balance, 2 * PROTOCOL_FEE);
        assertEq(escrow.claimable(seller, address(0)), 0);
    }

    /**
     * Reentrancy on the native withdrawal path.
     *
     * The credit is zeroed before the transfer (CEI) AND the function carries
     * the transient entry lock, so a seller contract that calls back in cannot
     * be paid twice. Both halves are checked: a reentrant caller that reverts
     * makes the whole withdrawal fail closed, and one that swallows the revert
     * is paid exactly once.
     */
    function test_RealSeaportV16_ReentrantSellerCannotBePaidTwice() public {
        if (!forked) return;
        _reentrancyCase(true);
        _reentrancyCase(false);
    }

    /**
     * Isolates the transient entry lock.
     *
     * Mutation showed the lock is NOT what stops the double-payment above - CEI
     * alone does that, because the credit is zeroed before the transfer. The
     * lock earns its place elsewhere: it stops a seller re-entering a DIFFERENT
     * state-changing entry point while their own withdrawal is still in flight.
     * Without this test the lock could be deleted and nothing would notice.
     */
    function test_RealSeaportV16_WithdrawalLocksOutOtherEntryPointsNotJustItself() public {
        if (!forked) return;
        CrossFunctionReentrantSeller badSeller = new CrossFunctionReentrantSeller(escrow, address(nft));
        _sellAs(address(badSeller));
        assertEq(escrow.claimable(address(badSeller), address(0)), SELLER_NET);

        badSeller.withdraw();
        assertTrue(badSeller.reentered(), "the callback must really have reentered");
        // Re-entering deposit() mid-withdrawal is refused by the entry lock
        // specifically, not by some incidental argument validation.
        assertEq(badSeller.lastError(), NewTradeEscrowV2.Reentrancy.selector);
        // ...and the withdrawal itself still completed correctly.
        assertEq(address(badSeller).balance, SELLER_NET);
        assertEq(escrow.claimable(address(badSeller), address(0)), 0);
    }

    function _reentrancyCase(bool bubble) internal {
        uint256 snap = vm.snapshotState();
        ReentrantSeller badSeller = new ReentrantSeller(escrow, bubble);
        uint256 id = _sellAs(address(badSeller));

        assertEq(escrow.claimable(address(badSeller), address(0)), SELLER_NET);
        uint256 escrowBefore = address(escrow).balance;

        if (bubble) {
            // The inner call reverts Reentrancy; the outer transfer therefore
            // fails and withdraw reverts InvalidRecipient. Nothing moves, and
            // the credit survives because the whole call rolled back.
            vm.expectRevert(NewTradeEscrowV2.InvalidRecipient.selector);
            badSeller.withdraw();
            assertEq(escrow.claimable(address(badSeller), address(0)), SELLER_NET);
            assertEq(address(escrow).balance, escrowBefore);
        } else {
            badSeller.withdraw();
            // Paid once, not twice, and the reentrant attempt is recorded as
            // having actually happened - otherwise this proves nothing.
            assertTrue(badSeller.reentered(), "the callback must really have reentered");
            assertEq(address(badSeller).balance, SELLER_NET);
            assertEq(escrow.claimable(address(badSeller), address(0)), 0);
            assertEq(address(escrow).balance, escrowBefore - SELLER_NET);
        }
        id; // silence unused
        vm.revertToState(snap);
    }

    /// Deposit, list and sell one bundle owned by `who`, natively. Returns the id.
    function _sellAs(address who) internal returns (uint256 id) {
        uint256 tokenId = 100 + uint256(uint160(who)) % 1000;
        nft.mint(who, tokenId);
        vm.startPrank(who);
        nft.approve(address(vault2()), tokenId);
        id = escrow.deposit(address(nft), tokenId, new ManifestEntry[](0), deadline);
        escrow.list(id, address(0), PRICE, deadline, 0, ps());
        vm.stopPrank();
        (OrderParameters memory p,,,,) = escrow.getOrder(id);
        vm.deal(buyer, PRICE);
        vm.prank(buyer);
        assertTrue(ISeaport(SEAPORT).fulfillOrder{value: PRICE}(Order(p, ""), bytes32(0)));
    }

    function vault2() internal view returns (address) {
        return escrow.vault();
    }

    function _reject(OrderParameters memory p) internal {
        (OrderParameters memory freshCanonical,,,,) = escrow.getOrder(1);
        assertNotEq(keccak256(abi.encode(p)), keccak256(abi.encode(freshCanonical)));
        vm.prank(buyer);
        vm.expectRevert();
        ISeaport(SEAPORT).fulfillOrder(Order(p, ""), bytes32(0));
        assertEq(receipt.ownerOf(1), address(escrow));
    }

    function _clone(OrderParameters memory p) internal pure returns (OrderParameters memory) {
        return abi.decode(abi.encode(p), (OrderParameters));
    }
}

/**
 * A seller that is a contract and calls back into withdraw on payment.
 *
 * `bubble` selects whether the callback lets the inner revert propagate, which
 * is what makes the outer transfer fail, or swallows it.
 */
contract ReentrantSeller {
    NewTradeEscrowV2 immutable escrow;
    bool immutable bubble;
    bool public reentered;

    constructor(NewTradeEscrowV2 escrow_, bool bubble_) {
        escrow = escrow_;
        bubble = bubble_;
    }

    function withdraw() external {
        escrow.withdraw(address(0));
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    receive() external payable {
        if (reentered) return;
        reentered = true;
        if (bubble) {
            escrow.withdraw(address(0));
        } else {
            try escrow.withdraw(address(0)) {} catch {}
        }
    }
}

/// Re-enters a DIFFERENT entry point during its own withdrawal, which is what
/// the transient entry lock exists to refuse.
contract CrossFunctionReentrantSeller {
    NewTradeEscrowV2 immutable escrow;
    address immutable nft;
    bool public reentered;
    bytes4 public lastError;

    constructor(NewTradeEscrowV2 escrow_, address nft_) {
        escrow = escrow_;
        nft = nft_;
    }

    function withdraw() external {
        escrow.withdraw(address(0));
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    receive() external payable {
        if (reentered) return;
        reentered = true;
        try escrow.deposit(nft, 9999, new ManifestEntry[](0), uint64(block.timestamp + 1 days)) returns (uint256) {
            lastError = bytes4(0);
        } catch (bytes memory err) {
            lastError = bytes4(err);
        }
    }
}
