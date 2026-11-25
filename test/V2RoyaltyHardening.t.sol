// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {V2BundleEscrowTest} from "./V2BundleEscrow.t.sol";
import {NewTradeEscrowV2} from "../src/NewTradeEscrowV2.sol";
import {Payout, BundleState} from "../src/NewTradeV2Types.sol";
import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {OrderParameters} from "../src/interfaces/ISeaport.sol";
import {SeaportV2Mock} from "./helpers/SeaportV2Mock.sol";

contract V2RoyaltyHardeningTest is V2BundleEscrowTest {
    address creator = address(0xCAFE);

    function _support(bool enabled) internal {
        vm.mockCall(
            address(control),
            abi.encodeCall(IERC165.supportsInterface, (type(IERC2981).interfaceId)),
            abi.encode(enabled)
        );
    }

    function _quote(address recipient, uint256 amount) internal {
        vm.mockCall(address(control), abi.encodeCall(IERC2981.royaltyInfo, (1, PRICE)), abi.encode(recipient, amount));
    }

    /// OPTION B (escrow-option-b-sep26): neither the fee nor the royalty is an
    /// item; the escrow item carries the whole price and the first exit credits
    /// the creator 0.1 and the seller 1 - 0.1 - 0.025 = 0.875.
    function royaltyPayouts() internal view returns (Payout[] memory ps) {
        ps = new Payout[](1);
        ps[0] = Payout(payable(address(escrow)), 1 ether);
    }

    function _two(uint256 a, address to, uint256 b) internal view returns (Payout[] memory ps) {
        ps = new Payout[](2);
        ps[0] = Payout(payable(address(escrow)), a);
        ps[1] = Payout(payable(to), b);
    }

    /// Option B: the cap binds, item[0] must cover royalty + fee, and no item may
    /// pay the creator (it is credited). A creator item used to be REQUIRED.
    function test_RoyaltyCapItem0CoverAndNoCreatorItemAreEnforced() public {
        uint256 id = deposit();
        _support(true);
        _quote(creator, 0.1 ether);
        vm.prank(seller);
        vm.expectRevert(NewTradeEscrowV2.InvalidConsideration.selector);
        escrow.list(id, address(erc20), PRICE, deadline, 999, royaltyPayouts()); // cap
        vm.prank(seller);
        vm.expectRevert(NewTradeEscrowV2.InvalidConsideration.selector);
        escrow.list(id, address(erc20), PRICE, deadline, 1000, _two(0.9 ether, creator, 0.1 ether)); // creator item
        vm.prank(seller);
        vm.expectRevert(NewTradeEscrowV2.InvalidConsideration.selector);
        escrow.list(id, address(erc20), PRICE, deadline, 1000, _two(0.125 ether - 1, address(0xABCD), 0.875 ether + 1)); // item0 short by 1
        vm.prank(seller);
        escrow.list(id, address(erc20), PRICE, deadline, 1000, _two(0.125 ether, address(0xABCD), 0.875 ether)); // exactly royalty + fee
        assertEq(escrow.getPayouts(id).length, 2);
        assertEq(escrow.getRoyaltySnapshot(id).creator, creator);
        assertEq(escrow.getRoyaltySnapshot(id).creatorNet, 0.1 ether);
    }

    function test_ExactTinyNativeBetaPriceAndFivePercentRoyalty() public {
        uint256 tinyPrice = 10_000_000_000;
        uint256 royalty = 500_000_000;
        uint256 id = deposit();
        escrow.setProtocolFeeBps(0);
        _support(true);
        vm.mockCall(
            address(control), abi.encodeCall(IERC2981.royaltyInfo, (1, tinyPrice)), abi.encode(creator, royalty)
        );
        Payout[] memory ps = new Payout[](1);
        ps[0] = Payout(payable(address(escrow)), tinyPrice);

        vm.prank(seller);
        escrow.list(id, address(0), tinyPrice, deadline, 500, ps);

        assertEq(escrow.getBundle(id).price, tinyPrice);
        assertEq(escrow.getPayouts(id).length, 1);
        assertEq(escrow.getPayouts(id)[0].amount, tinyPrice);
        // Option B: the 5 % royalty is frozen for crediting, not an item.
        assertEq(escrow.getRoyaltySnapshot(id).creator, creator);
        assertEq(escrow.getRoyaltySnapshot(id).creatorNet, royalty);
    }

    function test_ExactBetaSellerRoyaltyAggregatesAndPreservesComponent() public {
        uint256 tinyPrice = 10_000_000_000;
        uint256 id = deposit();
        escrow.setProtocolFeeBps(0);
        _support(true);
        vm.mockCall(
            address(control), abi.encodeCall(IERC2981.royaltyInfo, (1, tinyPrice)), abi.encode(seller, uint256(500_000_000))
        );
        Payout[] memory ps = new Payout[](1);
        ps[0] = Payout(payable(address(escrow)), tinyPrice);
        vm.prank(seller);
        escrow.list(id, address(0), tinyPrice, deadline, 500, ps);
        // zero-royalty-wrapper: the escrow froze the controlling NFT's quote; the
        // Bundle itself answers marketplaces zero.
        address recipient = escrow.getRoyaltySnapshot(id).creator;
        uint256 royalty = escrow.getRoyaltySnapshot(id).creatorNet;
        assertEq(recipient, seller);
        assertEq(royalty, 500_000_000);
        (address wrapped, uint256 wrappedAmount) = receipt.royaltyInfo(id, tinyPrice);
        assertEq(wrapped, address(0));
        assertEq(wrappedAmount, 0);
        assertEq(tinyPrice - royalty, 9_500_000_000);
        // The single consideration item pays the ESCROW - it is the offerer, and
        // OpenSea requires offerer == consideration[0].recipient. The seller's
        // ERC-2981 royalty is satisfied by the credit the escrow settles onward
        // to them, not by a second consideration item, which is why this
        // aggregated listing is accepted at all.
        assertEq(escrow.getPayouts(id).length, 1);
        assertEq(escrow.getPayouts(id)[0].recipient, address(escrow));
        assertEq(escrow.getPayouts(id)[0].amount, tinyPrice);

        // The equivalence has to be real, not asserted: fill the order and check
        // the seller can actually withdraw the full amount, royalty included.
        (OrderParameters memory p,,,,) = escrow.getOrder(id);
        SeaportV2Mock(SEAPORT).fill(p, buyer);
        assertEq(escrow.claimable(seller, address(0)), tinyPrice);

        // And the narrowness has to be real too: the same aggregation is
        // REJECTED when the royalty is owed to somebody other than the seller,
        // because the escrow settles onward only to the seller.
        setUp();
        uint256 other = deposit();
        escrow.setProtocolFeeBps(0);
        _support(true);
        vm.mockCall(
            address(control), abi.encodeCall(IERC2981.royaltyInfo, (1, tinyPrice)), abi.encode(creator, uint256(500_000_000))
        );
        vm.prank(seller);
        vm.expectRevert(NewTradeEscrowV2.InvalidConsideration.selector);
        escrow.list(other, address(0), tinyPrice, deadline, 500, ps);
    }

    /// zero-royalty-wrapper (item 62(3)): the wrapper answers (0x0, 0) and still
    /// advertises ERC-2981; the escrow's own quote of the original is unchanged.
    function test_WrapperAnswersZeroRoyalty_TheEscrowStillQuotesTheOriginal() public {
        uint256 id = deposit();
        _support(true);
        _quote(creator, 0.1 ether);
        (address recipient, uint256 amount) = receipt.royaltyInfo(id, PRICE);
        assertEq(recipient, address(0));
        assertEq(amount, 0);
        assertTrue(receipt.supportsInterface(type(IERC2981).interfaceId));
        (,, address quoted, uint256 quotedAmount) = escrow.quotePrimaryFees(id, PRICE);
        assertEq(quoted, creator);
        assertEq(quotedAmount, 0.1 ether);
    }

    /// Option B: an item to the royalty recipient (here the treasury as creator)
    /// is refused - it would be paid twice; an extra item to ANOTHER address
    /// (a seller-approved tip) stays allowed.
    function test_ACreatorItemIsRefused_ButAnExtraItemToAnotherAddressIsAllowed() public {
        uint256 id = deposit();
        _support(true);
        _quote(treasury, 0.1 ether);
        vm.prank(seller);
        vm.expectRevert(NewTradeEscrowV2.InvalidConsideration.selector);
        escrow.list(id, address(erc20), PRICE, deadline, 1000, _two(0.8 ether, treasury, 0.2 ether));
        vm.prank(seller);
        escrow.list(id, address(erc20), PRICE, deadline, 1000, _two(0.8 ether, address(0xABCD), 0.2 ether));
        assertEq(escrow.getPayouts(id)[1].amount, 0.2 ether);
    }

    event ProtocolFeeSnapshot(uint256 indexed bundleId, address indexed token, uint256 amount);

    /// `_protocolFeeAmount[bundleId]` (slot 21 of NewTradeEscrowV2Storage).
    function _feeSnapshot(uint256 id) internal view returns (uint256) {
        return uint256(vm.load(address(escrow), keccak256(abi.encode(id, uint256(21)))));
    }

    /// GUARD SEMANTICS CHANGED (escrow-fee-from-proceeds-sep25; seniordev decision
    /// 2026-09-26, option 1 "accept and document"; op2 to review explicitly).
    /// Before: a fee change between quote and list() made the seller's exact
    /// consideration fail (the treasury item no longer covered the fee). Now the
    /// fee is not a consideration item, so the seller's consideration does not
    /// bind it: list() freezes the LIVE bps, a raise between quote and list()
    /// binds that listing, a change after list() never alters its snapshot, the
    /// bps is capped at MAX_PROTOCOL_FEE_BPS, and item0 must still cover the fee.
    /// Follow-up (seniordev): a seller-supplied maxFeeBps on list().
    function test_FeeGuard_RaiseBetweenQuoteAndList_BindsThatListing_AndNothingAfterIt() public {
        uint256 id = deposit();
        _support(true);
        _quote(creator, 0.1 ether);
        (address quotedTreasury, uint256 quotedFee, address royaltyRecipient, uint256 royalty) =
            escrow.quotePrimaryFees(id, PRICE);
        assertEq(quotedTreasury, treasury);
        assertEq(quotedFee, 0.025 ether);
        assertEq(royaltyRecipient, creator);
        assertEq(royalty, 0.1 ether);

        // A RAISE to the maximum after the quote: the quoted consideration still lists,
        // and the snapshot is the RAISED fee, announced as it is frozen.
        escrow.setProtocolFeeBps(1_000);
        vm.expectEmit(true, true, false, true, address(escrow));
        emit ProtocolFeeSnapshot(id, address(erc20), 0.1 ether);
        vm.prank(seller);
        escrow.list(id, address(erc20), PRICE, deadline, 1000, royaltyPayouts());
        assertEq(uint8(escrow.getBundle(id).state), uint8(BundleState.Listed));
        assertEq(_feeSnapshot(id), 0.1 ether, "snapshot == the raised fee");

        // A change AFTER list() never alters the snapshot, in either direction.
        escrow.setProtocolFeeBps(0);
        assertEq(_feeSnapshot(id), 0.1 ether);
        escrow.setProtocolFeeBps(500);
        assertEq(_feeSnapshot(id), 0.1 ether);

        // net = item0 - snapshot at the sale.
        (OrderParameters memory p,,,,) = escrow.getOrder(id);
        erc20.mint(buyer, PRICE);
        vm.prank(buyer);
        erc20.approve(SEAPORT, PRICE);
        SeaportV2Mock(SEAPORT).fillAndPay(p, buyer, buyer);
        // Option B: net = item0 - royalty snapshot - fee snapshot.
        assertEq(escrow.claimable(seller, address(erc20)), royaltyPayouts()[0].amount - 0.1 ether - 0.1 ether, "net = item0 - royalty - fee");
        assertEq(escrow.claimable(seller, address(erc20)), 0.8 ether);
        assertEq(escrow.claimable(creator, address(erc20)), 0.1 ether);
    }

    function test_FeeGuard_RaiseAboveMaxRevertsAtSetProtocolFeeBps() public {
        uint96 max = escrow.MAX_PROTOCOL_FEE_BPS(); // hoisted: expectRevert applies to the next call
        assertEq(max, 1_000);
        vm.expectRevert(NewTradeEscrowV2.InvalidConsideration.selector);
        escrow.setProtocolFeeBps(max + 1);
        escrow.setProtocolFeeBps(max);
    }

    function test_FeeGuard_Item0BelowTheRaisedFee_RevertsList() public {
        uint256 id = deposit();
        _support(true);
        _quote(creator, 0.1 ether);
        // Quoted at 250 bps: item0 0.15 covers royalty 0.1 + fee 0.025...
        Payout[] memory ps = _two(0.15 ether, address(0x0717), 0.85 ether);
        // ...but not royalty 0.1 + the raised fee 0.1.
        escrow.setProtocolFeeBps(1_000);
        vm.prank(seller);
        vm.expectRevert(NewTradeEscrowV2.InvalidConsideration.selector);
        escrow.list(id, address(erc20), PRICE, deadline, 1000, ps);
        assertEq(uint8(escrow.getBundle(id).state), uint8(BundleState.Deposited));
        // At the quoted fee the same consideration lists.
        escrow.setProtocolFeeBps(250);
        vm.prank(seller);
        escrow.list(id, address(erc20), PRICE, deadline, 1000, ps);
        assertEq(_feeSnapshot(id), 0.025 ether);
    }

    /// GUARD SEMANTICS CHANGED (option B, escrow-option-b-sep26; op2/devlead to
    /// review explicitly). Before, the order carried the creator item, so a
    /// royalty recipient or amount that changed between quote and list() failed
    /// the seller's exact consideration. Now the royalty is not an item: list()
    /// freezes the LIVE ERC-2981 answer, and the seller's binding is the
    /// `maxRoyaltyBps` cap (plus item[0] covering royalty + fee). A change within
    /// the cap binds that listing; above it, list() reverts.
    function test_RoyaltyGuard_AChangedQuoteIsBoundByTheSellerCap() public {
        uint256 id = deposit();
        _support(true);
        _quote(creator, 0.1 ether);
        Payout[] memory quoted = royaltyPayouts();
        _quote(address(0xDEAD), 0.2 ether);
        vm.prank(seller);
        vm.expectRevert(NewTradeEscrowV2.InvalidConsideration.selector);
        escrow.list(id, address(erc20), PRICE, deadline, 1000, quoted); // 0.2 above the seller's 10 % cap
        assertEq(uint8(escrow.getBundle(id).state), uint8(BundleState.Deposited));
        vm.prank(seller);
        escrow.list(id, address(erc20), PRICE, deadline, 2000, quoted); // within a 20 % cap: frozen as live
        assertEq(escrow.getRoyaltySnapshot(id).creator, address(0xDEAD));
        assertEq(escrow.getRoyaltySnapshot(id).creatorNet, 0.2 ether);
    }

    function test_RoyaltyMalformedResponsesRejectAtomically() public {
        uint256 id = deposit();
        _support(true);
        vm.mockCall(address(control), abi.encodeCall(IERC2981.royaltyInfo, (1, PRICE)), hex"01");
        vm.prank(seller);
        vm.expectRevert(NewTradeEscrowV2.InvalidConsideration.selector);
        escrow.list(id, address(erc20), PRICE, deadline, 1000, royaltyPayouts());
        assertEq(uint8(escrow.getBundle(id).state), uint8(BundleState.Deposited));
        assertEq(escrow.getPayouts(id).length, 0);
    }

    function test_RoyaltyZeroRecipientWithPositiveAmountRejects() public {
        uint256 id = deposit();
        _support(true);
        _quote(address(0), 0.1 ether);
        vm.prank(seller);
        vm.expectRevert(NewTradeEscrowV2.InvalidConsideration.selector);
        escrow.list(id, address(erc20), PRICE, deadline, 1000, royaltyPayouts());
    }

    function test_RoyaltySnapshotCannotBeChangedAfterSellerLists() public {
        uint256 id = deposit();
        _support(true);
        _quote(creator, 0.1 ether);
        vm.prank(seller);
        escrow.list(id, address(erc20), PRICE, deadline, 1000, royaltyPayouts());
        _quote(address(0xDEAD), 0.2 ether);
        assertEq(escrow.getRoyaltySnapshot(id).creator, creator);
        assertEq(escrow.getRoyaltySnapshot(id).creatorNet, 0.1 ether);
    }

    function test_RoyaltySupportProbeRevertMeansNoAdvertisedRoyalty() public {
        uint256 id = deposit();
        vm.mockCallRevert(
            address(control), abi.encodeCall(IERC165.supportsInterface, (type(IERC2981).interfaceId)), "failure"
        );
        vm.prank(seller);
        escrow.list(id, address(erc20), PRICE, deadline, 0, payouts());
        assertEq(uint8(escrow.getBundle(id).state), uint8(BundleState.Listed));
    }
}
