// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {NewTradeEscrowV2} from "../../src/NewTradeEscrowV2.sol";
import {NewTradeV2VaultV2} from "../../src/NewTradeV2VaultV2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Payout, ManifestEntry, AssetKind, AcceptanceMode, BundleState, RoyaltySnapshot} from "../../src/NewTradeV2Types.sol";
import {ISeaport, Order, OrderParameters} from "../../src/interfaces/ISeaport.sol";
import {IERC6551Registry, ITokenboundAccountProxy} from "../../src/interfaces/IERC6551.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
// Compiled for deployCode("RoyaltyTestNFT.sol:RoyaltyTestNFT"): a filtered `forge test` builds only the import graph.
import {RoyaltyTestNFT} from "../legacy/RoyaltyTestNFT.sol";

interface IStrictRegistryArmB {
    function beforeAuthorizedTransfer(address token, uint256 tokenId) external;
}

interface IRoyaltyTestNFT {
    function mint(address to, uint256 tokenId) external;
    function royaltyInfo(uint256, uint256) external view returns (address, uint256);
}

contract OptionBZoneStub {
    fallback() external {
        assembly ("memory-safe") {
            mstore(0, shl(224, shr(224, calldataload(0))))
            return(0, 32)
        }
    }
}

/**
 * escrow-option-b-sep26: the LIVE Base escrow proxy upgraded, in a fork only,
 * from the fee-from-proceeds implementation 0xf3D5… to option B by its upgrader
 * 0xF8e0 (IMPERSONATED; nothing is broadcast). The final implementation is the
 * build ARTIFACT (deployCode). Pinned at block 51,845,636.
 *
 * The proof sale mirrors the owner's live proof run: a RoyaltyTestNFT paying 2.5 % to 0xc3F9,
 * its 6551 account created through the registry / proxy / logic the escrow's
 * fresh-account policy pins (read from the escrow's storage), USDC seeded into
 * it, depositFromAccount, list as exactly [escrow 0.99P, OpenSea 0.01P], and a
 * REAL Seaport fill (SignedZone stubbed after arming the registry).
 */
