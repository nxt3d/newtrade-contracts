// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {V2RoyaltyServiceTest} from "./V2RoyaltyService.t.sol";
import {NewTradeEscrowV2} from "../src/NewTradeEscrowV2.sol";
import {Payout, BundleState, RoyaltySnapshot} from "../src/NewTradeV2Types.sol";
import {OrderParameters} from "../src/interfaces/ISeaport.sol";
import {SeaportV2Mock} from "./helpers/SeaportV2Mock.sol";
import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import {Vm} from "forge-std/Vm.sol";

/// A creator that is a CONTRACT able to receive but unable to call `withdraw`.
contract PassiveCreator {
    receive() external payable {}
}

/// A creator that re-enters the escrow while being paid.
contract ReenteringPayee {
    NewTradeEscrowV2 internal immutable escrow;
    bytes public reentryError;

    constructor(NewTradeEscrowV2 escrow_) {
        escrow = escrow_;
    }

    receive() external payable {
        try escrow.withdrawFor(address(this), address(0)) {}
        catch (bytes memory err) {
            reentryError = err;
        }
    }
}

/**
 * OPTION B (escrow-option-b-sep26): the creator royalty is NOT a consideration
 * item. The order is `[escrow, OpenSea 1 %]`; at first exit the escrow item is
 * split in the owed ledger - the ERC-2981 recipient is credited its royalty,
 * the seller `item0 - royalty - fee`, the protocol fee stays as surplus. Both
 * withdraw through `withdraw`, or anyone through `withdrawFor`.
 *
 * Harness (V2BundleEscrowTest): PRICE 1 ether, controlling NFT mocked for
 * ERC-2981; the protocol fee here is set to the live 500 bps.
 */
