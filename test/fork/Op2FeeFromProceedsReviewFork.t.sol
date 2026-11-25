// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {NewTradeEscrowV2} from "../../src/NewTradeEscrowV2.sol";
import {NewTradeEscrowV2Seeder} from "../legacy/NewTradeEscrowV2Seeder.sol";
import {BundleState} from "../../src/NewTradeV2Types.sol";
import {ISeaport, Order, OrderParameters} from "../../src/interfaces/ISeaport.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FeeForkForceSend, FeeForkZoneStub, IStrictRegistryArm} from "./EscrowFeeFromProceedsUpgradeFork.t.sol";

/**
 * op2 independent review of escrow/fee-from-proceeds at 4500902
 * (op2-review-escrow-fee-from-proceeds-sep25). TESTS ONLY.
 *
 * Pinned at block 51,804,470: the head op2's OWN event derivation was taken at
 * (an unpublished event-derivation record, 185 windows of
 * <= 2,000 blocks from 51,436,376: exactly two ProceedsCredited, no
 * ProceedsWithdrawn). A different block from op's 51,802,555 on purpose.
 *
 * What these add to op's fork suite:
 *   - the STRICT seed is blockable by a stranger's dust, and the package's only
 *     remedy ("re-run pre") cannot clear it (USDC: drop the token; ETH: none);
 *   - the seeder guards an omitted ACCOUNT, not an omitted TOKEN;
 *   - after a rollback the latch is spent: a bare re-upgrade is NOT latched,
 *     and a sale during the rollback becomes withdrawable "surplus".
 * Implementations are the build artifacts (deployCode). Nothing is broadcast.
 */
