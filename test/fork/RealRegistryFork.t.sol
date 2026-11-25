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
import {ISeaport, Order, OrderParameters} from "../../src/interfaces/ISeaport.sol";
import {MockERC20, MockERC721} from "../mocks/TokenMocks.sol";
import {Mock6551Registry, Mock6551Implementation} from "../helpers/ERC6551Mocks.sol";

interface IStrictRegistry {
    function createList(string memory name) external returns (uint120);
    function applyListToCollection(address collection, uint120 id) external;
    function beforeAuthorizedTransfer(address token, uint256 tokenId) external;
    function beforeAuthorizedTransfer(address operator, address token) external;
    function afterAuthorizedTransfer(address token, uint256 tokenId) external;
    function validateTransfer(address caller, address from, address to, uint256 tokenId) external view;
    function getAuthorizerAccountsByCollection(address collection) external view returns (address[] memory);
    function getWhitelistedAccountsByCollection(address collection) external view returns (address[] memory);
}

/// Stands in for the SignedZone. It returns the selector Seaport asks for and
/// does NOT verify SIP-7 extraData, because no local test can produce a
/// server-signed one.
contract ForkAuthorizingZoneStub {
    fallback() external {
        assembly ("memory-safe") {
            mstore(0, shl(224, shr(224, calldataload(0))))
            return(0, 32)
        }
    }
}

/**
 * The REAL StrictAuthorizedTransferSecurityRegistry on Base, exercised through
 * its ACTUAL authorization model.
 *
 * ================== WHAT IS REAL AND WHAT IS IMPERSONATED ==================
 *
 * REAL, at pinned block 51408900:
 *   - the registry            0xA000027A9B2802E1ddf7000061001e5c005A0000
 *   - Seaport 1.6             0x0000000000000068F116a894984e2DB1123eB395
 *   - the OpenSea conduit     0x1E0049783F008A0085193E00003D00cd54003c71
 *   - the collection's resolved policy, authorizer set and whitelist
 *
 * IMPERSONATED, and this distinction is the whole point:
 *   - the SignedZone's AUTHORIZER CALL. These tests reach the armed state with
 *     `vm.prank(SIGNED_ZONE)` and a direct `beforeAuthorizedTransfer`. That
 *     proves the REGISTRY admits the transfer once armed. It proves NOTHING
 *     about whether OpenSea's server will issue the SIP-7 substandard-8
 *     extraData that would make the real zone arm it. Server issuance remains
 *     unproven and untestable locally.
 *   - the order's zone is a local stub, not the real SignedZone, for the same
 *     reason: real `authorizeOrder` requires server-signed extraData.
 *
 * So: "the registry will allow this" is proven here. "OpenSea will authorize
 * this" is not, and must never be read out of these passes.
 *
 * ---------------------------------------------------------------------------
 * CORRECTION. An earlier commit (e227ae4) concluded from the unarmed denial
 * that the receipt could never be sold and could not be fixed. That conclusion
 * was WRONG and is withdrawn. The observations in it were right; the
 * authorization model was simply never exercised. Two mistakes produced it:
 * the arming path was not tried, and the probe called `validateTransfer`
 * directly from the test contract. That function takes no token argument - the
 * collection IS `msg.sender` - so the registry was being asked about the test
 * contract, not the receipt. Both are fixed here and pinned by tests.
 */
