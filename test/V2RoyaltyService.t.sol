// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {V2BundleEscrowTest} from "./V2BundleEscrow.t.sol";
import {NewTradeEscrowV2} from "../src/NewTradeEscrowV2.sol";
import {NewTradeBundle} from "../src/NewTradeBundle.sol";
import {NewTradeRoyaltyReceiver} from "./legacy/NewTradeRoyaltyReceiver.sol";
import {Payout, BundleState, RoyaltySnapshot, ManifestEntry, AssetKind} from "../src/NewTradeV2Types.sol";
import {ICreatorToken} from "../src/interfaces/ICreatorToken.sol";
import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {OwnableUpgradeable as Ownable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {BundleDeploy} from "./helpers/BundleDeploy.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {OrderParameters} from "../src/interfaces/ISeaport.sol";
import {SeaportV2Mock} from "./helpers/SeaportV2Mock.sol";

/// A validator that refuses every holder-to-holder transfer. Used to prove a
/// validator rotation REDIRECTS enforcement rather than disabling it.
contract RefusingValidator {
    function validateTransfer(address, address, address, uint256) external pure {
        revert("REFUSED");
    }
}

/// A creator wallet that tries to re-enter `withdraw` while being paid.
/**
 * Receipt ownership / validator tests and the ROYALTY HARNESS for the escrow
 * suites. OPTION B (escrow-option-b-sep26) retired routing: every routed test
 * that lived here is gone with the code it tested (setRoyaltyRouter,
 * setRoyaltyServiceFeeBps, quoteRoyaltyService, the receiver credit). The
 * option B royalty behaviour is tested in test/V2OptionB.t.sol. The receiver
 * contract stays deployed and dormant, so its own lockdown test stays.
 */
contract V2RoyaltyServiceTest is V2BundleEscrowTest {
    event TransferValidatorUpdated(address oldValidator, address newValidator);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    address creator = address(0xCAFE);
    uint256 constant ROYALTY = 0.1 ether; // 10 % of PRICE
    uint256 constant PROTOCOL_FEE = 0.025 ether; // 250 bps of PRICE
    uint256 constant SELLER_NET = 0.875 ether;

    NewTradeRoyaltyReceiver router;

    function setUp() public virtual override {
        super.setUp();
        router = new NewTradeRoyaltyReceiver(address(this));
        router.bindController(address(escrow));
        erc20.mint(buyer, 100 ether);
        vm.prank(buyer);
        erc20.approve(SEAPORT, type(uint256).max);
    }

    // ---------------------------------------------------------------- helpers

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

    // ------------------------------------------------- receipt ownership (A)

    function test_ReceiptOwnerIsConfigurableDiscoverableAndAnnouncesInitialValidator() public {
        vm.expectEmit(true, true, true, true);
        emit OwnershipTransferred(address(0), receiptOwner);
        vm.expectEmit(true, true, true, true);
        emit TransferValidatorUpdated(address(0), SEAPORT);
        NewTradeBundle fresh = BundleDeploy.deploy(address(this), SEAPORT, SEAPORT, receiptOwner);
        assertEq(fresh.owner(), receiptOwner);
        assertEq(fresh.pendingOwner(), address(0));
        assertEq(fresh.getTransferValidator(), SEAPORT);
        // ERC-173, ICreatorToken and ERC-2981 are all discoverable.
        assertTrue(fresh.supportsInterface(0x7f5828d0));
        assertTrue(fresh.supportsInterface(type(ICreatorToken).interfaceId));
        assertTrue(fresh.supportsInterface(type(IERC2981).interfaceId));
        // Never hardcoded, never zero: the proxy cannot even be created.
        NewTradeBundle impl = new NewTradeBundle();
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new ERC1967Proxy(
            address(impl), abi.encodeCall(NewTradeBundle.initialize, (address(this), SEAPORT, SEAPORT, address(0)))
        );
    }

    function test_ReceiptOwnershipIsTwoStepAndNotRenounceable() public {
        assertEq(receipt.owner(), receiptOwner);
        vm.prank(receiptOwner);
        receipt.transferOwnership(holderB);
        // Nothing moves until the pending owner accepts.
        assertEq(receipt.owner(), receiptOwner);
        assertEq(receipt.pendingOwner(), holderB);
        vm.prank(holderC);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, holderC));
        receipt.acceptOwnership();
        vm.prank(holderB);
        receipt.acceptOwnership();
        assertEq(receipt.owner(), holderB);
        assertEq(receipt.pendingOwner(), address(0));
        vm.prank(holderB);
        vm.expectRevert(NewTradeBundle.OwnershipNotRenounceable.selector);
        receipt.renounceOwnership();
        vm.prank(holderC);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, holderC));
        receipt.transferOwnership(holderC);
    }

    function test_OwnerHasNoMintBurnApproveOrControllerPower() public {
        uint256 id = deposit();
        vm.startPrank(receiptOwner);
        vm.expectRevert(NewTradeBundle.ControllerOnly.selector);
        receipt.controllerMint(99);
        vm.expectRevert(NewTradeBundle.ControllerOnly.selector);
        receipt.controllerBurn(id);
        vm.expectRevert(NewTradeBundle.ControllerOnly.selector);
        receipt.controllerApproveSeaport(id);
        vm.expectRevert(NewTradeBundle.ControllerOnly.selector);
        receipt.bindController(receiptOwner);
        // Owner is not a holder either: a plain transfer of escrow custody fails.
        vm.expectRevert();
        receipt.transferFrom(address(escrow), receiptOwner, id);
        vm.stopPrank();
        assertEq(receipt.ownerOf(id), address(escrow));
        assertEq(receipt.controller(), address(escrow));
    }

    /// RE-ANCHORED (bundle-non-transferable-sep26): the first exit - the escrow
    /// giving the claim to its buyer - is now the ONLY move the validator is
    /// asked about, so rotation is pinned on it. And no validator, however
    /// permissive, re-enables a resale: that refusal runs before it is asked.
    function test_ValidatorRotationByOwnerOrControllerRedirectsButNeverDisablesEnforcement() public {
        uint256 id = deposit();
        (, OrderParameters memory p) = list(id);

        // Strangers, zero and code-less targets are all refused.
        vm.prank(holderC);
        vm.expectRevert(NewTradeBundle.ControllerOnly.selector);
        receipt.setTransferValidator(SEAPORT);
        vm.prank(receiptOwner);
        vm.expectRevert(NewTradeBundle.ControllerOnly.selector);
        receipt.setTransferValidator(address(0));
        vm.prank(receiptOwner);
        vm.expectRevert(NewTradeBundle.ControllerOnly.selector);
        receipt.setTransferValidator(address(0xBEEF));

        // The owner rotates to a refusing validator: every rotation is public and
        // the new validator is consulted immediately - the first exit is blocked.
        RefusingValidator refusing = new RefusingValidator();
        vm.expectEmit(true, true, true, true);
        emit TransferValidatorUpdated(SEAPORT, address(refusing));
        vm.prank(receiptOwner);
        receipt.setTransferValidator(address(refusing));
        assertEq(receipt.getTransferValidator(), address(refusing));
        vm.expectRevert(bytes("REFUSED"));
        SeaportV2Mock(SEAPORT).fill(p, buyer);
        assertEq(receipt.ownerOf(id), address(escrow));

        // The controller may rotate back; the first exit then goes through.
        vm.expectEmit(true, true, true, true);
        emit TransferValidatorUpdated(address(refusing), SEAPORT);
        vm.prank(address(escrow));
        receipt.setTransferValidator(SEAPORT);
        SeaportV2Mock(SEAPORT).fill(p, buyer);
        assertEq(receipt.ownerOf(id), buyer);

        // A permissive validator never re-enables a resale.
        authorizedTransferExpectingNonTransferable(buyer, holderB, id);
        assertEq(receipt.ownerOf(id), buyer);
    }

    function authorizedTransferExpectingNonTransferable(address from, address to, uint256 id) internal {
        vm.prank(from);
        receipt.approve(CONDUIT, id);
        vm.expectRevert(NewTradeBundle.NonTransferable.selector);
        SeaportV2Mock(SEAPORT).transferReceipt(address(receipt), from, to, id);
    }

    // ------------------------------------------------ fee policy (B, admin)

    function test_ReceiverBindingAndReceiveAreLockedDown() public {
        NewTradeRoyaltyReceiver fresh = new NewTradeRoyaltyReceiver(address(this));
        vm.prank(holderB);
        vm.expectRevert(NewTradeRoyaltyReceiver.ControllerOnly.selector);
        fresh.bindController(address(escrow));
        vm.expectRevert(NewTradeRoyaltyReceiver.ControllerOnly.selector);
        fresh.bindController(address(0xBEEF)); // no code
        fresh.bindController(address(escrow));
        vm.expectRevert(NewTradeRoyaltyReceiver.ControllerOnly.selector);
        fresh.bindController(address(escrow)); // once
        vm.expectRevert(NewTradeRoyaltyReceiver.ZeroAddress.selector);
        new NewTradeRoyaltyReceiver(address(0));

        // Only Seaport may push native value; only the controller may credit.
        vm.deal(holderB, 1 ether);
        vm.prank(holderB);
        (bool ok,) = address(router).call{value: 1 ether}("");
        assertFalse(ok);
        vm.prank(holderB);
        vm.expectRevert(NewTradeRoyaltyReceiver.ControllerOnly.selector);
        router.credit(1, address(0), holderB, 1 ether, treasury, 0);
        vm.expectRevert(NewTradeRoyaltyReceiver.NothingToWithdraw.selector);
        router.withdraw(address(0));
    }

    function manifestFor(uint256 extraId) internal view returns (ManifestEntry[] memory es) {
        es = new ManifestEntry[](3);
        es[0] = ManifestEntry(AssetKind.ERC20, address(erc20), 0, 20 ether);
        es[1] = ManifestEntry(AssetKind.ERC721, address(extra721), extraId, 1);
        es[2] = ManifestEntry(AssetKind.ERC1155, address(erc1155), 3, 4);
    }
}
