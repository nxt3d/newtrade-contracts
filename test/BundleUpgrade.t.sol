// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {V2BundleEscrowTest} from "./V2BundleEscrow.t.sol";
import {NewTradeBundle} from "../src/NewTradeBundle.sol";
import {BundleDeploy} from "./helpers/BundleDeploy.sol";
import {SeaportV2Mock} from "./helpers/SeaportV2Mock.sol";
import {OrderParameters} from "../src/interfaces/ISeaport.sol";
import {ManifestEntry} from "../src/NewTradeV2Types.sol";
import {ICreatorToken} from "../src/interfaces/ICreatorToken.sol";
import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

/// A plausible next receipt version: one appended storage variable, one
/// reinitializer, one new view. Nothing existing moves.
contract NewTradeBundleV2Mock is NewTradeBundle {
    string public releaseNote; // appended AFTER firstExitNotified (slot 5)

    function initializeV2(string calldata note) external reinitializer(2) {
        releaseNote = note;
    }

    function version() external pure returns (uint256) {
        return 2;
    }
}

/// An implementation that does NOT swap the storage layout but is not UUPS:
/// the proxy must refuse it (ERC-1822 proxiableUUID check).
contract NotUUPS {
    function owner() external pure returns (address) {
        return address(0xDEAD);
    }
}

/// An implementation whose `proxiableUUID` names the wrong slot.
contract WrongUUID {
    function proxiableUUID() external pure returns (bytes32) {
        return keccak256("not the erc1967 implementation slot");
    }
}

/**
 * The receipt collection behind its UUPS proxy.
 *
 * Inherits the escrow fixture so every upgrade claim is checked against a
 * receipt that is actually wired into an escrow with live bundles - not a
 * bare token in isolation.
 */
