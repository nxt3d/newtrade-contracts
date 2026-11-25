// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {V2FeeFromProceedsTest} from "./V2FeeFromProceeds.t.sol";
import {NewTradeEscrowV2} from "../src/NewTradeEscrowV2.sol";
import {Payout, BundleState} from "../src/NewTradeV2Types.sol";
import {OrderParameters} from "../src/interfaces/ISeaport.sol";

/**
 * op2 independent review of escrow/fee-from-proceeds at 4500902: the crux-1/2
 * boundaries op's suite does not pin exactly. TESTS ONLY. Inherits op's
 * harness (and therefore re-runs its tests under this contract name).
 * Base: PRICE 1 ether, fee 250 bps unless set, payment token erc20.
 */
contract Op2FeeFromProceedsReviewTest is V2FeeFromProceedsTest {
    /// `n` payouts summing to exactly `price`: item0 to the escrow, the rest to
    /// distinct recipients, the last one taking the remainder.
    function _payouts(uint256 n, uint256 item0, uint256 price) internal view returns (Payout[] memory ps) {
        ps = new Payout[](n);
        ps[0] = Payout(payable(address(escrow)), item0);
        uint256 rest = price - item0;
        uint256 each = rest / (n - 1);
        for (uint256 i = 1; i < n; ++i) {
            uint256 amount = i == n - 1 ? rest - each * (n - 2) : each;
            ps[i] = Payout(payable(address(uint160(0xA000 + i))), amount);
        }
    }

    function test_Op2_ThirtyTwoItems_Item0ExactlyTheFee_At500_AcceptedAndCreditsZero() public {
        escrow.setProtocolFeeBps(500);
        uint256 fee = PRICE * 500 / 10_000;
        Payout[] memory ps = _payouts(32, fee, PRICE);
        (uint256 id, OrderParameters memory p) = _listWith(address(erc20), PRICE, 0, ps);
        assertEq(escrow.getPayouts(id).length, 32);
        assertEq(_feeSnapshot(id), fee);
        _fillErc20(p);
        assertEq(escrow.claimable(seller, address(erc20)), 0, "item0 - fee == 0");
        assertEq(_surplus(address(erc20)), fee);
    }

    function test_Op2_ThirtyThreeItems_Rejected() public {
        escrow.setProtocolFeeBps(500);
        uint256 id = deposit();
        vm.prank(seller);
        vm.expectRevert(NewTradeEscrowV2.InvalidConsideration.selector);
        escrow.list(id, address(erc20), PRICE, deadline, 0, _payouts(33, 0.5 ether, PRICE));
    }

    function test_Op2_At500_Item0OneWeiBelowTheFee_Rejected_AtTheFee_Accepted() public {
        escrow.setProtocolFeeBps(500);
        uint256 fee = PRICE * 500 / 10_000;
        uint256 id = deposit();
        vm.prank(seller);
        vm.expectRevert(NewTradeEscrowV2.InvalidConsideration.selector);
        escrow.list(id, address(erc20), PRICE, deadline, 0, _two(fee - 1, other, PRICE - fee + 1));
        assertEq(uint8(escrow.getBundle(id).state), uint8(BundleState.Deposited));
        _listSame(id, address(erc20), PRICE, 0, _two(fee, other, PRICE - fee));
        assertEq(_feeSnapshot(id), fee);
    }

    /// Rounding floors on the PRICE: at 500 bps 19 wei carries no fee, 20 wei carries 1.
    function test_Op2_FeeFloorsOnPrice_19WeiZero() public {
        escrow.setProtocolFeeBps(500);
        (uint256 a, OrderParameters memory pa) = _listWith(address(erc20), 19, 0, _one(19));
        assertEq(_feeSnapshot(a), 0);
        _fillErc20(pa);
        assertEq(escrow.claimable(seller, address(erc20)), 19);
    }

    function test_Op2_FeeFloorsOnPrice_20WeiOne() public {
        escrow.setProtocolFeeBps(500);
        (uint256 b, OrderParameters memory pb) = _listWith(address(erc20), 20, 0, _one(20));
        assertEq(_feeSnapshot(b), 1);
        _fillErc20(pb);
        assertEq(escrow.claimable(seller, address(erc20)), 19);
        assertEq(_surplus(address(erc20)), 1);
    }

    /// The rewritten guard says a fee raise between quote and list() binds and
    /// list() "succeeds ... always, since MAX_PROTOCOL_FEE_BPS is 10%". It binds
    /// only while item0 still covers the new fee; a quote whose item0 is below
    /// 10% of the price REVERTS on a raise, as before. (Doc precision, not a bug.)
    function test_Op2_FeeRaiseAfterQuote_RevertsWhenItem0NoLongerCoversIt() public {
        uint256 id = deposit();
        (, uint256 quotedFee,,) = escrow.quotePrimaryFees(id, PRICE);
        assertEq(quotedFee, 0.025 ether);
        Payout[] memory ps = _two(0.05 ether, other, 0.95 ether); // covers 250 bps (and 500)
        escrow.setProtocolFeeBps(1_000); // 0.1 ether > item0
        vm.prank(seller);
        vm.expectRevert(NewTradeEscrowV2.InvalidConsideration.selector);
        escrow.list(id, address(erc20), PRICE, deadline, 0, ps);
        escrow.setProtocolFeeBps(500); // a raise that item0 still covers binds
        _listSame(id, address(erc20), PRICE, 0, ps);
        assertEq(_feeSnapshot(id), 0.05 ether);
    }
}