contract V2OptionBTest is V2RoyaltyServiceTest {
    event CreatorRoyaltySnapshot(uint256 indexed bundleId, address indexed recipient, address indexed token, uint256 amount);
    event CreatorRoyaltyCredited(uint256 indexed bundleId, address indexed recipient, address indexed token, uint256 amount);
    event ProceedsCredited(uint256 indexed bundleId, address indexed seller, address indexed token, uint256 amount);
    event ProceedsWithdrawn(address indexed seller, address indexed token, uint256 amount);

    address constant C3F9 = 0xc3F96C409d26272fDB592c0d04e1D771A7df032e;
    address constant OPENSEA = 0x0000a26b00c1F0DF003000390027140000fAa719;
    address stranger = address(0x5757);

    uint256 constant FEE = 0.05 ether; // 500 bps of PRICE
    uint256 constant OS = 0.01 ether; // 1 %

    /// The live protocol fee (500 bps). A modifier, not setUp: the inherited
    /// harness tests run in this contract too and expect the harness default.
    modifier live() {
        escrow.setProtocolFeeBps(500);
        _;
    }

    // ------------------------------------------------------------------ helpers

    function _royaltyBps(address recipient, uint256 bps) internal {
        _support(true);
        vm.mockCall(address(control), abi.encodeCall(IERC2981.royaltyInfo, (1, PRICE)), abi.encode(recipient, PRICE * bps / 10_000));
    }

    /// The option B shape: `[escrow price - 1 %, OpenSea 1 %]`.
    function _bShape() internal view returns (Payout[] memory ps) {
        ps = new Payout[](2);
        ps[0] = Payout(payable(address(escrow)), PRICE - OS);
        ps[1] = Payout(payable(OPENSEA), OS);
    }

    function _two(uint256 a, address to, uint256 b) internal view returns (Payout[] memory ps) {
        ps = new Payout[](2);
        ps[0] = Payout(payable(address(escrow)), a);
        ps[1] = Payout(payable(to), b);
    }

    function _list(Payout[] memory ps, uint16 maxBps) internal returns (uint256 id, OrderParameters memory p) {
        id = _pending != 0 ? _pending : deposit();
        _pending = 0;
        vm.prank(seller);
        escrow.list(id, address(erc20), PRICE, deadline, maxBps, ps);
        (p,,,,) = escrow.getOrder(id);
    }

    function _fill(OrderParameters memory p) internal {
        SeaportV2Mock(SEAPORT).fillAndPay(p, buyer, buyer);
    }

    /// One deposit per test (the harness NFT id 1 deposits once); failed lists leave it Deposited.
    uint256 private _pending;

    function _listReverts(Payout[] memory ps, uint16 maxBps) internal {
        if (_pending == 0) _pending = deposit();
        uint256 id = _pending;
        vm.prank(seller);
        vm.expectRevert(NewTradeEscrowV2.InvalidConsideration.selector);
        escrow.list(id, address(erc20), PRICE, deadline, maxBps, ps);
    }

    function _sumClaimable(address token, address[3] memory who) internal view returns (uint256 sum) {
        for (uint256 i; i < 3; ++i) {
            // count each distinct account once
            bool dup;
            for (uint256 j; j < i; ++j) if (who[j] == who[i]) dup = true;
            if (!dup) sum += escrow.claimable(who[i], token);
        }
    }

    // ============================================================ truth table

    function test_TwoPointFivePercentToC3F9_BShapeAccepted_CreditsCreatorSellerAndSurplus() public live {
        _royaltyBps(C3F9, 250); // 0.025
        _pending = deposit();
        vm.expectEmit(true, true, true, true, address(escrow));
        emit CreatorRoyaltySnapshot(_pending, C3F9, address(erc20), 0.025 ether);
        (uint256 id, OrderParameters memory p) = _list(_bShape(), 250);
        assertEq(p.consideration.length, 2, "exactly [escrow, OpenSea]");
        assertEq(p.consideration[0].recipient, address(escrow));
        assertEq(p.consideration[0].startAmount, 0.99 ether);
        assertEq(p.consideration[1].recipient, OPENSEA);
        RoyaltySnapshot memory s = escrow.getRoyaltySnapshot(id);
        assertEq(s.creator, C3F9);
        assertEq(s.grossRoyalty, 0.025 ether);
        assertEq(s.creatorNet, 0.025 ether);
        assertEq(s.router, address(0));
        assertEq(s.treasury, address(0));
        assertEq(s.serviceFeeAmount, 0);

        vm.expectEmit(true, true, true, true, address(escrow));
        emit ProceedsCredited(id, seller, address(erc20), 0.99 ether - 0.025 ether - FEE);
        vm.expectEmit(true, true, true, true, address(escrow));
        emit CreatorRoyaltyCredited(id, C3F9, address(erc20), 0.025 ether);
        _fill(p);
        assertEq(escrow.claimable(C3F9, address(erc20)), 0.025 ether);
        assertEq(escrow.claimable(seller, address(erc20)), 0.915 ether);
        assertEq(erc20.balanceOf(C3F9), 0, "no item paid the creator");
        assertEq(erc20.balanceOf(OPENSEA), OS);
        assertEq(escrow.totalOwed(address(erc20)), 0.94 ether, "seller + creator");
        assertEq(erc20.balanceOf(address(escrow)) - escrow.totalOwed(address(erc20)), FEE, "surplus = the fee");
        assertEq(address(router).balance + erc20.balanceOf(address(router)), 0, "the receiver is untouched");
    }

    function test_Item0ExactlyRoyaltyPlusFee_Accepted_SellerCreditedZero() public live {
        _royaltyBps(C3F9, 250);
        (uint256 id, OrderParameters memory p) = _list(_two(0.075 ether, stranger, 0.925 ether), 250);
        _fill(p);
        assertEq(escrow.claimable(seller, address(erc20)), 0);
        assertEq(escrow.claimable(C3F9, address(erc20)), 0.025 ether);
        id;
    }

    function test_Item0ShortByOne_Reverts() public live {
        _royaltyBps(C3F9, 250);
        _listReverts(_two(0.075 ether - 1, stranger, 0.925 ether + 1), 250);
    }

    function test_APayoutNamingTheCreator_Reverts_NoDoublePay() public live {
        _royaltyBps(C3F9, 250);
        _listReverts(_two(0.975 ether, C3F9, 0.025 ether), 250); // the old direct-creator shape
        _listReverts(_two(0.99 ether, C3F9, 0.01 ether), 250); // any amount to the creator
    }

    function test_ZeroPercentNft_NoErc2981_BShape_NoCreatorCredit() public live {
        _support(false);
        (uint256 id, OrderParameters memory p) = _list(_bShape(), 0);
        assertEq(escrow.getRoyaltySnapshot(id).creatorNet, 0);
        _fill(p);
        assertEq(escrow.claimable(seller, address(erc20)), 0.99 ether - FEE);
        assertEq(escrow.totalOwed(address(erc20)), 0.99 ether - FEE);
    }

    function test_ZeroPercentNft_DeclaredZero_RecipientNamed_NothingCredited_NoSnapshotEvent() public live {
        _royaltyBps(C3F9, 0);
        vm.recordLogs();
        (uint256 id, OrderParameters memory p) = _list(_bShape(), 0);
        bytes32 topic = keccak256("CreatorRoyaltySnapshot(uint256,address,address,uint256)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) assertTrue(logs[i].topics.length == 0 || logs[i].topics[0] != topic);
        _fill(p);
        assertEq(escrow.claimable(C3F9, address(erc20)), 0);
        assertEq(escrow.claimable(seller, address(erc20)), 0.99 ether - FEE);
        id;
    }

    function test_TenPercentNft_CapBinds_WithinCapCredits() public live {
        _royaltyBps(C3F9, 1_000); // 0.1
        _listReverts(_bShape(), 999);
        (, OrderParameters memory p) = _list(_bShape(), 1_000);
        _fill(p);
        assertEq(escrow.claimable(C3F9, address(erc20)), 0.1 ether);
        assertEq(escrow.claimable(seller, address(erc20)), 0.99 ether - 0.1 ether - FEE);
    }

    function test_SellerIsCreator_OneBalance_Item0LessFee() public live {
        _royaltyBps(seller, 250);
        (, OrderParameters memory p) = _list(_bShape(), 250);
        _fill(p);
        assertEq(escrow.claimable(seller, address(erc20)), 0.99 ether - FEE, "(item0 - royalty - fee) + royalty");
        assertEq(escrow.totalOwed(address(erc20)), 0.99 ether - FEE);
    }

    function test_MalformedOrZeroRecipientRoyalty_StillRevertsAtList() public live {
        _support(true);
        vm.mockCall(address(control), abi.encodeCall(IERC2981.royaltyInfo, (1, PRICE)), hex"01");
        _listReverts(_bShape(), 1_000);
        vm.mockCall(address(control), abi.encodeCall(IERC2981.royaltyInfo, (1, PRICE)), abi.encode(address(0), uint256(0.02 ether)));
        _listReverts(_bShape(), 1_000);
        // A royalty naming the escrow itself is refused by the no-double-pay rule (item[0] names it).
        _royaltyBps(address(escrow), 250);
        _listReverts(_bShape(), 250);
    }

    function test_ExtraItemToAnotherAddress_StaysAllowed() public live {
        _royaltyBps(C3F9, 250);
        Payout[] memory ps = new Payout[](3);
        ps[0] = Payout(payable(address(escrow)), 0.9 ether);
        ps[1] = Payout(payable(OPENSEA), OS);
        ps[2] = Payout(payable(stranger), 0.09 ether);
        (, OrderParameters memory p) = _list(ps, 250);
        _fill(p);
        assertEq(escrow.claimable(seller, address(erc20)), 0.9 ether - 0.025 ether - FEE);
        assertEq(erc20.balanceOf(stranger), 0.09 ether);
    }

    function test_PreOptionBBundle_ZeroSnapshot_NoCreatorCredit_SellerGetsItem0LessFee() public live {
        _royaltyBps(C3F9, 250);
        (uint256 id, OrderParameters memory p) = _list(_bShape(), 250);
        // What a bundle listed before option B looks like: an all-zero snapshot.
        bytes32 base = keccak256(abi.encode(id, uint256(20)));
        for (uint256 k; k < 6; ++k) vm.store(address(escrow), bytes32(uint256(base) + k), bytes32(0));
        assertEq(escrow.getRoyaltySnapshot(id).creatorNet, 0);
        _fill(p);
        assertEq(escrow.claimable(C3F9, address(erc20)), 0);
        assertEq(escrow.claimable(seller, address(erc20)), 0.99 ether - FEE);
    }

    /// zero-royalty-wrapper (item 62(3)): the Bundle answers marketplaces (0x0, 0)
    /// while the escrow keeps the controlling NFT's quote frozen for crediting.
    function test_BundleRoyaltyInfo_IsZero_WhileTheEscrowSnapshotKeepsTheOriginal() public live {
        _royaltyBps(C3F9, 250);
        (uint256 id,) = _list(_bShape(), 250);
        assertEq(uint8(escrow.getBundle(id).state), uint8(BundleState.Listed));
        (address to, uint256 amount) = receipt.royaltyInfo(id, PRICE);
        assertEq(to, address(0));
        assertEq(amount, 0);
        assertEq(escrow.getRoyaltySnapshot(id).creator, C3F9);
        assertEq(escrow.getRoyaltySnapshot(id).creatorNet, 0.025 ether);
    }

    function test_QuotePrimaryFees_NamesTheErc2981Recipient() public live {
        _royaltyBps(C3F9, 250);
        uint256 id = deposit();
        (address t, uint256 fee, address recipient, uint256 royalty) = escrow.quotePrimaryFees(id, PRICE);
        assertEq(t, treasury);
        assertEq(fee, FEE);
        assertEq(recipient, C3F9);
        assertEq(royalty, 0.025 ether);
    }

    function test_RoutingSurface_IsGone() public live {
        bytes4[5] memory gone = [
            bytes4(keccak256("royaltyRouter()")),
            bytes4(keccak256("royaltyServiceFeeBps()")),
            bytes4(keccak256("setRoyaltyRouter(address)")),
            bytes4(keccak256("setRoyaltyServiceFeeBps(uint16)")),
            bytes4(keccak256("quoteRoyaltyService(uint256,uint256)"))
        ];
        for (uint256 i; i < gone.length; ++i) {
            (bool ok,) = address(escrow).call(abi.encodeWithSelector(gone[i], uint256(1), uint256(1)));
            assertFalse(ok);
        }
    }

    // ============================================================ withdraw / withdrawFor

    function test_CreatorWithdraws_AndTotalOwedIsTheSum() public live {
        _royaltyBps(C3F9, 250);
        (, OrderParameters memory p) = _list(_bShape(), 250);
        _fill(p);
        assertEq(escrow.totalOwed(address(erc20)), _sumClaimable(address(erc20), [seller, C3F9, stranger]));
        vm.expectEmit(true, true, false, true, address(escrow));
        emit ProceedsWithdrawn(C3F9, address(erc20), 0.025 ether);
        vm.prank(C3F9);
        assertEq(escrow.withdraw(address(erc20)), 0.025 ether);
        assertEq(erc20.balanceOf(C3F9), 0.025 ether);
        assertEq(escrow.totalOwed(address(erc20)), 0.915 ether);
    }

    function test_WithdrawFor_ByAStranger_PaysTheAccountOnly() public live {
        _royaltyBps(C3F9, 250);
        (, OrderParameters memory p) = _list(_bShape(), 250);
        _fill(p);
        vm.expectEmit(true, true, false, true, address(escrow));
        emit ProceedsWithdrawn(C3F9, address(erc20), 0.025 ether);
        vm.prank(stranger);
        assertEq(escrow.withdrawFor(C3F9, address(erc20)), 0.025 ether);
        assertEq(erc20.balanceOf(C3F9), 0.025 ether);
        assertEq(erc20.balanceOf(stranger), 0, "the caller is never paid");
        assertEq(escrow.claimable(C3F9, address(erc20)), 0);
        // Zero now: a second call reverts, as withdraw does.
        vm.prank(stranger);
        vm.expectRevert(NewTradeEscrowV2.InvalidState.selector);
        escrow.withdrawFor(C3F9, address(erc20));
    }

    function test_WithdrawFor_AnAccountWithNothing_Reverts() public live {
        vm.prank(stranger);
        vm.expectRevert(NewTradeEscrowV2.InvalidState.selector);
        escrow.withdrawFor(C3F9, address(0));
    }

    function test_WithdrawFor_PaysAContractCreatorThatCannotCallWithdraw_Native() public live {
        PassiveCreator passive = new PassiveCreator();
        _royaltyBps(address(passive), 250);
        uint256 id = deposit();
        vm.prank(seller);
        escrow.list(id, address(0), PRICE, deadline, 250, _bShape());
        (OrderParameters memory p,,,,) = escrow.getOrder(id);
        vm.deal(address(this), PRICE);
        SeaportV2Mock(SEAPORT).fillAndPayNative{value: PRICE}(p, buyer);
        assertEq(escrow.claimable(address(passive), address(0)), 0.025 ether);
        vm.prank(stranger);
        escrow.withdrawFor(address(passive), address(0));
        assertEq(address(passive).balance, 0.025 ether);
    }

    function test_WithdrawFor_IsReentrancyLocked() public live {
        ReenteringPayee payee = new ReenteringPayee(escrow);
        _royaltyBps(address(payee), 250);
        uint256 id = deposit();
        vm.prank(seller);
        escrow.list(id, address(0), PRICE, deadline, 250, _bShape());
        (OrderParameters memory p,,,,) = escrow.getOrder(id);
        vm.deal(address(this), PRICE);
        SeaportV2Mock(SEAPORT).fillAndPayNative{value: PRICE}(p, buyer);
        escrow.withdrawFor(address(payee), address(0));
        assertEq(address(payee).balance, 0.025 ether);
        assertEq(bytes4(payee.reentryError()), NewTradeEscrowV2.Reentrancy.selector);
    }

}