contract ReceiptUpgradeTest is V2BundleEscrowTest {
    event Upgraded(address indexed implementation);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    bytes32 constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 constant INITIALIZABLE_SLOT = 0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;
    bytes32 constant OWNABLE_SLOT = 0x9016d09d72d40fdae2fd8ceac6b6234c7706214fd39c1cd1e609a0528c199300;
    bytes32 constant OWNABLE2STEP_SLOT = 0x237e158222e3e6968b72b9db0d8043aacf074ad9f650f0d1606b4d82ee432c00;
    bytes32 constant ERC721_SLOT = 0x80bb2b638cc20bc4d0a60d66940f3ab4a00c1d7b313497ca82fb0b4ab0079300;

    address stranger = address(0x5713);

    function _implementation() internal view returns (address) {
        return address(uint160(uint256(vm.load(address(receipt), IMPLEMENTATION_SLOT))));
    }

    function _asAddress(bytes32 word) internal pure returns (address) {
        return address(uint160(uint256(word)));
    }

    // ---------------------------------------------------- initialization

    function test_ImplementationInitializersAreDisabledAndItCannotBeUpgradedDirectly() public {
        NewTradeBundle impl = NewTradeBundle(_implementation());
        assertEq(impl.owner(), address(0), "the implementation is nobody's");
        assertEq(impl.controller(), address(0));
        // Disabled forever: nobody can initialize the implementation and become
        // its owner, so nothing can later be pointed at a hijacked one.
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(address(this), SEAPORT, SEAPORT, stranger);
        // And the implementation refuses upgrade calls made to itself.
        address next = address(new NewTradeBundleV2Mock());
        vm.expectRevert(UUPSUpgradeable.UUPSUnauthorizedCallContext.selector);
        impl.upgradeToAndCall(next, "");
    }

    function test_InitializerCannotBeFrontRunOrRepeatedOnTheProxy() public {
        // The proxy is initialized in the same transaction that creates it:
        // the owner and validator exist from the very first block.
        NewTradeBundle fresh = BundleDeploy.deploy(address(this), SEAPORT, SEAPORT, receiptOwner);
        assertEq(fresh.owner(), receiptOwner);
        assertEq(fresh.getTransferValidator(), SEAPORT);
        // A second initialize - from anyone, including the owner - is refused.
        vm.prank(stranger);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        fresh.initialize(stranger, SEAPORT, SEAPORT, stranger);
        vm.prank(receiptOwner);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        fresh.initialize(address(this), SEAPORT, SEAPORT, receiptOwner);
        // Nor can initialize be smuggled through the upgrade data path.
        NewTradeBundle impl = new NewTradeBundle();
        vm.prank(receiptOwner);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        fresh.upgradeToAndCall(
            address(impl), abi.encodeCall(NewTradeBundle.initialize, (stranger, SEAPORT, SEAPORT, stranger))
        );
        assertEq(fresh.owner(), receiptOwner, "owner survived every attempt");
    }

    /// A proxy created with empty init data would be claimable by whoever
    /// called initialize first. The OpenZeppelin 5.6 ERC1967Proxy refuses to
    /// be created that way at all, so the front-running window cannot even be
    /// opened by a careless deployment; DeployV2 initializes in the constructor.
    function test_AProxyCannotBeCreatedUninitializedSoThereIsNoFrontRunningWindow() public {
        NewTradeBundle impl = new NewTradeBundle();
        vm.expectRevert(ERC1967Proxy.ERC1967ProxyUninitialized.selector);
        new ERC1967Proxy(address(impl), "");
        // The helper (and DeployV2) initialize atomically; a late caller finds
        // the door already closed.
        NewTradeBundle safe = BundleDeploy.deploy(address(this), SEAPORT, SEAPORT, receiptOwner);
        vm.prank(stranger);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        safe.initialize(stranger, SEAPORT, SEAPORT, stranger);
    }

    function test_InitializeRejectsZeroBootstrapSeaportOwnerAndCodelessValidator() public {
        NewTradeBundle impl = new NewTradeBundle();
        bytes memory zeroBootstrap = abi.encodeCall(NewTradeBundle.initialize, (address(0), SEAPORT, SEAPORT, receiptOwner));
        vm.expectRevert(NewTradeBundle.ControllerOnly.selector);
        new ERC1967Proxy(address(impl), zeroBootstrap);
        bytes memory zeroSeaport = abi.encodeCall(NewTradeBundle.initialize, (address(this), address(0), SEAPORT, receiptOwner));
        vm.expectRevert(NewTradeBundle.ControllerOnly.selector);
        new ERC1967Proxy(address(impl), zeroSeaport);
        bytes memory eoaValidator = abi.encodeCall(NewTradeBundle.initialize, (address(this), SEAPORT, stranger, receiptOwner));
        vm.expectRevert(NewTradeBundle.ControllerOnly.selector);
        new ERC1967Proxy(address(impl), eoaValidator);
        bytes memory zeroOwner = abi.encodeCall(NewTradeBundle.initialize, (address(this), SEAPORT, SEAPORT, address(0)));
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableInvalidOwner.selector, address(0)));
        new ERC1967Proxy(address(impl), zeroOwner);
    }

    // ------------------------------------------------- upgrade authority

    function test_OnlyTheOwnerCanUpgrade() public {
        address next = address(new NewTradeBundleV2Mock());
        address before = _implementation();
        address escrowAdmin = address(this); // holds the escrow's DEFAULT_ADMIN_ROLE and UPGRADER_ROLE

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, stranger));
        receipt.upgradeToAndCall(next, "");

        // The escrow (controller) mints and burns but has no upgrade authority...
        vm.prank(address(escrow));
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, address(escrow)));
        receipt.upgradeToAndCall(next, "");

        // ...and neither does the escrow's administrator / upgrader: receipt
        // upgrade authority and escrow fee administration are separate keys.
        assertTrue(escrow.hasRole(escrow.DEFAULT_ADMIN_ROLE(), escrowAdmin));
        assertTrue(escrow.hasRole(escrow.UPGRADER_ROLE(), escrowAdmin));
        vm.prank(escrowAdmin);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, escrowAdmin));
        receipt.upgradeToAndCall(next, "");

        // A pending owner is not an owner yet.
        vm.prank(receiptOwner);
        receipt.transferOwnership(holderB);
        vm.prank(holderB);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, holderB));
        receipt.upgradeToAndCall(next, "");

        assertEq(_implementation(), before, "implementation untouched by every refused attempt");
    }

    function test_OwnerUpgradesAndTheNewImplementationIsLiveWithOptionalReinitializer() public {
        NewTradeBundleV2Mock next = new NewTradeBundleV2Mock();
        vm.expectEmit(true, true, true, true, address(receipt));
        emit Upgraded(address(next));
        vm.prank(receiptOwner);
        receipt.upgradeToAndCall(address(next), abi.encodeCall(NewTradeBundleV2Mock.initializeV2, ("v2")));
        assertEq(_implementation(), address(next));
        NewTradeBundleV2Mock upgraded = NewTradeBundleV2Mock(address(receipt));
        assertEq(upgraded.version(), 2);
        assertEq(upgraded.releaseNote(), "v2");
        // The reinitializer is single-use too.
        vm.prank(receiptOwner);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        upgraded.initializeV2("again");
        // Owner and upgrade authority are unchanged by the upgrade itself.
        assertEq(upgraded.owner(), receiptOwner);
        address another = address(new NewTradeBundleV2Mock());
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, stranger));
        upgraded.upgradeToAndCall(another, "");
    }

    function test_UpgradeRefusesNonUUPSAndWrongUUIDImplementations() public {
        address before = _implementation();
        address notUups = address(new NotUUPS());
        vm.prank(receiptOwner);
        vm.expectRevert(abi.encodeWithSelector(ERC1967Utils.ERC1967InvalidImplementation.selector, notUups));
        receipt.upgradeToAndCall(notUups, "");

        WrongUUID wrong = new WrongUUID();
        bytes32 wrongSlot = wrong.proxiableUUID();
        vm.prank(receiptOwner);
        vm.expectRevert(abi.encodeWithSelector(UUPSUpgradeable.UUPSUnsupportedProxiableUUID.selector, wrongSlot));
        receipt.upgradeToAndCall(address(wrong), "");

        // An account without code: the proxiableUUID probe cannot even be
        // made (Solidity's extcodesize guard reverts without data).
        vm.prank(receiptOwner);
        vm.expectRevert();
        receipt.upgradeToAndCall(stranger, "");
        assertEq(_implementation(), before, "every refused candidate left the implementation alone");
    }

    // --------------------------------------------------- ownership transfer

    function test_OwnershipTransferIsTwoStepAndMovesUpgradeAuthorityWithIt() public {
        vm.expectEmit(true, true, true, true, address(receipt));
        emit OwnershipTransferStarted(receiptOwner, holderB);
        vm.prank(receiptOwner);
        receipt.transferOwnership(holderB);
        assertEq(receipt.owner(), receiptOwner);
        assertEq(receipt.pendingOwner(), holderB);

        // The owner can still upgrade until the transfer is accepted; the
        // pending owner cannot, and a stranger cannot accept.
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, stranger));
        receipt.acceptOwnership();

        vm.expectEmit(true, true, true, true, address(receipt));
        emit OwnershipTransferred(receiptOwner, holderB);
        vm.prank(holderB);
        receipt.acceptOwnership();
        assertEq(receipt.owner(), holderB);
        assertEq(receipt.pendingOwner(), address(0));

        // Authority followed the ownership: the old owner is now just a stranger.
        address next = address(new NewTradeBundleV2Mock());
        vm.prank(receiptOwner);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, receiptOwner));
        receipt.upgradeToAndCall(next, "");
        vm.prank(receiptOwner);
        vm.expectRevert(NewTradeBundle.ControllerOnly.selector);
        receipt.setTransferValidator(SEAPORT);
        vm.prank(holderB);
        receipt.upgradeToAndCall(next, "");
        assertEq(_implementation(), next);

        // Still not renounceable after the hand-over.
        vm.prank(holderB);
        vm.expectRevert(NewTradeBundle.OwnershipNotRenounceable.selector);
        receipt.renounceOwnership();
    }

    // ------------------------------------------ storage layout and state

    /// Pins the receipt's own sequential slots and the OpenZeppelin ERC-7201
    /// namespaces it depends on. If any of these move, an upgrade would read
    /// garbage; `forge inspect NewTradeBundle storage-layout` is the companion
    /// artifact and must show the same order.
    function test_StorageLayoutIsPinned() public {
        uint256 id = deposit();
        (, OrderParameters memory p) = list(id);
        SeaportV2Mock(SEAPORT).fill(p, buyer);
        vm.prank(receiptOwner);
        receipt.transferOwnership(holderB);

        // Own storage, slots 0..4, in declaration order.
        assertEq(_asAddress(vm.load(address(receipt), bytes32(uint256(0)))), address(escrow), "slot 0 controller");
        assertEq(_asAddress(vm.load(address(receipt), bytes32(uint256(1)))), address(this), "slot 1 bootstrap");
        assertEq(_asAddress(vm.load(address(receipt), bytes32(uint256(2)))), SEAPORT, "slot 2 seaport");
        assertEq(_asAddress(vm.load(address(receipt), bytes32(uint256(3)))), SEAPORT, "slot 3 validator");
        bytes32 notifiedSlot = keccak256(abi.encode(id, uint256(4)));
        assertEq(uint256(vm.load(address(receipt), notifiedSlot)), 1, "slot 4 firstExitNotified mapping");
        assertEq(uint256(vm.load(address(receipt), bytes32(uint256(5)))), 0, "slot 5 free for the next version");

        // OpenZeppelin namespaces.
        assertEq(_asAddress(vm.load(address(receipt), OWNABLE_SLOT)), receiptOwner, "Ownable owner");
        assertEq(_asAddress(vm.load(address(receipt), OWNABLE2STEP_SLOT)), holderB, "Ownable2Step pending owner");
        assertEq(uint64(uint256(vm.load(address(receipt), INITIALIZABLE_SLOT))), 1, "Initializable version 1");
        // ERC721Storage._owners is the third member of the namespace.
        bytes32 ownersSlot = keccak256(abi.encode(id, uint256(ERC721_SLOT) + 2));
        assertEq(_asAddress(vm.load(address(receipt), ownersSlot)), buyer, "ERC721 _owners");
        assertEq(_implementation().code.length > 0, true);
    }

    function test_UpgradePreservesEveryPieceOfStateAndTheEscrowFlowKeepsWorking() public {
        // Build up real state: one issued receipt, one still in custody, an
        // approval, a pending owner, and a rotated validator.
        uint256 issued = deposit();
        (, OrderParameters memory p) = list(issued);
        SeaportV2Mock(SEAPORT).fill(p, buyer);
        control.mint(seller, 2);
        extra721.mint(seller, 8);
        erc20.mint(seller, 20 ether);
        erc1155.mint(seller, 3, 4);
        ManifestEntry[] memory es = manifest();
        es[1].tokenId = 8;
        vm.prank(seller);
        uint256 custody = escrow.deposit(address(control), 2, es, deadline);
        vm.prank(buyer);
        receipt.approve(CONDUIT, issued);
        vm.prank(receiptOwner);
        receipt.transferOwnership(holderB);
        SeaportV2Mock rotated = new SeaportV2Mock();
        vm.prank(address(escrow));
        receipt.setTransferValidator(address(rotated));

        string memory uriBefore = receipt.tokenURI(issued);
        (address royaltyToBefore, uint256 royaltyAmountBefore) = receipt.royaltyInfo(issued, PRICE);
        (bytes4 fnBefore,) = receipt.getTransferValidationFunction();

        NewTradeBundleV2Mock next = new NewTradeBundleV2Mock();
        vm.prank(receiptOwner);
        receipt.upgradeToAndCall(address(next), "");

        // Identity and interfaces.
        assertEq(receipt.name(), "NewTrade Bundle V2");
        assertEq(receipt.symbol(), "NTB2");
        assertTrue(receipt.supportsInterface(type(IERC721).interfaceId));
        assertTrue(receipt.supportsInterface(type(IERC2981).interfaceId));
        assertTrue(receipt.supportsInterface(type(ICreatorToken).interfaceId));
        assertTrue(receipt.supportsInterface(0x7f5828d0));
        // Ownership and wiring.
        assertEq(receipt.owner(), receiptOwner);
        assertEq(receipt.pendingOwner(), holderB);
        assertEq(receipt.controller(), address(escrow));
        assertEq(receipt.bootstrap(), address(this));
        assertEq(receipt.seaport(), SEAPORT);
        assertEq(receipt.getTransferValidator(), address(rotated));
        (bytes4 fnAfter,) = receipt.getTransferValidationFunction();
        assertEq(fnAfter, fnBefore);
        // Token state.
        assertEq(receipt.ownerOf(issued), buyer);
        assertEq(receipt.ownerOf(custody), address(escrow));
        assertEq(receipt.getApproved(issued), CONDUIT);
        assertEq(receipt.balanceOf(buyer), 1);
        assertTrue(receipt.firstExitNotified(issued));
        assertFalse(receipt.firstExitNotified(custody));
        assertEq(receipt.tokenURI(issued), uriBefore);
        (address royaltyToAfter, uint256 royaltyAmountAfter) = receipt.royaltyInfo(issued, PRICE);
        assertEq(royaltyToAfter, royaltyToBefore);
        assertEq(royaltyAmountAfter, royaltyAmountBefore);

        // The whole escrow flow still runs through the upgraded receipt: the
        // custody receipt lists and sells (first-exit callback intact), the
        // issued one does NOT change hands (non-transferable after its first
        // sale, bundle-non-transferable-sep26, even under a rotated validator),
        // and a burn remains controller-only.
        (, OrderParameters memory p2) = list(custody);
        SeaportV2Mock(SEAPORT).fill(p2, holderC);
        assertEq(receipt.ownerOf(custody), holderC);
        assertTrue(receipt.firstExitNotified(custody));
        vm.expectRevert(NewTradeBundle.NonTransferable.selector);
        SeaportV2Mock(address(rotated)).transferReceipt(address(receipt), buyer, holderB, issued);
        assertEq(receipt.ownerOf(issued), buyer);
        vm.prank(receiptOwner);
        vm.expectRevert(NewTradeBundle.ControllerOnly.selector);
        receipt.controllerBurn(issued);
        vm.prank(stranger);
        vm.expectRevert(NewTradeBundle.ControllerOnly.selector);
        receipt.controllerMint(777);
        // Pending owner can still complete the hand-over afterwards.
        vm.prank(holderB);
        receipt.acceptOwnership();
        assertEq(receipt.owner(), holderB);
    }
}
