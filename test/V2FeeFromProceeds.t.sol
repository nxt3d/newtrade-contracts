// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {V2RoyaltyServiceTest} from "./V2RoyaltyService.t.sol";
import {NewTradeEscrowV2} from "../src/NewTradeEscrowV2.sol";
import {NewTradeEscrowV2Seeder} from "./legacy/NewTradeEscrowV2Seeder.sol";
import {Payout, BundleState} from "../src/NewTradeV2Types.sol";
import {OrderParameters} from "../src/interfaces/ISeaport.sol";
import {SeaportV2Mock} from "./helpers/SeaportV2Mock.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {stdError} from "forge-std/StdError.sol";

/// A surplus recipient that tries to re-enter the escrow while being paid.
contract ReenteringSurplusRecipient {
    NewTradeEscrowV2 internal immutable escrow;
    bytes public reentryError;

    constructor(NewTradeEscrowV2 escrow_) {
        escrow = escrow_;
    }

    receive() external payable {
        try escrow.withdrawSurplus(address(0), address(this), 1) {}
        catch (bytes memory err) {
            reentryError = err;
        }
    }
}

/// Forces native value into a contract that has no payable path for it.
contract ForceSend {
    constructor(address payable to) payable {
        selfdestruct(to);
    }
}

/**
 * escrow-fee-from-proceeds-sep25: the protocol fee is taken FROM the escrow item
 * at first exit, never carried as a consideration item; the escrow keeps an owed
 * ledger (`totalOwed`) and the admin may withdraw only `balance - totalOwed`.
 *
 * Base harness (V2BundleEscrowTest): PRICE 1 ether, fee 250 bps, treasury 0xFEE,
 * payment tokens ETH + erc20, the test contract is admin + upgrader.
 */