contract EscrowOptionBUpgradeForkTest is Test {
    uint256 constant PINNED_FORK_BLOCK = 51_845_636;

    address constant PROXY = 0xCc29F5c82C8b7c01Cac6036047E7413Df458f86d;
    address constant CURRENT_IMPL = 0xf3D5816D4CB14Fa949e476499Cb8A126d37af437;
    address constant ADMIN = 0xF8e03bd4436371E0e2F7C02E529b2172fe72b4EF;
    address constant C3F9 = 0xc3F96C409d26272fDB592c0d04e1D771A7df032e;
    address constant BUNDLE3_SELLER = 0x9a704664009d615A90ddDf9345B6b8B2A214cFb2;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant SEAPORT = 0x0000000000000068F116a894984e2DB1123eB395;
    address constant VALIDATOR = 0xA000027A9B2802E1ddf7000061001e5c005A0000;
    address constant SIGNED_ZONE = 0x000056F7000000EcE9003ca63978907a00FFD100;
    address constant OPENSEA_FEE = 0x0000a26b00c1F0DF003000390027140000fAa719;
    address constant RECEIVER = 0x9182E5b06Bf25A49c0e6Ed04d2A44146d25d4394;
    bytes32 constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    uint256 constant P = 1 ether;
    uint256 constant BUNDLE_3 = 3;
    uint256 constant BUNDLE_3_ESCROW_ITEM = 89_000_000_000;

    NewTradeEscrowV2 escrow = NewTradeEscrowV2(payable(PROXY));
    address finalImpl;
    /// The per-entry vault `_upgrade` switched the escrow to.
    address newVault;
    bool forked;
    address seller = address(0x5E11E0B);
    address buyer = address(0xB0B0B0B);
    address stranger = address(0x5757);

    event CreatorRoyaltySnapshot(uint256 indexed bundleId, address indexed recipient, address indexed token, uint256 amount);
    event CreatorRoyaltyCredited(uint256 indexed bundleId, address indexed recipient, address indexed token, uint256 amount);

    function setUp() public {
        forked = PROXY.code.length > 0 && SEAPORT.code.length > 0;
        if (!forked) return;
        vm.rollFork(PINNED_FORK_BLOCK);
        finalImpl = deployCode("NewTradeEscrowV2.sol:NewTradeEscrowV2");
    }

    modifier onlyFork() {
        if (!forked) {
            vm.skip(true);
            return;
        }
        _;
    }

    // ------------------------------------------------------------------ helpers

    function _impl() internal view returns (address) {
        return address(uint160(uint256(vm.load(PROXY, IMPLEMENTATION_SLOT))));
    }

    /// The upgrade to the current build. Since F-01 (partial release) the escrow's exits go
    /// through `beginRelease` on the per-entry vault, so the ONLY compatible sequence is the
    /// one transaction that also switches the vault: `upgradeToAndCall(impl,
    /// initializeVault(vault))`, followed by the activation of the new vault with the old
    /// vault's policy (Wildcard for the three kinds, deposits from an account enabled).
    /// A bare `upgradeToAndCall(impl, "")` leaves the new code on the old vault; that
    /// incompatible sequence is pinned as a negative in `_upgradeWithoutTheVaultSwitch` and
    /// `test_BareUpgradeWithoutTheVaultSwitch_IsIncompatible`.
    function _upgrade() internal {
        // A SECOND forward hop (after a rollback of the implementation): the vault pointer
        // already names the new vault and initializer version 3 is spent, so the hop is a
        // plain upgrade. Running `initializeVault` again reverts (InvalidInitialization).
        if (newVault != address(0)) {
            vm.prank(ADMIN);
            escrow.upgradeToAndCall(finalImpl, "");
            return;
        }
        AcceptanceMode[3] memory disabled;
        vm.startPrank(ADMIN);
        address vaultImpl = address(new NewTradeV2VaultV2());
        address vault = address(
            new ERC1967Proxy(vaultImpl, abi.encodeCall(NewTradeV2VaultV2.initialize, (PROXY, escrow.receipt(), disabled)))
        );
        escrow.upgradeToAndCall(finalImpl, abi.encodeCall(NewTradeEscrowV2.initializeVault, (vault)));
        for (uint8 k; k < 3; ++k) escrow.setAssetAcceptanceMode(AssetKind(k), AcceptanceMode.Wildcard);
        escrow.setMigrationEnabled(true);
        vm.stopPrank();
        newVault = vault;
    }

    /// NOT a supported sequence: the current implementation with no vault switch.
    function _upgradeWithoutTheVaultSwitch() internal {
        vm.prank(ADMIN);
        escrow.upgradeToAndCall(finalImpl, "");
    }

    function _surplus() internal view returns (uint256) {
        return PROXY.balance - escrow.totalOwed(address(0));
    }

    /// The escrow's pinned fresh-account policy, read from its own storage (slots 8, 9, 12).
    function _policy() internal view returns (address registry, address logic, address accountProxy) {
        registry = address(uint160(uint256(vm.load(PROXY, bytes32(uint256(8))))));
        logic = address(uint160(uint256(vm.load(PROXY, bytes32(uint256(9))))));
        accountProxy = address(uint160(uint256(vm.load(PROXY, bytes32(uint256(12))))));
    }

    function _armAndStub(uint256 id) internal {
        address receipt = escrow.receipt();
        vm.prank(SIGNED_ZONE);
        IStrictRegistryArmB(VALIDATOR).beforeAuthorizedTransfer(receipt, id);
        vm.etch(SIGNED_ZONE, address(new OptionBZoneStub()).code);
    }

    function _fill(uint256 id, uint256 price) internal {
        (OrderParameters memory p,,,,) = escrow.getOrder(id);
        vm.deal(buyer, price);
        vm.prank(buyer);
        assertTrue(ISeaport(SEAPORT).fulfillOrder{value: price}(Order(p, ""), bytes32(0)));
    }

    function _order(uint256 id) internal view returns (bytes32) {
        (OrderParameters memory p, uint256 counter, bytes32 h, uint256 a, address b) = escrow.getOrder(id);
        return keccak256(abi.encode(p, counter, h, a, b));
    }

    /// The owner's proof sale: RoyaltyTestNFT (2.5 % → 0xc3F9), 6551 account, USDC seed, depositFromAccount, list [escrow 0.99P, OpenSea 0.01P].
    function _proofListing() internal returns (uint256 id, address nft, address account) {
        uint64 deadline;
        (id, nft, account, deadline) = _proofDeposit();
        Payout[] memory ps = new Payout[](2);
        ps[0] = Payout(payable(PROXY), 0.99 ether);
        ps[1] = Payout(payable(OPENSEA_FEE), 0.01 ether);
        vm.expectEmit(true, true, true, true, PROXY);
        emit CreatorRoyaltySnapshot(id, C3F9, address(0), 0.025 ether);
        vm.prank(seller);
        escrow.list(id, address(0), P, deadline, 250, ps);
    }

    /// The proof NFT deposited (not listed) through its 6551 account.
    function _proofDeposit() internal returns (uint256 id, address nft, address account, uint64 deadline) {
        return _proofDeposit(keccak256("option-b-proof"));
    }

    function _proofDeposit(bytes32 nonce) internal returns (uint256 id, address nft, address account, uint64 deadline) {
        nft = deployCode("RoyaltyTestNFT.sol:RoyaltyTestNFT", abi.encode(C3F9, uint96(250)));
        IRoyaltyTestNFT(nft).mint(seller, 1);
        (address registry, address logic, address accountProxy) = _policy();
        account = IERC6551Registry(registry).createAccount(accountProxy, bytes32(0), block.chainid, nft, 1);
        ITokenboundAccountProxy(account).initialize(logic);
        deal(USDC, account, 10);
        ManifestEntry[] memory manifest = new ManifestEntry[](1);
        manifest[0] = ManifestEntry(AssetKind.ERC20, USDC, 0, 10);
        deadline = uint64(block.timestamp + 14 days);
        vm.startPrank(seller);
        IERC721(nft).approve(escrow.vault(), 1);
        id = escrow.depositFromAccount(account, nft, 1, manifest, deadline, nonce);
        vm.stopPrank();
    }

    /// verify-escrow-b.sh rollback-check, mirrored: every id 1.._counter (slot 3) whose
    /// getBundle(id).state == Listed AND getRoyaltySnapshot(id).creatorNet != 0.
    function _openBListings() internal view returns (uint256[] memory ids) {
        uint256 n = uint256(vm.load(PROXY, bytes32(uint256(3))));
        uint256[] memory tmp = new uint256[](n);
        uint256 k;
        for (uint256 id = 1; id <= n; ++id) {
            if (escrow.getBundle(id).state == BundleState.Listed && escrow.getRoyaltySnapshot(id).creatorNet != 0) {
                tmp[k++] = id;
            }
        }
        ids = new uint256[](k);
        for (uint256 i; i < k; ++i) ids[i] = tmp[i];
    }

    /// verify-escrow-b.sh pre, mirrored: every Listed id whose snapshot is ROUTED (router != 0).
    function _openRoutedListings() internal view returns (uint256 count) {
        uint256 n = uint256(vm.load(PROXY, bytes32(uint256(3))));
        for (uint256 id = 1; id <= n; ++id) {
            if (escrow.getBundle(id).state == BundleState.Listed && escrow.getRoyaltySnapshot(id).router != address(0)) {
                ++count;
            }
        }
    }

    address constant WETH = 0x4200000000000000000000000000000000000006;

    /// The payment tokens the proxy was initialized with (creation tx 0x698127ea…43b6, block
    /// 51,436,381; no PaymentTokenAllowed event since): every one must be frozen.
    function _paymentTokens() internal pure returns (address[3] memory) {
        return [address(0), WETH, USDC];
    }

    /// Listing admission, on or off, by the admin through the EXISTING setPaymentTokenAllowed.
    function _setListing(bool open) internal {
        address[3] memory t = _paymentTokens();
        for (uint256 i; i < 3; ++i) {
            vm.prank(ADMIN);
            escrow.setPaymentTokenAllowed(t[i], open);
        }
    }

    /// verify-escrow-b.sh `frozen`, mirrored: no payment token is allowed, so list() cannot open anything.
    function _frozen() internal view returns (bool) {
        address[3] memory t = _paymentTokens();
        for (uint256 i; i < 3; ++i) {
            if (escrow.isPaymentTokenAllowed(t[i])) return false;
        }
        return true;
    }

    function _bShape() internal pure returns (Payout[] memory ps) {
        ps = new Payout[](2);
        ps[0] = Payout(payable(PROXY), 0.99 ether);
        ps[1] = Payout(payable(OPENSEA_FEE), 0.01 ether);
    }

    function _routedShape() internal pure returns (Payout[] memory ps) {
        ps = new Payout[](3);
        ps[0] = Payout(payable(PROXY), 0.965 ether);
        ps[1] = Payout(payable(RECEIVER), 0.025 ether);
        ps[2] = Payout(payable(OPENSEA_FEE), 0.01 ether);
    }

    function _rollback() internal {
        vm.prank(ADMIN);
        escrow.upgradeToAndCall(CURRENT_IMPL, "");
        assertEq(_impl(), CURRENT_IMPL);
    }

    // =================================================================== tests

    function test_Preconditions_TheLiveProxyAtThePinnedBlock() public onlyFork {
        assertEq(block.number, PINNED_FORK_BLOCK);
        assertEq(_impl(), CURRENT_IMPL, "rollback target is the live implementation");
        assertTrue(escrow.hasRole(escrow.UPGRADER_ROLE(), ADMIN));
        assertEq(uint8(escrow.getBundle(BUNDLE_3).state), uint8(BundleState.Listed));
        // No listed bundle carries a routed snapshot: option B's first exit reads zeros for #3.
        assertEq(escrow.getRoyaltySnapshot(BUNDLE_3).router, address(0));
        assertEq(escrow.getRoyaltySnapshot(BUNDLE_3).creatorNet, 0);
        assertGe(PROXY.balance, escrow.totalOwed(address(0)), "the ledger is backed before the upgrade");
    }

    function test_Upgrade_LedgerAndBundle3Unchanged_Bundle3FillCreditsItem0() public onlyFork {
        uint256 owedBefore = escrow.totalOwed(address(0));
        uint256 usdcOwedBefore = escrow.totalOwed(USDC);
        bytes32 orderBefore = _order(BUNDLE_3);
        bytes32 bundleBefore = keccak256(abi.encode(escrow.getBundle(BUNDLE_3)));
        bytes32 payoutsBefore = keccak256(abi.encode(escrow.getPayouts(BUNDLE_3)));
        bytes32 snapBefore = keccak256(abi.encode(escrow.getRoyaltySnapshot(BUNDLE_3)));
        uint256 seller3Before = escrow.claimable(BUNDLE3_SELLER, address(0));

        _upgrade();
        assertEq(_impl(), finalImpl);
        assertEq(escrow.totalOwed(address(0)), owedBefore, "totalOwed(ETH) unchanged");
        assertEq(escrow.totalOwed(USDC), usdcOwedBefore);
        assertEq(_order(BUNDLE_3), orderBefore, "getOrder(3) unchanged");
        assertEq(keccak256(abi.encode(escrow.getBundle(BUNDLE_3))), bundleBefore);
        assertEq(keccak256(abi.encode(escrow.getPayouts(BUNDLE_3))), payoutsBefore);
        assertEq(keccak256(abi.encode(escrow.getRoyaltySnapshot(BUNDLE_3))), snapBefore);

        uint256 receiverBefore = RECEIVER.balance;
        uint256 price = escrow.getBundle(BUNDLE_3).price;
        _armAndStub(BUNDLE_3);
        _fill(BUNDLE_3, price);
        assertEq(escrow.claimable(BUNDLE3_SELLER, address(0)), seller3Before + BUNDLE_3_ESCROW_ITEM, "item0 - 0 - 0");
        assertEq(escrow.totalOwed(address(0)), owedBefore + BUNDLE_3_ESCROW_ITEM, "no creator credit for a pre-B bundle");
        assertEq(RECEIVER.balance, receiverBefore, "the receiver is untouched");
    }

    function test_ProofSale_BShape_RealSeaportFill_CreatorAndSellerCredited_WithdrawForByAStranger() public onlyFork {
        _upgrade();
        (uint256 id,,) = _proofListing();
        (OrderParameters memory p,,,,) = escrow.getOrder(id);
        assertEq(p.consideration.length, 2, "exactly [escrow, OpenSea]");
        assertEq(p.consideration[0].recipient, PROXY);
        assertEq(p.consideration[0].startAmount, 0.99 ether);
        assertEq(p.consideration[1].recipient, OPENSEA_FEE);
        assertEq(p.consideration[1].startAmount, 0.01 ether);
        RoyaltySnapshot memory s = escrow.getRoyaltySnapshot(id);
        assertEq(s.creator, C3F9);
        assertEq(s.creatorNet, 0.025 ether);

        uint256 owedBefore = escrow.totalOwed(address(0));
        uint256 surplusBefore = _surplus();
        uint256 receiverBefore = RECEIVER.balance;
        uint256 creatorBefore = escrow.claimable(C3F9, address(0));
        uint256 c3f9Before = C3F9.balance;
        _armAndStub(id);
        vm.expectEmit(true, true, true, true, PROXY);
        emit CreatorRoyaltyCredited(id, C3F9, address(0), 0.025 ether);
        _fill(id, P);
        assertEq(uint8(escrow.getBundle(id).state), uint8(BundleState.Issued));
        assertEq(escrow.claimable(C3F9, address(0)) - creatorBefore, 0.025 ether, "creator 0.025P");
        assertEq(escrow.claimable(seller, address(0)), 0.99 ether - 0.025 ether - 0.05 ether, "seller 0.99P - 0.025P - 0.05P");
        assertEq(_surplus() - surplusBefore, 0.05 ether, "surplus 0.05P");
        assertEq(escrow.totalOwed(address(0)) - owedBefore, 0.94 ether, "totalOwed grows by seller + creator");
        assertEq(C3F9.balance, c3f9Before, "Seaport paid the creator nothing directly");
        assertEq(RECEIVER.balance, receiverBefore, "the receiver is untouched");

        // A stranger pays 0xc3F9 its credit.
        uint256 due = escrow.claimable(C3F9, address(0));
        uint256 strangerBefore = stranger.balance;
        vm.prank(stranger);
        assertEq(escrow.withdrawFor(C3F9, address(0)), due);
        assertEq(C3F9.balance - c3f9Before, due, "paid to 0xc3F9");
        assertEq(stranger.balance, strangerBefore, "never to the caller");
        assertEq(escrow.claimable(C3F9, address(0)), 0);
    }

    function test_Rollback_ToTheLiveImplementation() public onlyFork {
        _upgrade();
        (uint256 id,,) = _proofListing();
        _armAndStub(id);
        _fill(id, P);
        uint256 creatorOwed = escrow.claimable(C3F9, address(0));
        vm.prank(ADMIN);
        escrow.upgradeToAndCall(CURRENT_IMPL, "");
        assertEq(_impl(), CURRENT_IMPL);
        // The ledger is the same storage: both credits stay, and the old code pays them.
        assertEq(escrow.claimable(C3F9, address(0)), creatorOwed);
        vm.prank(seller);
        assertEq(escrow.withdraw(address(0)), 0.915 ether);
        vm.prank(C3F9);
        assertEq(escrow.withdraw(address(0)), creatorOwed);
    }

    // ============================================================ rollback guard
    // escrow-option-b-rollback-fix-sep27 (devlead P1). The hazard itself - a rollback
    // with a B listing open loses the creator's credit - is reproduced in devlead's
    // test/DevleadOptionBReview.t.sol; these pin the guard that prevents it.

    function test_RollbackCheck_RefusesWhileABListingIsOpen_PassesOnceItFills() public onlyFork {
        _upgrade();
        assertEq(_openBListings().length, 0, "bundle #3 (Listed, zero snapshot) is not a B listing");
        (uint256 id,,) = _proofListing();
        uint256[] memory open = _openBListings();
        assertEq(open.length, 1, "rollback-check REFUSES");
        assertEq(open[0], id);

        _armAndStub(id);
        _fill(id, P);
        assertEq(_openBListings().length, 0, "filled: rollback-check passes");
        uint256 creatorOwed = escrow.claimable(C3F9, address(0));
        assertEq(creatorOwed, 0.025 ether);

        _rollback();
        assertEq(_openBListings().length, 0, "verify rollback: nothing slipped in");
        vm.prank(C3F9);
        assertEq(escrow.withdraw(address(0)), creatorOwed, "the old code pays the B credit");
    }

    function test_RollbackCheck_PassesOnceTheOpenBListingIsReclaimed() public onlyFork {
        _upgrade();
        (uint256 id,,) = _proofListing();
        assertEq(_openBListings().length, 1);
        vm.warp(escrow.getBundle(id).custodyDeadline);
        vm.prank(seller);
        escrow.reclaim(id, seller);
        assertEq(uint8(escrow.getBundle(id).state), uint8(BundleState.Reclaimed));
        assertEq(_openBListings().length, 0, "reclaimed: rollback-check passes");
    }

    /// NEGATIVE, kept from the original failure of the test above: the current implementation
    /// WITHOUT the vault switch. The deposit still lands (in the old vault), but the exit
    /// calls `beginRelease` on a vault that has no such function and reverts whole: the
    /// claim is not burned and the bundle stays listed. This sequence is not supported.
    function test_BareUpgradeWithoutTheVaultSwitch_IsIncompatible() public onlyFork {
        _upgradeWithoutTheVaultSwitch();
        assertEq(_impl(), finalImpl);
        (uint256 id,,) = _proofListing();
        vm.warp(escrow.getBundle(id).custodyDeadline);
        vm.prank(seller);
        vm.expectRevert();
        escrow.reclaim(id, seller);
        assertEq(uint8(escrow.getBundle(id).state), uint8(BundleState.Listed), "nothing changed");
        assertEq(IERC721(escrow.receipt()).ownerOf(id), PROXY, "the claim is not burned");
        assertEq(_openBListings().length, 1);
    }

    /// A B listing opened between rollback-check and the rollback: `verify rollback`
    /// still sees it (the old implementation serves the same snapshot), and
    /// re-upgrading FORWARD before it fills settles it correctly.
    function test_ABListingThatSlipsPastTheCheck_IsCaught_AndReupgradingForwardSettlesIt() public onlyFork {
        _upgrade();
        (uint256 id,,) = _proofListing();
        _rollback();
        uint256[] memory open = _openBListings();
        assertEq(open.length, 1, "verify rollback FAILS: the B listing is visible under 0xf3D5");
        assertEq(open[0], id);
        assertEq(_openRoutedListings(), 0, "pre passes: a B snapshot is never routed");

        _upgrade();
        uint256 owedBefore = escrow.totalOwed(address(0));
        _armAndStub(id);
        _fill(id, P);
        assertEq(escrow.claimable(C3F9, address(0)), 0.025 ether, "creator credited");
        assertEq(escrow.claimable(seller, address(0)), 0.915 ether, "seller item0 - royalty - fee");
        assertEq(escrow.totalOwed(address(0)) - owedBefore, 0.94 ether);
    }

    /// The forward hop is NOT unconditional: while rolled back, 0xf3D5 routes new
    /// listings to the receiver (slot 19 still names it). Such a listing carried into
    /// B would be charged twice - the receiver takes the gross royalty item AND B's
    /// first exit credits the creator from item0. `verify-escrow-b.sh pre` (Listed
    /// with router != 0 -> STOP) catches it; this pins both the catch and the harm.
    function test_ForwardHop_ARoutedListingOpenedDuringARollback_IsCaughtByPre() public onlyFork {
        _upgrade();
        _rollback();
        (uint256 id,,, uint64 deadline) = _proofDeposit();
        Payout[] memory ps = new Payout[](3);
        ps[0] = Payout(payable(PROXY), 0.965 ether);
        ps[1] = Payout(payable(RECEIVER), 0.025 ether);
        ps[2] = Payout(payable(OPENSEA_FEE), 0.01 ether);
        vm.prank(seller);
        escrow.list(id, address(0), P, deadline, 250, ps);
        RoyaltySnapshot memory s = escrow.getRoyaltySnapshot(id);
        assertEq(s.router, RECEIVER, "0xf3D5 routed it");
        assertEq(_openRoutedListings(), 1, "pre STOPS the forward hop");
        assertEq(_openBListings().length, 1, "and rollback-check would refuse too (creatorNet != 0)");

        // Forced past the check: the seller pays the creator's royalty twice.
        _upgrade();
        uint256 receiverBefore = RECEIVER.balance;
        _armAndStub(id);
        _fill(id, P);
        assertEq(RECEIVER.balance - receiverBefore, 0.025 ether, "the order paid the receiver the gross royalty");
        assertEq(escrow.claimable(C3F9, address(0)), s.creatorNet, "AND B credited the creator from item0");
        assertEq(escrow.claimable(seller, address(0)), 0.965 ether - s.creatorNet - 0.05 ether, "the seller is short by creatorNet");
    }

    // ================================================== listing quiescence (freeze)
    // escrow-option-b-rollback-quiescence-sep27 (devlead re-look): the off-chain check and
    // the upgrade are not atomic, so listing admission is closed ON CHAIN first with the
    // existing setPaymentTokenAllowed(token, false) for every payment token, in BOTH directions.

    function test_Freeze_ListReverts_CheckPasses_Rollback_StillFrozen_Unfreeze_ListWorksUnderTheOldImplementation()
        public
        onlyFork
    {
        _upgrade();
        (uint256 id,,, uint64 deadline) = _proofDeposit();
        _setListing(false);
        assertTrue(_frozen());
        vm.prank(seller);
        vm.expectRevert(NewTradeEscrowV2.InvalidOrder.selector);
        escrow.list(id, address(0), P, deadline, 250, _bShape());
        assertEq(_openBListings().length, 0, "rollback-check: frozen AND no open B listing");

        _rollback();
        assertTrue(_frozen(), "post-check: still frozen under 0xf3D5");
        assertEq(_openBListings().length, 0, "post-check: no Listed bundle with a creator snapshot");
        vm.prank(seller);
        vm.expectRevert(NewTradeEscrowV2.InvalidOrder.selector);
        escrow.list(id, address(0), P, deadline, 250, _routedShape());

        _setListing(true);
        assertFalse(_frozen());
        vm.prank(seller);
        escrow.list(id, address(0), P, deadline, 250, _routedShape());
        assertEq(uint8(escrow.getBundle(id).state), uint8(BundleState.Listed), "listing works again under 0xf3D5");
        assertEq(escrow.getRoyaltySnapshot(id).router, RECEIVER, "routed, as 0xf3D5 lists");
    }

    /// devlead's race (test_Review_CheckPasses_NewBListing_Rollback_Fill_PostCheckMissesLoss)
    /// with the freeze in place: the listing that would slip in after the check cannot open.
    function test_Freeze_TheRaceCannotBeConstructed() public onlyFork {
        _upgrade();
        (uint256 id,,, uint64 deadline) = _proofDeposit();
        _setListing(false);
        assertTrue(_frozen() && _openBListings().length == 0, "rollback-check permits");
        // The racing seller, after the check and before the rollback lands:
        vm.prank(seller);
        vm.expectRevert(NewTradeEscrowV2.InvalidOrder.selector);
        escrow.list(id, address(0), P, deadline, 250, _bShape());
        _rollback();
        assertEq(uint8(escrow.getBundle(id).state), uint8(BundleState.Deposited), "nothing listed: nothing to fill");
        assertTrue(_frozen() && _openBListings().length == 0, "post-check holds");
    }

    /// The freeze blocks only list(): an open B listing still fills under option B and its
    /// creator is credited, after which the check passes.
    function test_Freeze_AnOpenBListingStillFillsUnderB_AndIsCredited() public onlyFork {
        _upgrade();
        (uint256 id,,) = _proofListing();
        _setListing(false);
        assertEq(_openBListings().length, 1, "rollback-check REFUSES: frozen, but a B listing is open");
        _armAndStub(id);
        _fill(id, P);
        assertEq(escrow.claimable(C3F9, address(0)), 0.025 ether, "creator credited while frozen");
        assertEq(escrow.claimable(seller, address(0)), 0.915 ether);
        assertTrue(_frozen() && _openBListings().length == 0, "rollback-check permits now");
    }

    /// The forward hop (the first upgrade AND any re-application): 0xf3D5 routes new
    /// listings (slot 19 names the receiver), and a routed listing carried into B is charged
    /// twice. Frozen before `pre`, none can open between `pre` and the upgrade.
    function test_ForwardHop_Frozen_NoRoutedListingCanOpenBetweenPreAndTheUpgrade() public onlyFork {
        (uint256 id,,, uint64 deadline) = _proofDeposit();
        _setListing(false);
        assertEq(_openRoutedListings(), 0, "pre: no routed listing");
        vm.prank(seller);
        vm.expectRevert(NewTradeEscrowV2.InvalidOrder.selector);
        escrow.list(id, address(0), P, deadline, 250, _routedShape());
        _upgrade();
        assertEq(_openRoutedListings(), 0);
        _setListing(true);
        vm.prank(seller);
        escrow.list(id, address(0), P, deadline, 250, _bShape());
        assertEq(escrow.getRoyaltySnapshot(id).creatorNet, 0.025 ether, "a B listing under B after the unfreeze");
    }
}
