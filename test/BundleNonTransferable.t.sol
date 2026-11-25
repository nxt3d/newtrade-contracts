// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {V2BundleEscrowTest, SecondaryMarketplace} from "./V2BundleEscrow.t.sol";
import {NewTradeEscrowV2} from "../src/NewTradeEscrowV2.sol";
import {NewTradeBundle, IBundleController} from "../src/NewTradeBundle.sol";
import {BundleState} from "../src/NewTradeV2Types.sol";
import {OrderParameters} from "../src/interfaces/ISeaport.sol";
import {SeaportV2Mock} from "./helpers/SeaportV2Mock.sol";
import {CardTestKit} from "./helpers/BundleCardHelpers.sol";

contract NTRefusingValidator {
    function validateTransfer(address, address, address, uint256) external pure {
        revert("REFUSED");
    }
}

contract NTPermissiveValidator {
    function validateTransfer(address, address, address, uint256) external pure {}
}

/**
 * bundle-non-transferable-sep26: a claim moves holder-to-holder exactly once -
 * out of the escrow, to its buyer, at the sale. Every later move reverts
 * NonTransferable, before the transfer validator is asked. Mint, the first
 * exit and the controller's burns are unchanged. (Inherits the escrow harness,
 * so its tests run again under this name.)
 */