contract Op2FeeFromProceedsReviewForkTest is Test {
    uint256 constant OP2_FORK_BLOCK = 51_804_470;

    address constant PROXY = 0xCc29F5c82C8b7c01Cac6036047E7413Df458f86d;
    address constant CURRENT_IMPL = 0x08306a31FC2Dd0a00bd8780961FcCb923E22c314;
    address constant ADMIN = 0xF8e03bd4436371E0e2F7C02E529b2172fe72b4EF;
    address constant SELLER_2 = 0x9a704664009d615A90ddDf9345B6b8B2A214cFb2;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant SEAPORT = 0x0000000000000068F116a894984e2DB1123eB395;
    address constant VALIDATOR = 0xA000027A9B2802E1ddf7000061001e5c005A0000;
    address constant SIGNED_ZONE = 0x000056F7000000EcE9003ca63978907a00FFD100;
    address constant STRANGER = address(0x5712A6E2);

    bytes32 constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 constant INITIALIZABLE_SLOT = 0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;

    // op2's derivation at 51,804,470 (independent of op's owed-events.json).
    uint256 constant OWED_ADMIN = 9_400_000_000;
    uint256 constant OWED_SELLER_2 = 9_400_000;
    uint256 constant OWED_ETH = 9_409_400_000;
    uint256 constant BUNDLE_3 = 3;
    uint256 constant BUNDLE_3_ESCROW_ITEM = 89_000_000_000;

    NewTradeEscrowV2 escrow = NewTradeEscrowV2(payable(PROXY));
    address finalImpl;
    address seeder;
    bool forked;

    function setUp() public {
        forked = PROXY.code.length > 0 && SEAPORT.code.length > 0;
        if (!forked) return;
        vm.rollFork(OP2_FORK_BLOCK);
        finalImpl = deployCode("NewTradeEscrowV2.sol:NewTradeEscrowV2");
        seeder = deployCode("NewTradeEscrowV2Seeder.sol:NewTradeEscrowV2Seeder");
    }

    modifier onlyFork() {
        if (!forked) {
            vm.skip(true);
            return;
        }
        _;
    }

    // ------------------------------------------------------------------ helpers

    function _list(address a) internal pure returns (address[] memory x) {
        x = new address[](1);
        x[0] = a;
    }

    function _list(address a, address b) internal pure returns (address[] memory x) {
        x = new address[](2);
        x[0] = a;
        x[1] = b;
    }

    function _seedData(address[] memory tokens, address[] memory accounts) internal view returns (bytes memory) {
        return abi.encodeCall(NewTradeEscrowV2Seeder.seedAndUpgrade, (finalImpl, tokens, accounts));
    }

    /// The package's transaction (c), exactly: tokens [ETH, USDC], accounts [0xF8e0, 0x9a70].
    function _packageSeed() internal view returns (bytes memory) {
        return _seedData(_list(address(0), USDC), _list(ADMIN, SELLER_2));
    }

    function _impl() internal view returns (address) {
        return address(uint160(uint256(vm.load(PROXY, IMPLEMENTATION_SLOT))));
    }

    function _version() internal view returns (uint64) {
        return uint64(uint256(vm.load(PROXY, INITIALIZABLE_SLOT)));
    }

    function _fillBundle3() internal {
        address receipt = escrow.receipt();
        vm.prank(SIGNED_ZONE);
        IStrictRegistryArm(VALIDATOR).beforeAuthorizedTransfer(receipt, BUNDLE_3);
        vm.etch(SIGNED_ZONE, address(new FeeForkZoneStub()).code);
        (OrderParameters memory p,,,,) = escrow.getOrder(BUNDLE_3);
        uint256 price = escrow.getBundle(BUNDLE_3).price;
        address buyer = address(0xB0B0B0);
        vm.deal(buyer, price);
        vm.prank(buyer);
        assertTrue(ISeaport(SEAPORT).fulfillOrder{value: price}(Order(p, ""), bytes32(0)));
    }

    // =================================================================== tests

    function test_Op2_Preconditions_MyDerivationEqualsTheLiveLedger() public onlyFork {
        assertEq(block.number, OP2_FORK_BLOCK);
        assertEq(_impl(), CURRENT_IMPL);
        assertEq(_version(), 1);
        assertEq(escrow.claimable(ADMIN, address(0)), OWED_ADMIN);
        assertEq(escrow.claimable(SELLER_2, address(0)), OWED_SELLER_2);
        assertEq(PROXY.balance, OWED_ETH, "sum of my two derived credits == balance");
        assertEq(IERC20(USDC).balanceOf(PROXY), 0);
        assertEq(uint8(escrow.getBundle(BUNDLE_3).state), uint8(BundleState.Listed));
    }

    /// FINDING (liveness): one unit of USDC from anyone blocks the package's
    /// exact calldata, and re-running `pre` / adding an account cannot help.
    /// The working remedy is to drop USDC from `tokens`: nobody is owed USDC, so
    /// totalOwed(USDC) = 0 is TRUE and the dust is correctly surplus.
    function test_Op2_UsdcDustFromAStranger_BlocksThePackageSeed_DroppingUsdcIsTheRemedy() public onlyFork {
        deal(USDC, STRANGER, 1);
        vm.prank(STRANGER);
        assertTrue(IERC20(USDC).transfer(PROXY, 1));

        bytes memory data = _packageSeed();
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(NewTradeEscrowV2Seeder.SeedMismatch.selector, USDC, 0, 1));
        escrow.upgradeToAndCall(seeder, data);
        assertEq(_impl(), CURRENT_IMPL, "reverted whole: still the live implementation");
        assertEq(_version(), 1, "reinitializer(2) not spent");

        data = _seedData(_list(address(0)), _list(ADMIN, SELLER_2));
        vm.prank(ADMIN);
        escrow.upgradeToAndCall(seeder, data);
        assertEq(_impl(), finalImpl);
        assertEq(escrow.totalOwed(address(0)), OWED_ETH);
        assertEq(escrow.totalOwed(USDC), 0);
        vm.prank(ADMIN);
        vm.expectRevert(NewTradeEscrowV2.InvalidState.selector);
        escrow.withdrawSurplus(USDC, ADMIN, 2);
        vm.prank(ADMIN);
        escrow.withdrawSurplus(USDC, ADMIN, 1);
        assertEq(IERC20(USDC).balanceOf(PROXY), 0);
    }

    /// FINDING (liveness): forced ETH (a selfdestruct; also a stranger's own
    /// Seaport order paying the escrow, which receive() accepts) makes EVERY
    /// seed that includes ETH revert, with no account list that fixes it. This
    /// seeder can then never run; a new seeder build would be needed.
    function test_Op2_ForcedEthStray_BlocksEverySeedThatIncludesEth() public onlyFork {
        vm.deal(STRANGER, 1);
        vm.prank(STRANGER);
        new FeeForkForceSend{value: 1}(payable(PROXY));
        assertEq(PROXY.balance, OWED_ETH + 1);

        bytes memory data = _packageSeed();
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(NewTradeEscrowV2Seeder.SeedMismatch.selector, address(0), OWED_ETH, OWED_ETH + 1));
        escrow.upgradeToAndCall(seeder, data);
        assertEq(_impl(), CURRENT_IMPL);

        // No account list reaches balance: listing the admin twice overshoots.
        data = _seedData(_list(address(0)), _list(ADMIN, ADMIN));
        vm.prank(ADMIN);
        vm.expectRevert(
            abi.encodeWithSelector(NewTradeEscrowV2Seeder.SeedMismatch.selector, address(0), 2 * OWED_ADMIN, OWED_ETH + 1)
        );
        escrow.upgradeToAndCall(seeder, data);
        assertEq(_impl(), CURRENT_IMPL);
        assertEq(_version(), 1);
    }

    /// FINDING (honest-omission guard is per ACCOUNT, not per TOKEN): a token list
    /// without ETH seeds, unlatches withdrawSurplus, and leaves totalOwed(ETH) at
    /// 0 - so every seller's ETH reads as surplus and the admin can take it. The
    /// package calldata includes ETH; this is the hazard of editing it (e.g. as a
    /// "fix" for the ETH-stray revert above).
    function test_Op2_OmittingEthFromTokens_Seeds_AndSellersEthBecomesSurplus() public onlyFork {
        bytes memory data = _seedData(_list(USDC), _list(ADMIN, SELLER_2));
        vm.prank(ADMIN);
        escrow.upgradeToAndCall(seeder, data);
        assertEq(_impl(), finalImpl);
        assertEq(_version(), 2, "latch open");
        assertEq(escrow.totalOwed(address(0)), 0, "ETH never seeded");

        address to = makeAddr("op2-surplus-to-0x70");
        uint256 before = to.balance;
        vm.prank(ADMIN);
        escrow.withdrawSurplus(address(0), to, OWED_ETH);
        assertEq(to.balance - before, OWED_ETH, "every seller's ETH left as 'surplus'");
        assertEq(escrow.claimable(SELLER_2, address(0)), OWED_SELLER_2, "still owed, now unfunded");
        vm.prank(SELLER_2);
        vm.expectRevert(NewTradeEscrowV2.InvalidRecipient.selector);
        escrow.withdraw(address(0));
    }

    /// op's note, CORRECTED: after a rollback the latch (version >= 2) is already
    /// satisfied, so a bare re-upgrade is NOT latched. A sale while rolled back is
    /// credited by the old code without totalOwed; after the bare re-upgrade that
    /// seller's credit reads as surplus and the admin can take it. The package
    /// forbids the bare re-upgrade in prose only; this proves why.
    function test_Op2_AfterRollback_ABareReupgradeIsNotLatched_ASaleDuringRollbackBecomesSurplus() public onlyFork {
        bytes memory data = _packageSeed();
        vm.prank(ADMIN);
        escrow.upgradeToAndCall(seeder, data);
        vm.prank(ADMIN);
        escrow.upgradeToAndCall(CURRENT_IMPL, "");
        assertEq(_impl(), CURRENT_IMPL);

        _fillBundle3(); // the old code credits 0x9a70 the full item, _claimable only
        assertEq(escrow.claimable(SELLER_2, address(0)), OWED_SELLER_2 + BUNDLE_3_ESCROW_ITEM);

        vm.prank(ADMIN);
        escrow.upgradeToAndCall(finalImpl, "");
        assertEq(_version(), 2, "the latch is already open");
        assertEq(escrow.totalOwed(address(0)), OWED_ETH, "stale: misses the sale");
        assertEq(PROXY.balance - escrow.totalOwed(address(0)), BUNDLE_3_ESCROW_ITEM, "a seller's credit reads as surplus");

        address to = makeAddr("op2-surplus-to-0x71");
        uint256 before = to.balance;
        vm.prank(ADMIN);
        escrow.withdrawSurplus(address(0), to, BUNDLE_3_ESCROW_ITEM);
        assertEq(to.balance - before, BUNDLE_3_ESCROW_ITEM);
        vm.prank(SELLER_2);
        vm.expectRevert(NewTradeEscrowV2.InvalidRecipient.selector);
        escrow.withdraw(address(0));
    }

    /// The one-shot half of op's note holds: after a rollback this seeder cannot
    /// run again (reinitializer(2) is spent), so going forward needs a NEW seeder.
    function test_Op2_AfterRollback_ThisSeederCannotRunAgain() public onlyFork {
        bytes memory data = _packageSeed();
        vm.prank(ADMIN);
        escrow.upgradeToAndCall(seeder, data);
        vm.prank(ADMIN);
        escrow.upgradeToAndCall(CURRENT_IMPL, "");
        vm.prank(ADMIN);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        escrow.upgradeToAndCall(seeder, data);
        assertEq(_impl(), CURRENT_IMPL);
    }
}
