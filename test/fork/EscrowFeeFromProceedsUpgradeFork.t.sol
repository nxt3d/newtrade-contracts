// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {NewTradeEscrowV2} from "../../src/NewTradeEscrowV2.sol";
import {NewTradeEscrowV2Seeder} from "../legacy/NewTradeEscrowV2Seeder.sol";
import {Payout, ManifestEntry, BundleState} from "../../src/NewTradeV2Types.sol";
import {ISeaport, Order, OrderParameters} from "../../src/interfaces/ISeaport.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

interface IStrictRegistryArm {
    function beforeAuthorizedTransfer(address token, uint256 tokenId) external;
}

/// Returns the selector Seaport asks for and verifies nothing (the SignedZone
/// needs OpenSea-issued extraData a fork cannot produce).
contract FeeForkZoneStub {
    fallback() external {
        assembly ("memory-safe") {
            mstore(0, shl(224, shr(224, calldataload(0))))
            return(0, 32)
        }
    }
}

contract FeeForkForceSend {
    constructor(address payable to) payable {
        selfdestruct(to);
    }
}

/**
 * escrow-fee-from-proceeds-sep25: the LIVE Base escrow proxy, in a fork only,
 * taken through the ONE upgrade transaction
 *   upgradeToAndCall(seeder, seedAndUpgrade(finalImpl, [ETH, USDC], [0xF8e0, 0x9a70]))
 * as its upgrader 0xF8e0 (IMPERSONATED with vm.prank; nothing is broadcast).
 *
 * Both implementations are the build ARTIFACTS (deployCode), i.e. the bytes the
 * package deploys, not a test-compiled `new`.
 *
 * Pinned at block 51,802,555: the head the owed-ledger enumeration
 * (an unpublished owed-events record) was taken at.
 */
