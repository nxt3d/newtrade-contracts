// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {NewTradeEscrowV2} from "../../src/NewTradeEscrowV2.sol";
import {NewTradeBundle} from "../../src/NewTradeBundle.sol";
import {Payout, ManifestEntry, BundleState} from "../../src/NewTradeV2Types.sol";
import {ISeaport, Order, OrderParameters} from "../../src/interfaces/ISeaport.sol";
import {FeeForkZoneStub, IStrictRegistryArm} from "./EscrowFeeFromProceedsUpgradeFork.t.sol";
import {CardTestKit} from "../helpers/BundleCardHelpers.sol";

/**
 * bundle-non-transferable-sep26 on the LIVE Base proxies, in a fork only:
 * NewTradeBundle upgraded from the live `0x29Da…19d6` to the non-transferable
 * build (the artifact, via deployCode) as its owner 0xF8e0 (impersonated;
 * nothing is broadcast).
 *
 * Pinned at block 51,839,800: the last block at which bundle #4 is still Issued
 * and held by 0xc3F9…032e (it is redeemed at 51,839,801, found by bisection of
 * `getBundle(4).state`), bundle #3 is Listed, the Bundle proxy runs 0x29Da and
 * the escrow runs the fee-from-proceeds implementation 0xf3D5.
 */