contract V2FeeFromProceedsTest is V2RoyaltyServiceTest {
    event ProceedsCredited(uint256 indexed bundleId, address indexed seller, address indexed token, uint256 amount);
    event SurplusWithdrawn(address indexed token, address indexed to, uint256 amount, address indexed by);
    event TotalOwedSeeded(address indexed token, uint256 total, uint256 accounts);

    address other = address(0x0717);

    // ---------------------------------------------------------------- helpers

    function _feeSnapshot(uint256 id) internal view returns (uint256) {
        return uint256(vm.load(address(escrow), keccak256(abi.encode(id, uint256(21)))));
    }

    function _one(uint256 escrowAmount) internal view returns (Payout[] memory ps) {
        ps = new Payout[](1);
        ps[0] = Payout(payable(address(escrow)), escrowAmount);
    }

    function _two(uint256 escrowAmount, address to, uint256 amount) internal view returns (Payout[] memory ps) {
        ps = new Payout[](2);
        ps[0] = Payout(payable(address(escrow)), escrowAmount);
        ps[1] = Payout(payable(to), amount);
    }

    function _listWith(address token, uint256 price, uint16 maxRoyaltyBps, Payout[] memory ps)
        internal
        returns (uint256 id, OrderParameters memory p)
    {
        id = deposit();
        p = escrow.previewOrderParameters(id, token, price, deadline, maxRoyaltyBps, ps, uint64(block.timestamp));
        vm.prank(seller);
        escrow.list(id, token, price, deadline, maxRoyaltyBps, ps);
    }

    /// Lists an already-deposited bundle (the receipt NFT can be deposited once per test).
    function _listSame(uint256 id, address token, uint256 price, uint16 maxRoyaltyBps, Payout[] memory ps)
        internal
        returns (OrderParameters memory p)
    {
        p = escrow.previewOrderParameters(id, token, price, deadline, maxRoyaltyBps, ps, uint64(block.timestamp));
        vm.prank(seller);
        escrow.list(id, token, price, deadline, maxRoyaltyBps, ps);
    }

    function _fillErc20(OrderParameters memory p) internal {
        SeaportV2Mock(SEAPORT).fillAndPay(p, buyer, buyer);
    }

    function _fillNative(OrderParameters memory p, uint256 price) internal {
        vm.deal(address(this), address(this).balance + price);
        SeaportV2Mock(SEAPORT).fillAndPayNative{value: price}(p, buyer);
    }

    function _surplus(address token) internal view returns (uint256) {
        uint256 bal = token == address(0) ? address(escrow).balance : erc20.balanceOf(address(escrow));
        return bal - escrow.totalOwed(token);
    }

    /// The one user transaction: upgradeToAndCall(seeder, seedAndUpgrade(final, tokens, accounts)).
    /// f01-release-test-fixes: seed only (version 2), no vault switch.
    function _seedOnly(address[] memory accounts)
        internal
        returns (NewTradeEscrowV2 finalImpl, NewTradeEscrowV2Seeder seeder)
    {
        finalImpl = NewTradeEscrowV2(payable(deployCode("NewTradeEscrowV2.sol:NewTradeEscrowV2")));
        seeder = NewTradeEscrowV2Seeder(deployCode("NewTradeEscrowV2Seeder.sol:NewTradeEscrowV2Seeder"));
        escrow.upgradeToAndCall(
            address(seeder), abi.encodeCall(NewTradeEscrowV2Seeder.seedAndUpgrade, (address(finalImpl), _tokens(), accounts))
        );
    }

    /// The seed, then (on a pre-switch fixture) the F-01 vault switch.
    function _seed(address[] memory accounts) internal returns (NewTradeEscrowV2 finalImpl, NewTradeEscrowV2Seeder seeder) {
        (finalImpl, seeder) = _seedOnly(accounts);
        // partial-release-oct20: the live order is seed (v2, 2026-09-26), then the
        // F-01 vault switch (v3). A pre-switch fixture switches here.
        if (deferVaultSwitch && address(custody) == address(0)) _switchVault();
    }

    /// partial-release-oct20: the seeder (reinitializer(2)) is history on the live
    /// proxy; it ran before the F-01 switch (reinitializer(3)), which would make it
    /// unreachable. Tests of the seeder itself replay it on a pre-switch fixture.
    /// Deposits, listings and fills before the seed go through the legacy vault,
    /// as they did live; any release happens after the switch.
    modifier preSwitchFixture() {
        deferVaultSwitch = true;
        setUp();
        _;
    }

    function _tokens() internal view returns (address[] memory t) {
        t = new address[](2);
        t[0] = address(0);
        t[1] = address(erc20);
    }

    function _accounts(address a) internal pure returns (address[] memory x) {
        x = new address[](1);
        x[0] = a;
    }

    bytes32 constant ERC1967_IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function _implementation() internal view returns (address) {
        return address(uint160(uint256(vm.load(address(escrow), ERC1967_IMPL_SLOT))));
    }

    // ============================================================ validation truth table

    function test_Validation_FeeZero_EscrowCarriesTheWholePrice_SellerCreditedInFull() public {
        escrow.setProtocolFeeBps(0);
        (uint256 id, OrderParameters memory p) = _listWith(address(erc20), PRICE, 0, _one(PRICE));
        assertEq(_feeSnapshot(id), 0, "zero fee is snapshotted too");
        _fillErc20(p);
        assertEq(escrow.claimable(seller, address(erc20)), PRICE);
        assertEq(_surplus(address(erc20)), 0);
    }

    function test_Validation_Fee500_SellerCreditedItem0LessFee() public {
        escrow.setProtocolFeeBps(500);
        (uint256 id, OrderParameters memory p) = _listWith(address(erc20), PRICE, 0, _one(PRICE));
        assertEq(_feeSnapshot(id), 0.05 ether);
        vm.expectEmit(true, true, true, true, address(escrow));
        emit ProceedsCredited(id, seller, address(erc20), 0.95 ether);
        _fillErc20(p);
        assertEq(escrow.claimable(seller, address(erc20)), 0.95 ether);
        assertEq(escrow.totalOwed(address(erc20)), 0.95 ether);
        assertEq(_surplus(address(erc20)), 0.05 ether, "the fee stays in the escrow as surplus");
    }

    function test_Validation_FeeMax1000_SellerCreditedNinetyPercent() public {
        escrow.setProtocolFeeBps(1_000);
        (, OrderParameters memory p) = _listWith(address(erc20), PRICE, 0, _one(PRICE));
        _fillErc20(p);
        assertEq(escrow.claimable(seller, address(erc20)), 0.9 ether);
        assertEq(_surplus(address(erc20)), 0.1 ether);
    }

    function test_Validation_PriceOneWei_FeeFloorsToZero() public {
        escrow.setProtocolFeeBps(1_000);
        (uint256 id, OrderParameters memory p) = _listWith(address(erc20), 1, 0, _one(1));
        assertEq(_feeSnapshot(id), 0, "1 * 1000 / 10000 floors to 0");
        _fillErc20(p);
        assertEq(escrow.claimable(seller, address(erc20)), 1);
    }

    function test_Validation_Item0EqualsFee_Accepted_SellerCreditedZero() public {
        escrow.setProtocolFeeBps(1_000);
        (uint256 id, OrderParameters memory p) = _listWith(address(erc20), PRICE, 0, _two(0.1 ether, other, 0.9 ether));
        assertEq(_feeSnapshot(id), 0.1 ether);
        vm.expectEmit(true, true, true, true, address(escrow));
        emit ProceedsCredited(id, seller, address(erc20), 0);
        _fillErc20(p);
        assertEq(escrow.claimable(seller, address(erc20)), 0);
        assertEq(_surplus(address(erc20)), 0.1 ether);
    }

    function test_Validation_Item0BelowFee_Rejected() public {
        escrow.setProtocolFeeBps(1_000);
        uint256 id = deposit();
        vm.prank(seller);
        vm.expectRevert(NewTradeEscrowV2.InvalidConsideration.selector);
        escrow.list(id, address(erc20), PRICE, deadline, 0, _two(0.1 ether - 1, other, 0.9 ether + 1));
        assertEq(uint8(escrow.getBundle(id).state), uint8(BundleState.Deposited));
    }

    function test_Validation_TreasuryItemIsNeverCountedAsTheFee() public {
        // Present and large, yet it does not satisfy item0 >= fee.
        escrow.setProtocolFeeBps(1_000);
        uint256 id = deposit();
        vm.prank(seller);
        vm.expectRevert(NewTradeEscrowV2.InvalidConsideration.selector);
        escrow.list(id, address(erc20), PRICE, deadline, 0, _two(0.05 ether, treasury, 0.95 ether));
        // And when present alongside a covering item0, the fee is STILL deducted from item0 (never "paid" by it).
        _fillErc20(_listSame(id, address(erc20), PRICE, 0, _two(0.975 ether, treasury, 0.025 ether)));
        assertEq(escrow.claimable(seller, address(erc20)), 0.875 ether, "0.975 - the 0.1 fee");
    }

    /// RE-ANCHORED (option B, escrow-option-b-sep26): bundle #3's merged shape
    /// (a creator item, here the treasury as creator) is now REFUSED - the
    /// creator is credited out of item[0] at first exit and may never also be
    /// paid by an item. The same sale without that item lists and credits both.
    function test_Validation_MergedLegacyShape_NowRefused_TheCreatorIsCreditedInstead() public {
        _support(true);
        _quote(treasury, 0.1 ether);
        uint256 id = deposit();
        vm.prank(seller);
        vm.expectRevert(NewTradeEscrowV2.InvalidConsideration.selector);
        escrow.list(id, address(erc20), PRICE, deadline, 1_000, _two(0.875 ether, treasury, 0.125 ether));
        _fillErc20(_listSame(id, address(erc20), PRICE, 1_000, _one(PRICE)));
        assertEq(escrow.claimable(seller, address(erc20)), 0.875 ether, "1 - 0.1 royalty - 0.025 fee");
        assertEq(escrow.claimable(treasury, address(erc20)), 0.1 ether, "the creator's royalty, credited");
        assertEq(erc20.balanceOf(treasury), 0, "no item paid the creator");
    }

    function test_Validation_SellerAsCreator_CountsOnlyItem0LessFee() public {
        _support(true);
        _quote(seller, 0.1 ether);
        // Option B: item0 must cover royalty + fee (0.125). 0.12 does not.
        uint256 id = deposit();
        vm.prank(seller);
        vm.expectRevert(NewTradeEscrowV2.InvalidConsideration.selector);
        escrow.list(id, address(erc20), PRICE, deadline, 1_000, _two(0.12 ether, other, 0.88 ether));
        // item0 == royalty + fee exactly is accepted; seller == creator, so both
        // credits land in one balance: (0.125 - 0.1 - 0.025) + 0.1 = item0 - fee.
        _fillErc20(_listSame(id, address(erc20), PRICE, 1_000, _two(0.125 ether, other, 0.875 ether)));
        assertEq(escrow.claimable(seller, address(erc20)), 0.1 ether);
    }

    // ============================================================ snapshot and first exit

    function test_Snapshot_FrozenAtList_ALaterFeeOrTreasuryChangeNeverTouchesIt() public {
        (uint256 id, OrderParameters memory p) = _listWith(address(erc20), PRICE, 0, _one(PRICE));
        assertEq(_feeSnapshot(id), 0.025 ether);
        escrow.setProtocolFeeBps(1_000);
        escrow.setTreasury(other);
        assertEq(_feeSnapshot(id), 0.025 ether);
        _fillErc20(p);
        assertEq(escrow.claimable(seller, address(erc20)), 0.975 ether);
        assertEq(_surplus(address(erc20)), 0.025 ether);
        assertEq(erc20.balanceOf(other), 0, "the new treasury is not paid anything");
    }

    function test_FirstExit_ABundleListedBeforeTheUpgrade_ZeroSnapshot_PaysTheFullItem() public {
        (uint256 id, OrderParameters memory p) = _listWith(address(erc20), PRICE, 0, _one(PRICE));
        // Exactly what a pre-upgrade listing looks like: no fee snapshot was ever written.
        vm.store(address(escrow), keccak256(abi.encode(id, uint256(21))), bytes32(0));
        _fillErc20(p);
        assertEq(escrow.claimable(seller, address(erc20)), PRICE);
        assertEq(_surplus(address(erc20)), 0);
    }

    function test_FirstExit_Native_CreditsNet_TotalOwedTracks_WithdrawDebits() public {
        (, OrderParameters memory p) = _listWith(address(0), PRICE, 0, _one(PRICE));
        _fillNative(p, PRICE);
        assertEq(escrow.claimable(seller, address(0)), 0.975 ether);
        assertEq(escrow.totalOwed(address(0)), 0.975 ether);
        assertEq(address(escrow).balance, PRICE);
        vm.prank(seller);
        escrow.withdraw(address(0));
        assertEq(escrow.totalOwed(address(0)), 0);
        assertEq(address(escrow).balance, 0.025 ether);
        assertEq(seller.balance, 0.975 ether);
    }

    // ============================================================ withdrawSurplus

    function test_WithdrawSurplus_LatchedUntilSeeded() public preSwitchFixture  {
        (, OrderParameters memory p) = _listWith(address(erc20), PRICE, 0, _one(PRICE));
        _fillErc20(p);
        // Version 1 (no seed): even real surplus is unreachable.
        vm.expectRevert(NewTradeEscrowV2.InvalidState.selector);
        escrow.withdrawSurplus(address(erc20), other, 1);
    }

    function test_Seeder_RetainedFeesAreNotOwed_ASellerOnlySeedIsRejected() public preSwitchFixture  {
        (, OrderParameters memory p) = _listWith(address(erc20), PRICE, 0, _one(PRICE));
        _fillErc20(p);
        // Seed the ledger that the pre-upgrade flow would have (the seller's credit).
        // (Here the first exit already wrote totalOwed; seeding requires _totalOwed == 0,
        // so reset it to model a pre-upgrade escrow, then seed from the ledger.)
        vm.store(address(escrow), keccak256(abi.encode(address(erc20), uint256(22))), bytes32(0));
        // The ledger balance includes the retained fee, so a strict seed of [seller] must FAIL...
        address[] memory sellerOnly = _accounts(seller);
        NewTradeEscrowV2 fin = NewTradeEscrowV2(payable(deployCode("NewTradeEscrowV2.sol:NewTradeEscrowV2")));
        NewTradeEscrowV2Seeder seeder = NewTradeEscrowV2Seeder(deployCode("NewTradeEscrowV2Seeder.sol:NewTradeEscrowV2Seeder"));
        vm.expectRevert(
            abi.encodeWithSelector(NewTradeEscrowV2Seeder.SeedMismatch.selector, address(erc20), 0.975 ether, 1 ether)
        );
        escrow.upgradeToAndCall(address(seeder), abi.encodeCall(NewTradeEscrowV2Seeder.seedAndUpgrade, (address(fin), _tokens(), sellerOnly)));
        fin;
    }

    function test_WithdrawSurplus_AfterSeed_RoleZeroCapNativeErc20() public preSwitchFixture  {
        _seed(new address[](0)); // an empty escrow: every total is 0 == balance 0
        assertEq(escrow.totalOwed(address(0)), 0);
        // A native sale and an ERC-20 sale, each leaving its fee as surplus.
        (, OrderParameters memory pn) = _listWith(address(0), PRICE, 0, _one(PRICE));
        _fillNative(pn, PRICE);
        vm.prank(seller);
        escrow.withdraw(address(0)); // the seller takes 0.975; surplus 0.025 remains

        // non-admin
        vm.prank(other);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, other, bytes32(0))
        );
        escrow.withdrawSurplus(address(0), other, 1);
        // zero recipient / zero amount
        vm.expectRevert(NewTradeEscrowV2.InvalidState.selector);
        escrow.withdrawSurplus(address(0), address(0), 1);
        vm.expectRevert(NewTradeEscrowV2.InvalidState.selector);
        escrow.withdrawSurplus(address(0), other, 0);
        // one wei over the cap
        vm.expectRevert(NewTradeEscrowV2.InvalidState.selector);
        escrow.withdrawSurplus(address(0), other, 0.025 ether + 1);
        // exactly the cap, native
        vm.expectEmit(true, true, true, true, address(escrow));
        emit SurplusWithdrawn(address(0), other, 0.025 ether, address(this));
        escrow.withdrawSurplus(address(0), other, 0.025 ether);
        assertEq(other.balance, 0.025 ether);
        assertEq(address(escrow).balance, 0);
        assertEq(escrow.totalOwed(address(0)), 0);
    }

    function test_WithdrawSurplus_NeverReachesAnUnwithdrawnSellerCredit() public preSwitchFixture  {
        _seed(new address[](0));
        (, OrderParameters memory p) = _listWith(address(erc20), PRICE, 0, _one(PRICE));
        _fillErc20(p);
        // The seller has NOT withdrawn: balance 1, owed 0.975, surplus 0.025.
        vm.expectRevert(NewTradeEscrowV2.InvalidState.selector);
        escrow.withdrawSurplus(address(erc20), other, 0.025 ether + 1);
        escrow.withdrawSurplus(address(erc20), other, 0.025 ether);
        assertEq(escrow.claimable(seller, address(erc20)), 0.975 ether, "untouched by the admin");
        vm.prank(seller);
        escrow.withdraw(address(erc20));
        assertEq(erc20.balanceOf(address(escrow)), 0);
    }

    function test_WithdrawSurplus_BalanceBelowOwed_FailsSafe() public preSwitchFixture  {
        _seed(new address[](0));
        (, OrderParameters memory p) = _listWith(address(erc20), PRICE, 0, _one(PRICE));
        _fillErc20(p);
        // A shortfall (e.g. a fee-on-transfer token drained the escrow): the checked cap reverts.
        deal(address(erc20), address(escrow), 0.5 ether);
        vm.expectRevert(stdError.arithmeticError);
        escrow.withdrawSurplus(address(erc20), other, 1);
    }

    function test_WithdrawSurplus_StrayNative_ThenReentryBlocked() public preSwitchFixture  {
        _seed(new address[](0));
        new ForceSend{value: 3 ether}(payable(address(escrow)));
        assertEq(_surplus(address(0)), 3 ether, "a forced send is surplus, owed to no one");
        ReenteringSurplusRecipient r = new ReenteringSurplusRecipient(escrow);
        escrow.withdrawSurplus(address(0), address(r), 1 ether);
        assertEq(address(r).balance, 1 ether);
        assertEq(bytes4(r.reentryError()), NewTradeEscrowV2.Reentrancy.selector, "the transient lock holds");
        assertEq(_surplus(address(0)), 2 ether);
    }

    // ============================================================ the three size trims fail SAFE
    // (size decision 2026-09-25, conditions 2-3): break the invariant each trim relies
    // on - by writing storage directly, since no code path can - and show the wrap
    // ends in a withdrawSurplus revert (Panic 0x11), never a payout.

    function _setTotalOwed(address token, uint256 value) internal {
        vm.store(address(escrow), keccak256(abi.encode(token, uint256(22))), bytes32(value));
    }

    /// TRIM 1 (unchecked `owed - fee` at first exit) relies on item0 >= fee. A fee
    /// snapshot above the escrow item makes net wrap HIGH: the admin cannot take
    /// anything and the seller's inflated credit cannot be paid.
    function test_Trim1_FeeAboveItem0_WrapNeverPays() public preSwitchFixture  {
        _seed(new address[](0));
        (uint256 id, OrderParameters memory p) = _listWith(address(0), PRICE, 0, _one(PRICE));
        vm.store(address(escrow), keccak256(abi.encode(id, uint256(21))), bytes32(PRICE + 1));
        _fillNative(p, PRICE);
        assertEq(escrow.claimable(seller, address(0)), type(uint256).max, "net wrapped high");
        assertGt(escrow.totalOwed(address(0)), address(escrow).balance, "totalOwed now exceeds the balance");
        vm.expectRevert(stdError.arithmeticError);
        escrow.withdrawSurplus(address(0), other, 1);
        vm.prank(seller);
        vm.expectRevert(NewTradeEscrowV2.InvalidRecipient.selector);
        escrow.withdraw(address(0));
        assertEq(address(escrow).balance, PRICE, "nothing left the escrow");
        assertEq(other.balance, 0);
    }

    /// TRIM 1, second branch: when the seller already holds a credit, the wrapped net
    /// overflows the checked `_claimable +=` and the whole fill reverts.
    function test_Trim1_FeeAboveItem0_WithAnExistingCredit_TheFillReverts() public preSwitchFixture  {
        _seed(new address[](0));
        (uint256 id, OrderParameters memory p) = _listWith(address(0), PRICE, 0, _one(PRICE));
        vm.store(address(escrow), keccak256(abi.encode(address(0), uint256(22))), bytes32(uint256(5)));
        vm.store(
            address(escrow), keccak256(abi.encode(address(0), keccak256(abi.encode(seller, uint256(17))))), bytes32(uint256(5))
        );
        vm.store(address(escrow), keccak256(abi.encode(id, uint256(21))), bytes32(PRICE + 1));
        vm.deal(address(this), PRICE);
        vm.expectRevert();
        SeaportV2Mock(SEAPORT).fillAndPayNative{value: PRICE}(p, buyer);
        assertEq(escrow.claimable(seller, address(0)), 5);
        assertEq(uint8(escrow.getBundle(id).state), uint8(BundleState.Listed));
    }

    /// TRIM 2 (unchecked `_totalOwed -= amount` in _debitOwed) relies on invariant (i).
    /// With the total below a seller's claimable, their withdrawal wraps it HIGH and
    /// every later withdrawSurplus reverts - the retained fee is stuck, never paid.
    function test_Trim2_TotalBelowClaimable_WrapNeverPays() public preSwitchFixture  {
        _seed(new address[](0));
        (, OrderParameters memory p) = _listWith(address(erc20), PRICE, 0, _one(PRICE));
        _fillErc20(p);
        _setTotalOwed(address(erc20), 0.5 ether); // (i) broken: 0.5 < claimable 0.975
        uint256 before = erc20.balanceOf(seller);
        vm.prank(seller);
        escrow.withdraw(address(erc20));
        assertEq(erc20.balanceOf(seller) - before, 0.975 ether, "the seller is paid only their own credit");
        assertGt(escrow.totalOwed(address(erc20)), erc20.balanceOf(address(escrow)), "total wrapped high");
        vm.expectRevert(stdError.arithmeticError);
        escrow.withdrawSurplus(address(erc20), other, 1);
        assertEq(erc20.balanceOf(other), 0);
        assertEq(erc20.balanceOf(address(escrow)), 0.025 ether, "the fee is stuck, not paid");
    }

    /// TRIM 3 (the checked cap): balance below totalOwed reverts with Panic 0x11 for
    /// every amount, native and ERC-20.
    function test_Trim3_BalanceBelowOwed_EveryAmountRevertsPanic() public preSwitchFixture  {
        _seed(new address[](0));
        (, OrderParameters memory pn) = _listWith(address(0), PRICE, 0, _one(PRICE));
        _fillNative(pn, PRICE);
        vm.deal(address(escrow), escrow.totalOwed(address(0)) - 1);
        uint256[3] memory amounts = [uint256(1), 0.025 ether, type(uint256).max];
        for (uint256 i; i < 3; ++i) {
            vm.expectRevert(stdError.arithmeticError);
            escrow.withdrawSurplus(address(0), other, amounts[i]);
        }
        assertEq(other.balance, 0);
    }

    // ============================================================ the seeder

    function test_Seeder_HappyPath_OneTx_SeedsAndLandsOnTheFinalImpl() public preSwitchFixture  {
        // A pre-upgrade escrow: a seller credit exists, totalOwed was never written.
        escrow.setProtocolFeeBps(0);
        (, OrderParameters memory p) = _listWith(address(0), PRICE, 0, _one(PRICE));
        _fillNative(p, PRICE);
        vm.store(address(escrow), keccak256(abi.encode(address(0), uint256(22))), bytes32(0));
        assertEq(escrow.totalOwed(address(0)), 0);
        vm.expectEmit(true, false, false, true, address(escrow));
        emit TotalOwedSeeded(address(0), PRICE, 1);
        (NewTradeEscrowV2 fin,) = _seed(_accounts(seller));
        assertEq(_implementation(), address(fin), "the proxy rests on the final impl, never the seeder");
        assertEq(escrow.totalOwed(address(0)), PRICE);
        assertEq(escrow.totalOwed(address(erc20)), 0);
        assertEq(_surplus(address(0)), 0);
    }

    function test_Seeder_OmittedAccount_RevertsTheWholeUpgrade() public preSwitchFixture  {
        escrow.setProtocolFeeBps(0);
        (, OrderParameters memory p) = _listWith(address(0), PRICE, 0, _one(PRICE));
        _fillNative(p, PRICE);
        vm.store(address(escrow), keccak256(abi.encode(address(0), uint256(22))), bytes32(0));
        address before = _implementation();
        NewTradeEscrowV2 fin = NewTradeEscrowV2(payable(deployCode("NewTradeEscrowV2.sol:NewTradeEscrowV2")));
        NewTradeEscrowV2Seeder seeder = NewTradeEscrowV2Seeder(deployCode("NewTradeEscrowV2Seeder.sol:NewTradeEscrowV2Seeder"));
        vm.expectRevert(abi.encodeWithSelector(NewTradeEscrowV2Seeder.SeedMismatch.selector, address(0), 0, PRICE));
        escrow.upgradeToAndCall(address(seeder), abi.encodeCall(NewTradeEscrowV2Seeder.seedAndUpgrade, (address(fin), _tokens(), new address[](0))));
        assertEq(_implementation(), before, "a reverted seed leaves the proxy where it was");
    }

    function test_Seeder_DuplicateAccount_AndStrayAtSeedTime_Revert() public preSwitchFixture  {
        escrow.setProtocolFeeBps(0);
        (, OrderParameters memory p) = _listWith(address(0), PRICE, 0, _one(PRICE));
        _fillNative(p, PRICE);
        vm.store(address(escrow), keccak256(abi.encode(address(0), uint256(22))), bytes32(0));
        NewTradeEscrowV2 fin = NewTradeEscrowV2(payable(deployCode("NewTradeEscrowV2.sol:NewTradeEscrowV2")));
        NewTradeEscrowV2Seeder seeder = NewTradeEscrowV2Seeder(deployCode("NewTradeEscrowV2Seeder.sol:NewTradeEscrowV2Seeder"));
        address[] memory twice = new address[](2);
        twice[0] = seller;
        twice[1] = seller;
        vm.expectRevert(abi.encodeWithSelector(NewTradeEscrowV2Seeder.SeedMismatch.selector, address(0), 2 * PRICE, PRICE));
        escrow.upgradeToAndCall(address(seeder), abi.encodeCall(NewTradeEscrowV2Seeder.seedAndUpgrade, (address(fin), _tokens(), twice)));
        new ForceSend{value: 1}(payable(address(escrow)));
        vm.expectRevert(abi.encodeWithSelector(NewTradeEscrowV2Seeder.SeedMismatch.selector, address(0), PRICE, PRICE + 1));
        escrow.upgradeToAndCall(address(seeder), abi.encodeCall(NewTradeEscrowV2Seeder.seedAndUpgrade, (address(fin), _tokens(), _accounts(seller))));
    }

    /// f01-release-test-fixes: the seed ALONE (version 2, before any vault switch)
    /// makes a second seed revert; the post-switch (version 3) rejection is kept as
    /// an additional assertion.
    function test_Seeder_OneShot_ASecondSeedReverts() public preSwitchFixture  {
        _seedOnly(new address[](0));
        assertEq(address(custody), address(0), "seed-only: the vault switch has not run");
        assertEq(_initializedVersion(), 2, "seed-only: version 2");
        NewTradeEscrowV2 fin = NewTradeEscrowV2(payable(deployCode("NewTradeEscrowV2.sol:NewTradeEscrowV2")));
        NewTradeEscrowV2Seeder seeder = NewTradeEscrowV2Seeder(deployCode("NewTradeEscrowV2Seeder.sol:NewTradeEscrowV2Seeder"));
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        escrow.upgradeToAndCall(address(seeder), abi.encodeCall(NewTradeEscrowV2Seeder.seedAndUpgrade, (address(fin), _tokens(), new address[](0))));
        assertEq(_initializedVersion(), 2, "a rejected second seed leaves version 2");

        _switchVault();
        assertEq(_initializedVersion(), 3, "after the switch: version 3");
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        escrow.upgradeToAndCall(address(seeder), abi.encodeCall(NewTradeEscrowV2Seeder.seedAndUpgrade, (address(fin), _tokens(), new address[](0))));
    }

    /// OpenZeppelin Initializable (ERC-7201) `_initialized`, read off the proxy.
    function _initializedVersion() internal view returns (uint64) {
        return uint64(
            uint256(vm.load(address(escrow), 0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00))
        );
    }

    function test_Seeder_BadFinalImplementation_Reverts() public preSwitchFixture  {
        NewTradeEscrowV2Seeder seeder = NewTradeEscrowV2Seeder(deployCode("NewTradeEscrowV2Seeder.sol:NewTradeEscrowV2Seeder"));
        vm.expectRevert(abi.encodeWithSelector(NewTradeEscrowV2Seeder.BadFinalImplementation.selector, other));
        escrow.upgradeToAndCall(address(seeder), abi.encodeCall(NewTradeEscrowV2Seeder.seedAndUpgrade, (other, _tokens(), new address[](0))));
    }

    function test_Seeder_OwnRoleCheck_AndNeverAResting_Implementation() public {
        NewTradeEscrowV2Seeder seeder = NewTradeEscrowV2Seeder(deployCode("NewTradeEscrowV2Seeder.sol:NewTradeEscrowV2Seeder"));
        NewTradeEscrowV2 fin = NewTradeEscrowV2(payable(deployCode("NewTradeEscrowV2.sol:NewTradeEscrowV2")));
        // Its OWN role check (the first hop's is the old implementation's): a fresh proxy has no roles.
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), seeder.UPGRADER_ROLE())
        );
        new ERC1967Proxy(address(seeder), abi.encodeCall(NewTradeEscrowV2Seeder.seedAndUpgrade, (address(fin), _tokens(), new address[](0))));
        // Were the proxy ever left resting on it, nothing could upgrade away from it.
        vm.store(address(escrow), ERC1967_IMPL_SLOT, bytes32(uint256(uint160(address(seeder)))));
        vm.expectRevert(NewTradeEscrowV2Seeder.SeederOnly.selector);
        escrow.upgradeToAndCall(address(fin), "");
        // And the implementation itself cannot be initialised.
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        seeder.seedAndUpgrade(address(fin), _tokens(), new address[](0));
    }

    function test_BareUpgradeToTheFinalImpl_LeavesWithdrawSurplusLatched() public preSwitchFixture  {
        NewTradeEscrowV2 fin = NewTradeEscrowV2(payable(deployCode("NewTradeEscrowV2.sol:NewTradeEscrowV2")));
        escrow.upgradeToAndCall(address(fin), "");
        new ForceSend{value: 1 ether}(payable(address(escrow)));
        vm.expectRevert(NewTradeEscrowV2.InvalidState.selector);
        escrow.withdrawSurplus(address(0), other, 1);
    }

    // ============================================================ the source guard

    /// The owed ledger has ONE write path. Every `_claimable[` in the escrow's
    /// source (comments stripped) lies inside `_creditOwed`, `_debitOwed` or
    /// `claimable`, and there are exactly three; the seeder only reads it, once,
    /// in `seedAndUpgrade`; the storage base only declares it.
    function test_SourceGuard_ClaimableIsTouchedOnlyByTheLedgerFunctions() public view {
        bytes memory esc = _stripComments(bytes(vm.readFile("src/NewTradeEscrowV2.sol")));
        uint256[] memory at = _positions(esc, "_claimable[");
        assertEq(at.length, 3, "exactly three _claimable[ in NewTradeEscrowV2.sol");
        for (uint256 i; i < at.length; ++i) {
            bytes32 fn = keccak256(_enclosingFunction(esc, at[i]));
            assertTrue(
                fn == keccak256("_creditOwed") || fn == keccak256("_debitOwed") || fn == keccak256("claimable"),
                string.concat("_claimable[ outside the ledger functions, in: ", string(_enclosingFunction(esc, at[i])))
            );
        }
        bytes memory seed = _stripComments(bytes(vm.readFile("test/legacy/NewTradeEscrowV2Seeder.sol")));
        uint256[] memory sat = _positions(seed, "_claimable[");
        assertEq(sat.length, 1, "the seeder reads the ledger exactly once");
        assertEq(_enclosingFunction(seed, sat[0]), bytes("seedAndUpgrade"));
        assertEq(_positions(seed, "sum += _claimable[").length, 1, "and only as a read into the sum");
        assertEq(_positions(_stripComments(bytes(vm.readFile("src/NewTradeEscrowV2Storage.sol"))), "_claimable[").length, 0);
    }

    function _stripComments(bytes memory src) internal pure returns (bytes memory out) {
        out = new bytes(src.length);
        uint256 n;
        for (uint256 i; i < src.length; ++i) {
            if (i + 1 < src.length && src[i] == "/" && src[i + 1] == "/") {
                while (i < src.length && src[i] != "\n") ++i;
            } else if (i + 1 < src.length && src[i] == "/" && src[i + 1] == "*") {
                i += 2;
                while (i + 1 < src.length && !(src[i] == "*" && src[i + 1] == "/")) ++i;
                ++i;
                continue;
            }
            if (i < src.length) out[n++] = src[i];
        }
        assembly {
            mstore(out, n)
        }
    }

    function _positions(bytes memory hay, bytes memory needle) internal pure returns (uint256[] memory found) {
        uint256[] memory tmp = new uint256[](hay.length);
        uint256 n;
        for (uint256 i; i + needle.length <= hay.length; ++i) {
            bool ok = true;
            for (uint256 j; j < needle.length; ++j) {
                if (hay[i + j] != needle[j]) {
                    ok = false;
                    break;
                }
            }
            if (ok) tmp[n++] = i;
        }
        found = new uint256[](n);
        for (uint256 k; k < n; ++k) found[k] = tmp[k];
    }

    /// The name of the last `function <name>(` that starts before `pos`.
    function _enclosingFunction(bytes memory src, uint256 pos) internal pure returns (bytes memory name) {
        uint256[] memory fns = _positions(src, "function ");
        uint256 start = type(uint256).max;
        for (uint256 i; i < fns.length && fns[i] < pos; ++i) start = fns[i] + 9;
        require(start != type(uint256).max, "no enclosing function");
        uint256 end = start;
        while (src[end] != "(") ++end;
        name = new bytes(end - start);
        for (uint256 i; i < name.length; ++i) name[i] = src[start + i];
    }
}