contract RealRegistryForkTest is Test {
    address constant REGISTRY = 0xA000027A9B2802E1ddf7000061001e5c005A0000;
    address constant SIGNED_ZONE = 0x000056F7000000EcE9003ca63978907a00FFD100;
    address constant CONDUIT = 0x1E0049783F008A0085193E00003D00cd54003c71;
    address constant SEAPORT = 0x0000000000000068F116a894984e2DB1123eB395;
    address constant NOT_AN_AUTHORIZER = address(0xBADBAD);

    address seller = address(0xA11CE);
    address buyer = address(0xB0B);
    address treasury = address(0xFEE);
    address marketFee = address(0x0FEE5EA);
    uint256 constant PRICE = 1 ether;

    NewTradeEscrowV2 escrow;
    NewTradeBundle receipt;
    NewTradeV2VaultV2 vault;
    MockERC721 nft;
    uint64 deadline;
    bool forked;

    function setUp() public {
        forked = REGISTRY.code.length > 0 && SEAPORT.code.length > 0;
        if (!forked) return;
        nft = new MockERC721();
        address[] memory pays = new address[](2);
        pays[0] = address(0);
        pays[1] = address(new MockERC20("Pay", "PAY", 18));
        address[] memory assets = new address[](1);
        assets[0] = address(nft);
        AssetKind[] memory kinds = new AssetKind[](1);
        kinds[0] = AssetKind.ERC721;
        AcceptanceMode[3] memory modes = [AcceptanceMode.Allowlist, AcceptanceMode.Allowlist, AcceptanceMode.Allowlist];
        Mock6551Registry registry6551 = new Mock6551Registry();
        Mock6551Implementation implementation = new Mock6551Implementation();
        ForkAuthorizingZoneStub zone = new ForkAuthorizingZoneStub();

        // The REAL registry is the receipt's transfer validator here.
        receipt = BundleDeploy.deploy(address(this), SEAPORT, REGISTRY, address(this));
        NewTradeV2Vault legacyVault = new NewTradeV2Vault(address(this), address(receipt), assets, kinds, modes);
        V2Initialization memory c = V2Initialization(
            address(this), treasury, 250, pays, assets, kinds, modes,
            address(registry6551), address(implementation), address(implementation),
            address(receipt), address(legacyVault), REGISTRY, address(zone), address(0)
        );
        NewTradeEscrowV2 impl = new NewTradeEscrowV2();
        escrow = NewTradeEscrowV2(
            payable(address(new ERC1967Proxy(address(impl), abi.encodeCall(NewTradeEscrowV2.initialize, (c)))))
        );
        receipt.bindController(address(escrow));
        legacyVault.bindController(address(escrow));
        vault = VaultV2Deploy.switchEscrowMirroring(escrow, address(receipt), assets, kinds, modes);
        deadline = uint64(block.timestamp + 1 days);
    }

    // ------------------------------------------------------------ the policy

    /// The collection is NOT unconfigured-and-abandoned: it resolves to the
    /// registry's default list, whose authorizer is the SignedZone. Nothing
    /// needs configuring, which is why the earlier "can never be configured"
    /// conclusion did not follow from the observation.
    function test_TheCollectionResolvesToADefaultPolicyAuthorizedByTheSignedZone() public view {
        if (!forked) return;
        address[] memory authorizers = IStrictRegistry(REGISTRY).getAuthorizerAccountsByCollection(address(receipt));
        assertEq(authorizers.length, 1, "expected exactly one authorizer");
        assertEq(authorizers[0], SIGNED_ZONE, "the authorizer must be the SignedZone");
        // The conduit is deliberately NOT on the static whitelist: admission is
        // per fill, via the authorizer, not by standing permission.
        assertFalse(_whitelisted(CONDUIT));
    }

    /// Unarmed, the registry denies the conduit. This part of e227ae4 was right
    /// and is kept.
    function test_UnarmedTheRegistryDeniesTheConduit() public {
        if (!forked) return;
        vm.expectRevert(bytes4(0x1de5204e));
        this.validateAsCollection(CONDUIT, address(escrow), buyer, 1);
    }

    /// Substandard 7 arms an (operator, token) pair and does NOT unlock the
    /// tokenId variant this receipt advertises. Substandard 8 does.
    function test_Substandard7IsInsufficientAndSubstandard8IsWhatUnlocksIt() public {
        if (!forked) return;
        (bytes4 fn,) = receipt.getTransferValidationFunction();
        assertEq(fn, bytes4(0xcaee23ea), "the receipt advertises the tokenId validation variant");

        vm.prank(SIGNED_ZONE);
        IStrictRegistry(REGISTRY).beforeAuthorizedTransfer(CONDUIT, address(receipt)); // substandard 7
        vm.expectRevert(bytes4(0x1de5204e));
        this.validateAsCollection(CONDUIT, address(escrow), buyer, 1);

        vm.prank(SIGNED_ZONE);
        IStrictRegistry(REGISTRY).beforeAuthorizedTransfer(address(receipt), 1); // substandard 8
        this.validateAsCollection(CONDUIT, address(escrow), buyer, 1);
        // Once armed the operator no longer matters - Seaport itself passes too.
        this.validateAsCollection(SEAPORT, address(escrow), buyer, 1);
    }

    function test_OnlyTheAuthorizerCanArmItAndAfterTransferClearsIt() public {
        if (!forked) return;
        vm.prank(NOT_AN_AUTHORIZER);
        vm.expectRevert();
        IStrictRegistry(REGISTRY).beforeAuthorizedTransfer(address(receipt), 1);

        vm.prank(SIGNED_ZONE);
        IStrictRegistry(REGISTRY).beforeAuthorizedTransfer(address(receipt), 1);
        this.validateAsCollection(CONDUIT, address(escrow), buyer, 1);

        vm.prank(SIGNED_ZONE);
        IStrictRegistry(REGISTRY).afterAuthorizedTransfer(address(receipt), 1);
        vm.expectRevert(bytes4(0x1de5204e));
        this.validateAsCollection(CONDUIT, address(escrow), buyer, 1);
    }

    /// `applyListToCollection` failing for a non-owner is expected and
    /// irrelevant: nothing needs configuring. Kept so the observation stays on
    /// the record without the wrong conclusion attached to it.
    ///
    /// Since the receipt gained ERC-173 `owner()`, the REAL registry now also
    /// recognises the owner as a collection admin. That is the discoverable
    /// ownership OpenSea's tooling looks for - and it is a real capability, so
    /// the second half pins what applying a list actually does: it REPLACES
    /// the default policy (SignedZone authorizer) with the owner's list. A
    /// deployment must therefore never apply a list unless it re-adds the
    /// SignedZone as authorizer, or sales stop arming.
    function test_ApplyListFailsForANonOwnerWhichIsExpectedAndHarmless() public {
        if (!forked) return;
        uint120 id = IStrictRegistry(REGISTRY).createList("newtrade-probe");
        vm.prank(NOT_AN_AUTHORIZER);
        vm.expectRevert(bytes4(0x05b33364));
        IStrictRegistry(REGISTRY).applyListToCollection(address(receipt), id);
        // ...and the sale path is unaffected by that failure, because it does
        // not depend on a collection-owned list at all.
        vm.prank(SIGNED_ZONE);
        IStrictRegistry(REGISTRY).beforeAuthorizedTransfer(address(receipt), 1);
        this.validateAsCollection(CONDUIT, address(escrow), buyer, 1);
        vm.prank(SIGNED_ZONE);
        IStrictRegistry(REGISTRY).afterAuthorizedTransfer(address(receipt), 1);

        // The owner, by contrast, is admitted by the real registry through
        // `owner()` alone - no registration, no verification, no OpenSea step.
        assertEq(receipt.owner(), address(this));
        assertGt(IStrictRegistry(REGISTRY).getAuthorizerAccountsByCollection(address(receipt)).length, 0);
        IStrictRegistry(REGISTRY).applyListToCollection(address(receipt), id);
        assertEq(
            IStrictRegistry(REGISTRY).getAuthorizerAccountsByCollection(address(receipt)).length,
            0,
            "an owner-applied empty list drops the SignedZone authorizer"
        );
        vm.prank(SIGNED_ZONE);
        vm.expectRevert();
        IStrictRegistry(REGISTRY).beforeAuthorizedTransfer(address(receipt), 1);
    }

    // ------------------------------------------- the whole sale, end to end

    /**
     * Zone-armed substandard-8 first exit, through REAL Seaport and the REAL
     * conduit, against the REAL registry, with the pull-payment credit and the
     * seller's withdrawal asserted.
     *
     * The arming is impersonated (see the contract header). Everything the
     * arming unlocks is real.
     */
    function test_ZoneArmedFirstExitThroughRealSeaportCreditsAndPaysTheSeller() public {
        if (!forked) return;
        uint256 id = _deposit();
        OrderParameters memory p = _list(id);

        // Unarmed, the real fill fails at the registry.
        vm.deal(buyer, PRICE);
        vm.prank(buyer);
        vm.expectRevert();
        ISeaport(SEAPORT).fulfillOrder{value: PRICE}(Order(p, ""), bytes32(0));
        assertEq(receipt.ownerOf(id), address(escrow), "nothing may move while unarmed");
        assertEq(uint8(escrow.getBundle(id).state), uint8(BundleState.Listed));

        // Arm exactly as the SignedZone would, then fulfil for real.
        vm.prank(SIGNED_ZONE);
        IStrictRegistry(REGISTRY).beforeAuthorizedTransfer(address(receipt), id);

        uint256 marketFeeBefore = marketFee.balance;
        vm.prank(buyer);
        assertTrue(ISeaport(SEAPORT).fulfillOrder{value: PRICE}(Order(p, ""), bytes32(0)));

        // The receipt moved, through the real conduit, past the real registry.
        assertEq(receipt.ownerOf(id), buyer);
        assertTrue(receipt.firstExitNotified(id), "the first-exit callback must have run");
        assertEq(uint8(escrow.getBundle(id).state), uint8(BundleState.Issued));
        assertEq(escrow.getBundle(id).firstRecipient, buyer);

        // Consideration settled: the market fee direct, the seller by credit of
        // item0 - the frozen protocol fee, which stays in the escrow as surplus.
        assertEq(marketFee.balance - marketFeeBefore, 0.01 ether);
        assertEq(address(escrow).balance, 0.99 ether);
        assertEq(escrow.claimable(seller, address(0)), 0.965 ether);

        uint256 sellerBefore = seller.balance;
        vm.prank(seller);
        assertEq(escrow.withdraw(address(0)), 0.965 ether);
        assertEq(seller.balance - sellerBefore, 0.965 ether);
        assertEq(address(escrow).balance, 0.025 ether, "the fee stays as surplus");
        assertEq(escrow.claimable(seller, address(0)), 0);
    }

    // ------------------------------------------------------------- helpers

    /// `validateTransfer` takes no token argument: the collection IS
    /// `msg.sender`. It must therefore be called AS the receipt, which is what
    /// the token contract does. Calling it straight from the test asks the
    /// registry about the TEST CONTRACT, which is the mistake that produced
    /// e227ae4's wrong conclusion.
    function validateAsCollection(address caller, address from, address to, uint256 id) external {
        vm.prank(address(receipt));
        IStrictRegistry(REGISTRY).validateTransfer(caller, from, to, id);
    }

    function _whitelisted(address account) internal view returns (bool) {
        address[] memory list = IStrictRegistry(REGISTRY).getWhitelistedAccountsByCollection(address(receipt));
        for (uint256 i; i < list.length; ++i) {
            if (list[i] == account) return true;
        }
        return false;
    }

    function _deposit() internal returns (uint256 id) {
        nft.mint(seller, 1);
        vm.startPrank(seller);
        nft.approve(address(vault), 1);
        id = escrow.deposit(address(nft), 1, new ManifestEntry[](0), deadline);
        vm.stopPrank();
    }

    function _list(uint256 id) internal returns (OrderParameters memory p) {
        Payout[] memory ps = new Payout[](2);
        // escrow-fee-from-proceeds-sep25: no protocol-fee item. The escrow item
        // carries the 0.025 fee (deducted at first exit); a marketplace fee is the
        // second recipient (bundle #2's shape).
        ps[0] = Payout(payable(address(escrow)), 0.99 ether);
        ps[1] = Payout(payable(marketFee), 0.01 ether);
        vm.prank(seller);
        escrow.list(id, address(0), PRICE, deadline, 0, ps);
        (p,,,,) = escrow.getOrder(id);
    }
}