contract EscrowFeeFromProceedsUpgradeForkTest is Test {
    uint256 constant PINNED_FORK_BLOCK = 51_802_555;

    address constant PROXY = 0xCc29F5c82C8b7c01Cac6036047E7413Df458f86d;
    address constant CURRENT_IMPL = 0x08306a31FC2Dd0a00bd8780961FcCb923E22c314;
    address constant ADMIN = 0xF8e03bd4436371E0e2F7C02E529b2172fe72b4EF;
    address constant SELLER_2 = 0x9a704664009d615A90ddDf9345B6b8B2A214cFb2;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant SEAPORT = 0x0000000000000068F116a894984e2DB1123eB395;
    address constant VALIDATOR = 0xA000027A9B2802E1ddf7000061001e5c005A0000;
    address constant SIGNED_ZONE = 0x000056F7000000EcE9003ca63978907a00FFD100;
    address constant OPENSEA_FEE = 0x0000a26b00c1F0DF003000390027140000fAa719;
    address constant COLLECTION = 0xf4fd1a2Ea84a16Be24848Aa6f4242E9CAab18953;
    address constant HOLDER_101 = 0xD5c85198CB79443100c661d5bf5D66fa746Eea1d;

    bytes32 constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 constant INITIALIZABLE_SLOT = 0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;

    // The owed ledger, from ProceedsCredited/ProceedsWithdrawn 51,436,376 -> 51,802,555 (184 windows).
    uint256 constant OWED_ADMIN = 9_400_000_000;
    uint256 constant OWED_SELLER_2 = 9_400_000;
    uint256 constant OWED_ETH = 9_409_400_000;

    uint256 constant BUNDLE_3 = 3;
    uint256 constant BUNDLE_3_ESCROW_ITEM = 89_000_000_000;

    NewTradeEscrowV2 escrow = NewTradeEscrowV2(payable(PROXY));
    address finalImpl;
    address seeder;
    bool forked;

    event ProtocolFeeSnapshot(uint256 indexed bundleId, address indexed token, uint256 amount);

    function setUp() public {
        forked = PROXY.code.length > 0 && SEAPORT.code.length > 0;
        if (!forked) return;
        vm.rollFork(PINNED_FORK_BLOCK);
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

    function _tokens() internal pure returns (address[] memory t) {
        t = new address[](2);
        t[0] = address(0);
        t[1] = USDC;
    }

    function _accounts() internal pure returns (address[] memory a) {
        a = new address[](2);
        a[0] = ADMIN;
        a[1] = SELLER_2;
    }

    function _seedCalldata(address[] memory accounts) internal view returns (bytes memory) {
        return abi.encodeCall(NewTradeEscrowV2Seeder.seedAndUpgrade, (finalImpl, _tokens(), accounts));
    }

    /// THE upgrade transaction of the package.
    function _upgradeAndSeed() internal {
        vm.prank(ADMIN);
        escrow.upgradeToAndCall(seeder, _seedCalldata(_accounts()));
    }

    function _impl() internal view returns (address) {
        return address(uint160(uint256(vm.load(PROXY, IMPLEMENTATION_SLOT))));
    }

    function _initializedVersion() internal view returns (uint64) {
        return uint64(uint256(vm.load(PROXY, INITIALIZABLE_SLOT)));
    }

    function _feeSnapshot(uint256 id) internal view returns (uint256) {
        return uint256(vm.load(PROXY, keccak256(abi.encode(id, uint256(21)))));
    }

    function _escrowRecipientAmount(uint256 id) internal view returns (uint256) {
        return uint256(vm.load(PROXY, keccak256(abi.encode(id, uint256(16)))));
    }

    function _surplus(address token) internal view returns (uint256) {
        uint256 bal = token == address(0) ? PROXY.balance : IERC20(token).balanceOf(PROXY);
        return bal - escrow.totalOwed(token);
    }

    /// Arm the strict registry while the SignedZone still has its real code, THEN stub the zone.
    function _armAndStub(uint256 id) internal {
        address receipt = escrow.receipt();
        vm.prank(SIGNED_ZONE);
        IStrictRegistryArm(VALIDATOR).beforeAuthorizedTransfer(receipt, id);
        vm.etch(SIGNED_ZONE, address(new FeeForkZoneStub()).code);
    }

    function _fillNative(uint256 id, uint256 price) internal {
        (OrderParameters memory p,,,,) = escrow.getOrder(id);
        address buyer = address(0xB0B0B0);
        vm.deal(buyer, price);
        vm.prank(buyer);
        assertTrue(ISeaport(SEAPORT).fulfillOrder{value: price}(Order(p, ""), bytes32(0)));
    }

    // =================================================================== tests

    function test_Preconditions_TheLiveProxyAtThePinnedBlock() public onlyFork {
        assertEq(block.number, PINNED_FORK_BLOCK);
        assertEq(_impl(), CURRENT_IMPL, "rollback target is the live implementation");
        assertEq(_initializedVersion(), 1, "reinitializer(2) is free");
        assertTrue(escrow.hasRole(escrow.UPGRADER_ROLE(), ADMIN));
        assertTrue(escrow.hasRole(escrow.DEFAULT_ADMIN_ROLE(), ADMIN));
        // The two appended mappings are unused today (the keys this upgrade reads).
        assertEq(vm.load(PROXY, keccak256(abi.encode(address(0), uint256(22)))), bytes32(0));
        assertEq(vm.load(PROXY, keccak256(abi.encode(USDC, uint256(22)))), bytes32(0));
        assertEq(_feeSnapshot(BUNDLE_3), 0);
    }

    /// The account list is complete: its sum equals the balance, per token.
    function test_EventEnumeration_SumEqualsBalance() public onlyFork {
        assertEq(escrow.claimable(ADMIN, address(0)), OWED_ADMIN);
        assertEq(escrow.claimable(SELLER_2, address(0)), OWED_SELLER_2);
        assertEq(OWED_ADMIN + OWED_SELLER_2, OWED_ETH);
        assertEq(PROXY.balance, OWED_ETH, "sum == balance == 9,409,400,000");
        assertEq(IERC20(USDC).balanceOf(PROXY), 0);
        assertEq(escrow.claimable(ADMIN, USDC) + escrow.claimable(SELLER_2, USDC), 0);
    }

    function test_UpgradeAndSeed_AsTheLiveUpgrader_ThenBothSellersWithdrawExactly() public onlyFork {
        _upgradeAndSeed();
        assertEq(_impl(), finalImpl, "the proxy rests on the final implementation");
        assertEq(_initializedVersion(), 2);
        assertEq(escrow.totalOwed(address(0)), OWED_ETH);
        assertEq(_surplus(address(0)), 0);
        assertEq(escrow.totalOwed(USDC), 0);
        assertEq(_surplus(USDC), 0);
        vm.prank(ADMIN);
        vm.expectRevert(NewTradeEscrowV2.InvalidState.selector);
        escrow.withdrawSurplus(address(0), ADMIN, 1);

        uint256 before = ADMIN.balance;
        vm.prank(ADMIN);
        assertEq(escrow.withdraw(address(0)), OWED_ADMIN);
        assertEq(ADMIN.balance - before, OWED_ADMIN);
        assertEq(escrow.totalOwed(address(0)), OWED_SELLER_2);

        before = SELLER_2.balance;
        vm.prank(SELLER_2);
        assertEq(escrow.withdraw(address(0)), OWED_SELLER_2);
        assertEq(SELLER_2.balance - before, OWED_SELLER_2);
        assertEq(escrow.totalOwed(address(0)), 0);
        assertEq(PROXY.balance, 0);
    }

    function test_Plant_OmittedAccount_RevertsTheWholeUpgrade() public onlyFork {
        address[] memory onlyAdmin = new address[](1);
        onlyAdmin[0] = ADMIN;
        bytes memory data = _seedCalldata(onlyAdmin);
        vm.prank(ADMIN);
        vm.expectRevert(
            abi.encodeWithSelector(NewTradeEscrowV2Seeder.SeedMismatch.selector, address(0), OWED_ADMIN, OWED_ETH)
        );
        escrow.upgradeToAndCall(seeder, data);
        assertEq(_impl(), CURRENT_IMPL, "nothing changed");
        assertEq(_initializedVersion(), 1);
    }

    function test_Plant_BareUpgradeToTheFinalImpl_LeavesWithdrawSurplusUnusable() public onlyFork {
        vm.prank(ADMIN);
        escrow.upgradeToAndCall(finalImpl, "");
        assertEq(_impl(), finalImpl);
        assertEq(escrow.totalOwed(address(0)), 0, "unseeded: the whole balance would look like surplus");
        // ...but the latch holds: no amount is withdrawable, not even a stray.
        new FeeForkForceSend{value: 1 ether}(payable(PROXY));
        vm.startPrank(ADMIN);
        vm.expectRevert(NewTradeEscrowV2.InvalidState.selector);
        escrow.withdrawSurplus(address(0), ADMIN, 1);
        vm.expectRevert(NewTradeEscrowV2.InvalidState.selector);
        escrow.withdrawSurplus(address(0), ADMIN, OWED_ETH);
        vm.stopPrank();
        assertEq(PROXY.balance, OWED_ETH + 1 ether);
    }

    function test_StraySendAfterSeeding_IsSurplus_AdminOnly_ExactlyThatAmount() public onlyFork {
        _upgradeAndSeed();
        uint256 stray = 12_345;
        new FeeForkForceSend{value: stray}(payable(PROXY));
        assertEq(_surplus(address(0)), stray);
        vm.prank(SELLER_2);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, SELLER_2, bytes32(0))
        );
        escrow.withdrawSurplus(address(0), SELLER_2, stray);
        vm.prank(ADMIN);
        vm.expectRevert(NewTradeEscrowV2.InvalidState.selector);
        escrow.withdrawSurplus(address(0), ADMIN, stray + 1);
        address to = address(0x5E5E5E);
        vm.prank(ADMIN);
        escrow.withdrawSurplus(address(0), to, stray);
        assertEq(to.balance, stray);
        assertEq(PROXY.balance, OWED_ETH);
        assertEq(escrow.totalOwed(address(0)), OWED_ETH);
        assertEq(escrow.claimable(ADMIN, address(0)), OWED_ADMIN);
        assertEq(escrow.claimable(SELLER_2, address(0)), OWED_SELLER_2);
    }

    /// Bundle 3 (Listed before the upgrade, legacy merged shape, no fee snapshot):
    /// every observable is identical after the upgrade, and a fill credits the
    /// FULL escrow item.
    function test_Bundle3_UnchangedByTheUpgrade_AndAFillCreditsTheFullEscrowItem() public onlyFork {
        bytes32 orderBefore = _order(BUNDLE_3);
        bytes32 bundleBefore = keccak256(abi.encode(escrow.getBundle(BUNDLE_3)));
        bytes32 payoutsBefore = keccak256(abi.encode(escrow.getPayouts(BUNDLE_3)));
        bytes32 royaltyBefore = keccak256(abi.encode(escrow.getRoyaltySnapshot(BUNDLE_3)));
        uint256 recipientAmountBefore = _escrowRecipientAmount(BUNDLE_3);
        assertEq(recipientAmountBefore, BUNDLE_3_ESCROW_ITEM);

        _upgradeAndSeed();

        assertEq(_order(BUNDLE_3), orderBefore, "getOrder(3) changed");
        assertEq(keccak256(abi.encode(escrow.getBundle(BUNDLE_3))), bundleBefore, "getBundle(3) changed");
        assertEq(keccak256(abi.encode(escrow.getPayouts(BUNDLE_3))), payoutsBefore, "getPayouts(3) changed");
        assertEq(keccak256(abi.encode(escrow.getRoyaltySnapshot(BUNDLE_3))), royaltyBefore, "royalty snapshot changed");
        assertEq(_escrowRecipientAmount(BUNDLE_3), recipientAmountBefore, "escrow-recipient amount changed");
        assertEq(_feeSnapshot(BUNDLE_3), 0, "a pre-upgrade listing has no fee snapshot");

        uint256 price = escrow.getBundle(BUNDLE_3).price;
        assertEq(escrow.getBundle(BUNDLE_3).paymentToken, address(0));
        _armAndStub(BUNDLE_3);
        _fillNative(BUNDLE_3, price);
        assertEq(uint8(escrow.getBundle(BUNDLE_3).state), uint8(BundleState.Issued));
        assertEq(escrow.claimable(SELLER_2, address(0)), OWED_SELLER_2 + BUNDLE_3_ESCROW_ITEM, "full 8.9e10 credited");
        assertEq(escrow.totalOwed(address(0)), OWED_ETH + BUNDLE_3_ESCROW_ITEM);
        assertEq(_surplus(address(0)), 0, "nothing retained from a pre-upgrade listing");
    }

    /// A FRESH listing after the upgrade: bundle #2's shape (no protocol-fee item),
    /// the fee frozen at list(), deducted at first exit, withdrawn by the admin.
    function test_FreshDepositListAndRealSeaportFill_FeeFromProceeds() public onlyFork {
        _upgradeAndSeed();
        uint256 price = 10_000_000_000;
        uint256 royalty = 500_000_000; // 5 % to 0xF8e0 (creator == treasury: direct, not routed)
        uint256 market = 100_000_000; // 1 % OpenSea
        uint256 fee = 500_000_000; // 500 bps, live
        // OPTION B (escrow-option-b-sep26; this test compiles the current source):
        // the royalty is credited out of the escrow item, not an item of its own.
        uint256 item0 = price - market; // 0.99 P

        (address qTreasury, uint256 qFee, address qCreator, uint256 qRoyalty) = _quoteFor101(price);
        assertEq(qTreasury, ADMIN);
        assertEq(qFee, fee);
        assertEq(qCreator, ADMIN);
        assertEq(qRoyalty, royalty);

        address vault = escrow.vault();
        uint64 deadline = uint64(block.timestamp + 14 days);
        vm.startPrank(HOLDER_101);
        IERC721(COLLECTION).approve(vault, 101);
        uint256 id = escrow.deposit(COLLECTION, 101, new ManifestEntry[](0), deadline);
        Payout[] memory ps = new Payout[](2);
        ps[0] = Payout(payable(PROXY), item0);
        ps[1] = Payout(payable(OPENSEA_FEE), market);
        vm.expectEmit(true, true, false, true, PROXY);
        emit ProtocolFeeSnapshot(id, address(0), fee);
        escrow.list(id, address(0), price, deadline, 500, ps);
        vm.stopPrank();

        Payout[] memory stored = escrow.getPayouts(id);
        assertEq(stored.length, 2);
        assertEq(stored[0].recipient, PROXY);
        assertEq(stored[0].amount, 9_900_000_000, "escrow 0.99P");
        assertEq(stored[1].recipient, OPENSEA_FEE);
        assertEq(stored[1].amount, 100_000_000, "OpenSea 0.01P");
        assertEq(_feeSnapshot(id), fee);

        uint256 adminBefore = ADMIN.balance;
        uint256 marketBefore = OPENSEA_FEE.balance;
        _armAndStub(id);
        _fillNative(id, price);
        assertEq(uint8(escrow.getBundle(id).state), uint8(BundleState.Issued));
        assertEq(ADMIN.balance - adminBefore, 0, "no item pays the creator");
        assertEq(escrow.claimable(ADMIN, address(0)), OWED_ADMIN + royalty, "0xF8e0 credited its 0.05P royalty");
        assertEq(OPENSEA_FEE.balance - marketBefore, market);
        assertEq(escrow.claimable(HOLDER_101, address(0)), 8_900_000_000, "seller credited 0.89P = item0 - royalty - fee");
        assertEq(escrow.totalOwed(address(0)), OWED_ETH + 8_900_000_000 + royalty);
        assertEq(_surplus(address(0)), fee, "0.05P retained as surplus");

        vm.prank(ADMIN);
        vm.expectRevert(NewTradeEscrowV2.InvalidState.selector);
        escrow.withdrawSurplus(address(0), ADMIN, fee + 1);
        adminBefore = ADMIN.balance;
        vm.prank(ADMIN);
        escrow.withdrawSurplus(address(0), ADMIN, fee);
        assertEq(ADMIN.balance - adminBefore, fee);
        assertEq(_surplus(address(0)), 0);
        assertEq(escrow.claimable(HOLDER_101, address(0)), 8_900_000_000, "untouched by the admin");
    }

    function test_Rollback_ToTheLiveImplementation() public onlyFork {
        _upgradeAndSeed();
        vm.prank(ADMIN);
        escrow.upgradeToAndCall(CURRENT_IMPL, "");
        assertEq(_impl(), CURRENT_IMPL);
        // The old code reads the same ledger; the appended slots are inert to it.
        assertEq(escrow.claimable(ADMIN, address(0)), OWED_ADMIN);
        assertEq(escrow.claimable(SELLER_2, address(0)), OWED_SELLER_2);
        vm.prank(SELLER_2);
        assertEq(escrow.withdraw(address(0)), OWED_SELLER_2);
        // ONE-WAY for the ledger: version 2 is spent and _totalOwed is now stale
        // (the old code debited _claimable without it). Re-applying this upgrade
        // after a rollback needs a NEW seeder (reinitializer(3)), never a bare
        // upgrade - documented in the package's rollback section.
        assertEq(_initializedVersion(), 2);
        assertEq(uint256(vm.load(PROXY, keccak256(abi.encode(address(0), uint256(22))))), OWED_ETH);
    }

    /// Every field getOrder returns, hashed (a tuple cannot be abi.encoded whole).
    function _order(uint256 id) internal view returns (bytes32) {
        (OrderParameters memory p, uint256 counter, bytes32 h, uint256 a, address b) = escrow.getOrder(id);
        return keccak256(abi.encode(p, counter, h, a, b));
    }

    function _quoteFor101(uint256 price) internal returns (address, uint256, address, uint256) {
        // quotePrimaryFees needs a deposited bundle; read the same figures directly.
        (bool ok, bytes memory r) =
            COLLECTION.staticcall(abi.encodeWithSignature("royaltyInfo(uint256,uint256)", 101, price));
        require(ok);
        (address creator, uint256 royalty) = abi.decode(r, (address, uint256));
        bytes32 slot4 = vm.load(PROXY, bytes32(uint256(4)));
        uint256 bps = uint256(slot4) & type(uint96).max;
        address treasury = address(uint160(uint256(slot4) >> 96));
        return (treasury, price * bps / 10_000, creator, royalty);
    }
}