contract BundleNonTransferableTest is V2BundleEscrowTest {
    address operator = address(0x0E1);

    function _issued() internal returns (uint256 id, OrderParameters memory p) {
        id = deposit();
        (, p) = list(id);
        SeaportV2Mock(SEAPORT).fill(p, buyer);
    }

    function test_NT_MintIsTheEscrows_AndUnchanged() public {
        uint256 id = deposit();
        assertEq(receipt.ownerOf(id), address(escrow));
        assertFalse(receipt.firstExitNotified(id));
    }

    function test_NT_FirstExitIsAllowed_AndNotifiesTheEscrowExactlyOnce() public {
        uint256 id = deposit();
        (, OrderParameters memory p) = list(id);
        vm.expectCall(address(escrow), abi.encodeWithSelector(IBundleController.onReceiptFirstExit.selector), 1);
        SeaportV2Mock(SEAPORT).fill(p, buyer);
        assertEq(receipt.ownerOf(id), buyer);
        assertTrue(receipt.firstExitNotified(id));
        assertEq(uint8(escrow.getBundle(id).state), uint8(BundleState.Issued));
    }

    function test_NT_HolderTransferFrom_AndBothSafeTransfers_Revert() public {
        (uint256 id,) = _issued();
        vm.startPrank(buyer);
        vm.expectRevert(NewTradeBundle.NonTransferable.selector);
        receipt.transferFrom(buyer, holderB, id);
        vm.expectRevert(NewTradeBundle.NonTransferable.selector);
        receipt.safeTransferFrom(buyer, holderB, id);
        vm.expectRevert(NewTradeBundle.NonTransferable.selector);
        receipt.safeTransferFrom(buyer, holderB, id, "");
        vm.stopPrank();
        assertEq(receipt.ownerOf(id), buyer);
    }

    function test_NT_AnApprovedOperator_AndAnApprovedForAllOperator_CannotMoveIt() public {
        (uint256 id,) = _issued();
        vm.prank(buyer);
        receipt.approve(operator, id);
        vm.prank(operator);
        vm.expectRevert(NewTradeBundle.NonTransferable.selector);
        receipt.transferFrom(buyer, holderB, id);

        vm.prank(buyer);
        receipt.setApprovalForAll(holderC, true);
        vm.prank(holderC);
        vm.expectRevert(NewTradeBundle.NonTransferable.selector);
        receipt.safeTransferFrom(buyer, holderB, id);
        // Approvals may be granted; they cannot execute.
        assertEq(receipt.getApproved(id), operator);
        assertTrue(receipt.isApprovedForAll(buyer, holderC));
        assertEq(receipt.ownerOf(id), buyer);
    }

    function test_NT_ASecondFill_OrAResaleThroughTheConduit_OrAMarketplace_Reverts() public {
        (uint256 id, OrderParameters memory p) = _issued();
        // The sale order again: the token is no longer the escrow's.
        vm.expectRevert();
        SeaportV2Mock(SEAPORT).fill(p, holderB);
        // A resale: the holder approves the OpenSea conduit, which then moves it.
        vm.prank(buyer);
        receipt.approve(CONDUIT, id);
        vm.expectRevert(NewTradeBundle.NonTransferable.selector);
        SeaportV2Mock(SEAPORT).transferReceipt(address(receipt), buyer, holderB, id);
        SecondaryMarketplace market = new SecondaryMarketplace();
        vm.prank(buyer);
        receipt.approve(address(market), id);
        vm.expectRevert(NewTradeBundle.NonTransferable.selector);
        market.transfer(receipt, buyer, holderB, id);
        assertEq(receipt.ownerOf(id), buyer);
    }

    function test_NT_TheControllersBurns_RedeemAndReclaim_StillWork() public {
        (uint256 id,) = _issued();
        vm.prank(buyer);
        escrow.redeemToFreshAccount(id, keccak256("nt-redeem"));
        vm.expectRevert();
        receipt.ownerOf(id);
        assertEq(uint8(escrow.getBundle(id).state), uint8(BundleState.Redeemed));

        setUp();
        uint256 unsold = deposit();
        vm.warp(deadline);
        vm.prank(seller);
        escrow.reclaim(unsold, seller);
        vm.expectRevert();
        receipt.ownerOf(unsold);
    }

    function test_NT_TheValidatorStillGatesTheFirstExit() public {
        uint256 id = deposit();
        (, OrderParameters memory p) = list(id);
        NTRefusingValidator refusing = new NTRefusingValidator();
        vm.prank(address(escrow));
        receipt.setTransferValidator(address(refusing));
        vm.expectRevert(bytes("REFUSED"));
        SeaportV2Mock(SEAPORT).fill(p, buyer);
        assertEq(receipt.ownerOf(id), address(escrow));
    }

    function test_NT_TheRefusalComesBeforeTheValidator_AndNoValidatorReEnablesTransfers() public {
        (uint256 id,) = _issued();
        // A refusing validator is never reached: the error is NonTransferable, not REFUSED.
        NTRefusingValidator refusing = new NTRefusingValidator();
        vm.prank(address(escrow));
        receipt.setTransferValidator(address(refusing));
        vm.prank(buyer);
        vm.expectRevert(NewTradeBundle.NonTransferable.selector);
        receipt.transferFrom(buyer, holderB, id);
        // A validator that allows everything does not re-enable resale either.
        NTPermissiveValidator permissive = new NTPermissiveValidator();
        vm.prank(address(escrow));
        receipt.setTransferValidator(address(permissive));
        vm.prank(buyer);
        vm.expectRevert(NewTradeBundle.NonTransferable.selector);
        receipt.transferFrom(buyer, holderB, id);
        assertEq(receipt.ownerOf(id), buyer);
    }

    function test_NT_TokenURI_SaysSo_OnceAndInValidPosition() public {
        (uint256 id,) = _issued();
        bytes memory json = CardTestKit.jsonOf(receipt.tokenURI(id));
        int256 sentence = CardTestKit.indexOf(json, 'This claim can only be redeemed by its holder; it cannot be transferred or resold.",', 0);
        bytes memory attribute = '{"trait_type":"Transferable","value":"No (redeem only)"}],"properties"';
        int256 attr = CardTestKit.indexOf(json, attribute, 0);
        assertTrue(sentence > 0, "the sentence ends the description");
        assertTrue(attr > sentence, "the attribute is the last one");
        assertEq(CardTestKit.indexOf(json, '"Transferable"', uint256(attr) + attribute.length), -1, "exactly once");
        assertEq(CardTestKit.indexOf(json, '"Transferable"', 0), attr + 14, "and nowhere before it");
        assertEq(CardTestKit.indexOf(json, '"description":"NewTrade Bundle NFT: a redeem-only claim on a vault-held asset bundle.', 0) > 0, true, "the description opens redeem-only");
        assertEq(CardTestKit.indexOf(json, "transferable claim", 0), -1, "and never calls the claim transferable");
    }
}