contract BundleNonTransferableUpgradeForkTest is Test {
    uint256 constant FORK_BLOCK = 51_839_800;

    address constant BUNDLE = 0x59900b207ea703B0bBcF8fD84C5E11dE46826185;
    address constant LIVE_IMPL = 0x29DaD81D121CaB79343A191EeB071317858319d6;
    address constant OWNER = 0xF8e03bd4436371E0e2F7C02E529b2172fe72b4EF;
    address constant ESCROW = 0xCc29F5c82C8b7c01Cac6036047E7413Df458f86d;
    address constant SEAPORT = 0x0000000000000068F116a894984e2DB1123eB395;
    address constant VALIDATOR = 0xA000027A9B2802E1ddf7000061001e5c005A0000;
    address constant SIGNED_ZONE = 0x000056F7000000EcE9003ca63978907a00FFD100;
    address constant OPENSEA_CONDUIT = 0x1E0049783F008A0085193E00003D00cd54003c71;
    address constant OPENSEA_FEE = 0x0000a26b00c1F0DF003000390027140000fAa719;
    address constant COLLECTION = 0xf4fd1a2Ea84a16Be24848Aa6f4242E9CAab18953;
    address constant HOLDER_101 = 0xD5c85198CB79443100c661d5bf5D66fa746Eea1d;
    address constant HOLDER_4 = 0xc3F96C409d26272fDB592c0d04e1D771A7df032e;
    address constant SELLER_3 = 0x9a704664009d615A90ddDf9345B6b8B2A214cFb2;
    bytes32 constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    NewTradeBundle bundle = NewTradeBundle(BUNDLE);
    NewTradeEscrowV2 escrow = NewTradeEscrowV2(payable(ESCROW));
    address newImpl;
    bool forked;

    string uri3Before;
    bytes4[6] interfaces = [bytes4(0x01ffc9a7), 0x80ac58cd, 0x5b5e139f, 0x2a55205a, 0xad0d7f6c, 0x49064906];
    bool[6] supportedBefore;

    function setUp() public {
        forked = ESCROW.code.length > 0 && SEAPORT.code.length > 0;
        if (!forked) return;
        vm.rollFork(FORK_BLOCK);
        newImpl = deployCode("NewTradeBundle.sol:NewTradeBundle");
        uri3Before = bundle.tokenURI(3);
        for (uint256 i; i < interfaces.length; ++i) supportedBefore[i] = bundle.supportsInterface(interfaces[i]);
    }

    modifier onlyFork() {
        if (!forked) {
            vm.skip(true);
            return;
        }
        _;
    }

    function _impl() internal view returns (address) {
        return address(uint160(uint256(vm.load(BUNDLE, IMPLEMENTATION_SLOT))));
    }

    function _upgrade() internal {
        vm.prank(OWNER);
        bundle.upgradeToAndCall(newImpl, "");
    }

    /// Arm the strict registry while the SignedZone still has its real code, THEN stub the zone.
    function _armAndStub(uint256 id) internal {
        vm.prank(SIGNED_ZONE);
        IStrictRegistryArm(VALIDATOR).beforeAuthorizedTransfer(BUNDLE, id);
        vm.etch(SIGNED_ZONE, address(new FeeForkZoneStub()).code);
    }

    function _fill(uint256 id, address buyer) internal {
        (OrderParameters memory p,,,,) = escrow.getOrder(id);
        uint256 price = escrow.getBundle(id).price;
        vm.deal(buyer, price);
        vm.prank(buyer);
        assertTrue(ISeaport(SEAPORT).fulfillOrder{value: price}(Order(p, ""), bytes32(0)));
    }

    /// `json` with `insert` placed right before the first `marker` at or after `from`.
    function _insertBefore(bytes memory json, bytes memory marker, bytes memory insert) internal pure returns (bytes memory) {
        int256 at = CardTestKit.indexOf(json, marker, 0);
        require(at >= 0, "MARKER");
        uint256 cut = uint256(at);
        return abi.encodePacked(CardTestKit.slice(json, 0, cut), insert, CardTestKit.slice(json, cut, json.length));
    }

    /// `json` with its ONLY occurrence of `from` replaced by `to` (reverts unless exactly one).
    function _replaceOnce(bytes memory json, bytes memory from, bytes memory to) internal pure returns (bytes memory) {
        int256 at = CardTestKit.indexOf(json, from, 0);
        require(at >= 0, "FROM");
        uint256 cut = uint256(at);
        require(CardTestKit.indexOf(json, from, cut + 1) == -1, "FROM TWICE");
        return abi.encodePacked(CardTestKit.slice(json, 0, cut), to, CardTestKit.slice(json, cut + from.length, json.length));
    }

    function _expectHolderCannotMove(uint256 id, address holder) internal {
        vm.prank(holder);
        vm.expectRevert(NewTradeBundle.NonTransferable.selector);
        bundle.transferFrom(holder, address(0xB0B), id);
        vm.prank(holder);
        vm.expectRevert(NewTradeBundle.NonTransferable.selector);
        bundle.safeTransferFrom(holder, address(0xB0B), id);
        // Through the OpenSea conduit (a marketplace resale), with its approval: refused too.
        vm.prank(holder);
        bundle.approve(OPENSEA_CONDUIT, id);
        vm.prank(OPENSEA_CONDUIT);
        vm.expectRevert(NewTradeBundle.NonTransferable.selector);
        bundle.transferFrom(holder, address(0xB0B), id);
        assertEq(bundle.ownerOf(id), holder);
    }

    // =================================================================== tests

    function test_Preconditions_AtThePinnedBlock() public onlyFork {
        assertEq(block.number, FORK_BLOCK);
        assertEq(_impl(), LIVE_IMPL, "upgrading from the live implementation");
        assertEq(bundle.owner(), OWNER);
        assertEq(bundle.ownerOf(4), HOLDER_4);
        assertEq(uint8(escrow.getBundle(4).state), uint8(BundleState.Issued));
        assertEq(uint8(escrow.getBundle(3).state), uint8(BundleState.Listed));
        assertEq(bundle.ownerOf(3), ESCROW);
    }

    function test_Upgrade_TokenURI3_IsTheSameJson_PlusExactlyTheAttributeTheSentenceAndTheRedeemOnlyPhrase() public onlyFork {
        bytes memory before = CardTestKit.jsonOf(uri3Before);
        _upgrade();
        assertEq(_impl(), newImpl);
        bytes memory expected = _insertBefore(
            _replaceOnce(before, "NewTrade Bundle NFT: a transferable claim on", "NewTrade Bundle NFT: a redeem-only claim on"), '","image":"', " This claim can only be redeemed by its holder; it cannot be transferred or resold."
        );
        expected = _insertBefore(expected, '],"properties"', ',{"trait_type":"Transferable","value":"No (redeem only)"}');
        assertEq(CardTestKit.jsonOf(bundle.tokenURI(3)), expected);
    }

    function test_Upgrade_SupportsInterface_Unchanged() public onlyFork {
        _upgrade();
        for (uint256 i; i < interfaces.length; ++i) {
            assertEq(bundle.supportsInterface(interfaces[i]), supportedBefore[i]);
        }
        assertTrue(supportedBefore[1] && supportedBefore[3], "ERC-721 and ERC-2981 were and are supported");
    }

    function test_Bundle4_TheHolderCannotTransfer_ButCanRedeem() public onlyFork {
        _upgrade();
        _expectHolderCannotMove(4, HOLDER_4);
        vm.prank(HOLDER_4);
        address account = escrow.redeemToFreshAccount(4, keccak256("op2-nt-fork"));
        assertTrue(account != address(0));
        vm.expectRevert();
        bundle.ownerOf(4);
        assertEq(uint8(escrow.getBundle(4).state), uint8(BundleState.Redeemed));
    }

    function test_Bundle3_ARealSeaportFill_StillIssues_ThenItsBuyerCannotResell() public onlyFork {
        _upgrade();
        address buyer = address(0xB0B0B0);
        _armAndStub(3);
        _fill(3, buyer);
        assertEq(bundle.ownerOf(3), buyer);
        assertEq(uint8(escrow.getBundle(3).state), uint8(BundleState.Issued));
        assertTrue(bundle.firstExitNotified(3));
        _expectHolderCannotMove(3, buyer);
    }

    function test_Bundle3_Reclaim_StillBurns() public onlyFork {
        _upgrade();
        vm.warp(escrow.getBundle(3).custodyDeadline);
        vm.prank(SELLER_3);
        escrow.reclaim(3, SELLER_3);
        vm.expectRevert();
        bundle.ownerOf(3);
        assertEq(IERC721(COLLECTION).ownerOf(104), SELLER_3);
    }

    function test_AFreshDepositListAndRealSeaportFill_Issues_TheBuyerCannotResell_AndRedeems() public onlyFork {
        _upgrade();
        uint256 price = 10_000_000_000;
        address vault = escrow.vault();
        uint64 deadline = uint64(block.timestamp + 14 days);
        vm.startPrank(HOLDER_101);
        IERC721(COLLECTION).approve(vault, 101);
        uint256 id = escrow.deposit(COLLECTION, 101, new ManifestEntry[](0), deadline);
        Payout[] memory ps = new Payout[](3);
        ps[0] = Payout(payable(ESCROW), price - 500_000_000 - 100_000_000);
        ps[1] = Payout(payable(OWNER), 500_000_000); // 5 % creator royalty to 0xF8e0 (direct)
        ps[2] = Payout(payable(OPENSEA_FEE), 100_000_000);
        escrow.list(id, address(0), price, deadline, 500, ps);
        vm.stopPrank();
        assertEq(bundle.ownerOf(id), ESCROW);

        address buyer = address(0xB0B0B1);
        _armAndStub(id);
        _fill(id, buyer);
        assertEq(bundle.ownerOf(id), buyer);
        assertEq(uint8(escrow.getBundle(id).state), uint8(BundleState.Issued));
        _expectHolderCannotMove(id, buyer);

        vm.prank(buyer);
        escrow.redeemToFreshAccount(id, keccak256("op2-nt-fresh"));
        vm.expectRevert();
        bundle.ownerOf(id);
    }

    function test_Rollback_ToTheLiveImplementation_RestoresTheJson() public onlyFork {
        _upgrade();
        vm.prank(OWNER);
        bundle.upgradeToAndCall(LIVE_IMPL, "");
        assertEq(_impl(), LIVE_IMPL);
        assertEq(bundle.tokenURI(3), uri3Before);
        // The rolled-back code no longer refuses with NonTransferable (the old
        // validator rules apply again): whatever it says, it is not this error.
        vm.prank(HOLDER_4);
        try bundle.transferFrom(HOLDER_4, address(0xB0B), 4) {} catch (bytes memory err) {
            assertTrue(err.length < 4 || bytes4(err) != NewTradeBundle.NonTransferable.selector);
        }
    }
}
