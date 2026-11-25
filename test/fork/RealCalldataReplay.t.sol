// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC6551Account} from "../../src/interfaces/IERC6551.sol";
import {INewTradeEscrowV2} from "../../src/INewTradeEscrowV2.sol";
import {NewTradeBundle} from "../../src/NewTradeBundle.sol";
import {AssetKind, Bundle, BundleState, ManifestEntry, Payout} from "../../src/NewTradeV2Types.sol";
import {
    AdvancedOrder,
    CriteriaResolver,
    ISeaport,
    ItemType,
    OrderType,
    OrderComponents,
    OrderParameters
} from "../../src/interfaces/ISeaport.sol";
import {RealCalldataRouteVerifier} from "../helpers/RealCalldataRouteVerifier.sol";

/// @dev Executes the exact call as a Foundry broadcast transaction and proves
/// the nominated signer, rather than the test harness, supplied its native
/// value. This is a fork-test helper; it never submits a live transaction.
abstract contract BroadcastDebitHelper is Test {
    function _broadcastCallWithExactNativeDebit(address signer, address target, uint256 value, bytes memory data)
        internal
        returns (bool ok, bytes memory returnData)
    {
        uint256 harnessNativeBalanceBefore = address(this).balance;
        uint256 signerNativeBalanceBefore = signer.balance;
        vm.broadcast(signer);
        (ok, returnData) = target.call{value: value}(data);
        require(address(this).balance == harnessNativeBalanceBefore, "native value sourced from harness");
        if (ok) {
            require(signer.balance + value == signerNativeBalanceBefore, "native value not debited from signer");
        } else {
            require(signer.balance == signerNativeBalanceBefore, "failed call changed signer balance");
        }
    }
}

/// @notice Replays OpenSea API-produced `fulfillAdvancedOrder` calldata against
/// a Base fork. It deliberately has no SignedZone or transfer-validator mocks.
/// The listing, API authorization, fulfiller funding and approvals must already
/// exist at the selected fork block.
contract RealCalldataReplay is BroadcastDebitHelper {
    uint256 private constant BASE_CHAIN_ID = 8453;
    address private constant BASE_SEAPORT = 0x0000000000000068F116a894984e2DB1123eB395;
    address private constant OPENSEA_SIGNED_ZONE = 0x000056F7000000EcE9003ca63978907a00FFD100;
    address private constant OPENSEA_STRICT_TRANSFER_VALIDATOR = 0xA000027A9B2802E1ddf7000061001e5c005A0000;
    bytes4 private constant FULFILL_ADVANCED_ORDER_SELECTOR = ISeaport.fulfillAdvancedOrder.selector;
    bytes4 private constant ERC6551_VALID_SIGNER = 0x523e3260;
    bytes4 private constant UNAUTHORIZED_SELECTOR = bytes4(keccak256("Unauthorized()"));

    INewTradeEscrowV2 private escrow;
    NewTradeBundle private receipt;
    ISeaport private seaport;
    uint256 private bundleId;
    address private fulfiller;
    address private initialHolder;
    address private finalHolder;
    address private expectedRoyaltyRecipient;
    uint256 private expectedRoyaltyAmount;
    uint256 private callValue;
    bytes private fulfillmentCalldata;
    bytes32 private expectedOrderHash;
    bytes32 private expectedFulfillerConduitKey;
    address private secondaryFulfiller;
    uint256 private secondaryCallValue;
    bytes private secondaryFulfillmentCalldata;
    bytes32 private expectedSecondaryOrderHash;
    bool private replayConfigured;

    function setUp() public {
        replayConfigured = vm.envExists("LIVE_ESCROW");
        if (!replayConfigured) return;

        escrow = INewTradeEscrowV2(vm.envAddress("LIVE_ESCROW"));
        receipt = NewTradeBundle(vm.envAddress("LIVE_RECEIPT"));
        bundleId = vm.envUint("LIVE_BUNDLE_ID");
        fulfiller = vm.envAddress("OPENSEA_FULFILLER");
        initialHolder = vm.envAddress("EXPECTED_INITIAL_HOLDER");
        finalHolder = vm.envAddress("EXPECTED_FINAL_HOLDER");
        expectedRoyaltyRecipient = vm.envAddress("EXPECTED_ROYALTY_RECIPIENT");
        expectedRoyaltyAmount = vm.envUint("EXPECTED_ROYALTY_AMOUNT");
        callValue = vm.envUint("OPENSEA_CALL_VALUE");
        fulfillmentCalldata = vm.envBytes("OPENSEA_CALLDATA");
        expectedOrderHash = vm.envBytes32("OPENSEA_ORDER_HASH");
        expectedFulfillerConduitKey = vm.envBytes32("OPENSEA_FULFILLER_CONDUIT_KEY");
        secondaryFulfiller = vm.envAddress("SECONDARY_FULFILLER");
        secondaryCallValue = vm.envUint("SECONDARY_CALL_VALUE");
        secondaryFulfillmentCalldata = vm.envBytes("SECONDARY_OPENSEA_CALLDATA");
        expectedSecondaryOrderHash = vm.envBytes32("SECONDARY_ORDER_HASH");

        require(block.chainid == BASE_CHAIN_ID, "not Base");
        require(BASE_SEAPORT.code.length != 0, "Seaport not deployed");
        require(OPENSEA_SIGNED_ZONE.code.length != 0, "SignedZone not deployed");
        require(OPENSEA_STRICT_TRANSFER_VALIDATOR.code.length != 0, "validator not deployed");
        require(address(escrow).code.length != 0, "escrow not deployed");
        require(address(receipt).code.length != 0, "receipt not deployed");
        require(fulfiller != address(0) && initialHolder != address(0) && finalHolder != address(0), "zero actor");
        require(expectedRoyaltyRecipient != address(0) && expectedRoyaltyAmount != 0, "zero expected royalty");
        require(fulfillmentCalldata.length > 4, "missing API calldata");
        require(bytes4(fulfillmentCalldata) == FULFILL_ADVANCED_ORDER_SELECTOR, "not fulfillAdvancedOrder");
        require(secondaryFulfiller != address(0) && secondaryFulfiller != initialHolder, "invalid secondary fulfiller");
        require(secondaryFulfillmentCalldata.length > 4, "missing secondary resale calldata");
        require(
            bytes4(secondaryFulfillmentCalldata) == FULFILL_ADVANCED_ORDER_SELECTOR,
            "secondary not fulfillAdvancedOrder"
        );
        require(expectedSecondaryOrderHash != bytes32(0), "missing secondary order hash");
        require(escrow.receipt() == address(receipt), "receipt/escrow mismatch");
        require(receipt.getTransferValidator() == OPENSEA_STRICT_TRANSFER_VALIDATOR, "noncanonical validator");
    }

    function test_ReplayPrimaryPurchaseSecondaryResaleAndFinalHolderRedemption() external {
        vm.skip(!replayConfigured, "missing LIVE_* replay inputs");
        (,,,, address protocol) = escrow.getOrder(bundleId);
        seaport = ISeaport(protocol);
        _assertListingAndApiCalldata();
        _fillAndAssertPayouts();
        _executeAuthorizedSecondaryResale();
        _redeemAndAssertAssets();
    }

    function _assertListingAndApiCalldata() private view {
        (
            OrderParameters memory stored,
            uint256 counter,
            bytes32 storedOrderHash,
            uint256 orderChainId,
            address protocol
        ) = escrow.getOrder(bundleId);
        Bundle memory beforeBundle = escrow.getBundle(bundleId);

        require(orderChainId == BASE_CHAIN_ID, "order not Base");
        require(orderChainId == block.chainid, "order/fork chain mismatch");
        require(protocol == BASE_SEAPORT && protocol == address(seaport), "wrong protocol");
        require(storedOrderHash == expectedOrderHash, "wrong order hash");
        require(beforeBundle.state == BundleState.Listed, "bundle not listed");
        require(initialHolder != beforeBundle.seller, "buyer is original seller");
        require(finalHolder != beforeBundle.seller && finalHolder != initialHolder, "later holder not distinct");
        require(receipt.ownerOf(bundleId) == address(escrow), "receipt already issued");
        require(block.timestamp >= stored.startTime && block.timestamp < stored.endTime, "listing not active");

        (bool validated, bool cancelled, uint256 totalFilled, uint256 totalSize) =
            seaport.getOrderStatus(expectedOrderHash);
        require(validated && !cancelled && totalFilled == 0 && totalSize == 0, "listing unavailable");

        (
            AdvancedOrder memory advanced,
            CriteriaResolver[] memory criteria,
            bytes32 fulfillerConduitKey,
            address apiRecipient
        ) = this.decodeFulfillAdvancedOrder(fulfillmentCalldata);

        require(advanced.numerator == 1 && advanced.denominator == 1, "not exact 1/1 fill");
        require(advanced.signature.length == 0, "escrow order signature not empty");
        require(advanced.parameters.orderType == OrderType.FULL_RESTRICTED, "order not full restricted");
        require(advanced.parameters.zone == OPENSEA_SIGNED_ZONE, "noncanonical SignedZone");
        require(advanced.extraData.length >= 92, "invalid SIP-7 extraData");
        require(criteria.length == 0, "unexpected criteria");
        require(keccak256(abi.encode(advanced.parameters)) == keccak256(abi.encode(stored)), "API order mismatch");
        require(_orderHash(advanced.parameters, counter) == expectedOrderHash, "API hash mismatch");
        require(
            apiRecipient == address(0) ? initialHolder == fulfiller : initialHolder == apiRecipient,
            "initial holder mismatch"
        );

        // Distinguish exact native and canonical Base WETH paths. For WETH,
        // resolve a nonzero conduit key and prove the fulfiller approved the
        // actual transfer target. The unmodified Seaport call remains the
        // definitive execution check.
        RealCalldataRouteVerifier.assertPaymentRoute(
            stored,
            beforeBundle.paymentToken,
            beforeBundle.price,
            callValue,
            fulfiller,
            fulfillerConduitKey,
            expectedFulfillerConduitKey,
            address(seaport)
        );
    }

    function _fillAndAssertPayouts() private {
        Bundle memory listed = escrow.getBundle(bundleId);
        Payout[] memory payouts = escrow.getPayouts(bundleId);
        (address royaltyRecipient, uint256 royaltyAmount) = receipt.royaltyInfo(bundleId, listed.price);
        require(royaltyRecipient == expectedRoyaltyRecipient, "unexpected royalty recipient");
        require(royaltyAmount == expectedRoyaltyAmount, "unexpected royalty amount");
        (uint256 royaltyConsideration, uint256 royaltyItems) = _payoutTo(payouts, royaltyRecipient);
        require(royaltyItems == 1, "royalty payout item not unique");
        if (royaltyRecipient == listed.seller) {
            // The royaltyInfo assertions above prove the component even though
            // the zero-fee beta order pays seller and creator in one transfer.
            (, uint256 protocolAmount,,) = escrow.quotePrimaryFees(bundleId, listed.price);
            require(protocolAmount == 0, "merged beta requires zero protocol fee");
            require(payouts.length == 1 && royaltyConsideration == listed.price, "merged royalty payout mismatch");
        } else {
            require(royaltyConsideration == expectedRoyaltyAmount, "canonical royalty payout mismatch");
        }

        uint256[] memory payoutBalances = new uint256[](payouts.length);
        for (uint256 i; i < payouts.length; ++i) {
            require(payouts[i].recipient != fulfiller, "fulfiller/payout overlap");
            payoutBalances[i] = _paymentBalance(listed.paymentToken, payouts[i].recipient);
        }
        require(listed.paymentToken == address(0) ? callValue == listed.price : callValue == 0, "call value mismatch");
        uint256 fulfillerBalanceBefore = _paymentBalance(listed.paymentToken, fulfiller);
        require(fulfillerBalanceBefore >= listed.price, "fulfiller underfunded");

        _executeFulfillmentAsFulfiller();
        require(
            _paymentBalance(listed.paymentToken, fulfiller) + listed.price == fulfillerBalanceBefore,
            "fulfiller debit mismatch"
        );

        require(receipt.ownerOf(bundleId) == initialHolder, "receipt not delivered to buyer");
        require(escrow.getBundle(bundleId).state == BundleState.Issued, "bundle not issued");
        (bool validated, bool cancelled, uint256 totalFilled, uint256 totalSize) =
            seaport.getOrderStatus(expectedOrderHash);
        require(validated && !cancelled && totalFilled == totalSize && totalSize != 0, "order not filled");

        for (uint256 i; i < payouts.length; ++i) {
            require(
                _paymentBalance(listed.paymentToken, payouts[i].recipient) == payoutBalances[i] + payouts[i].amount,
                "payout delta mismatch"
            );
        }
        require(
            _paymentBalance(listed.paymentToken, royaltyRecipient)
                == payoutBalances[_payoutIndex(payouts, royaltyRecipient)] + royaltyConsideration,
            "royalty not paid"
        );
    }

    function _executeFulfillmentAsFulfiller() private {
        (bool ok, bytes memory returnData) =
            _broadcastCallWithExactNativeDebit(fulfiller, address(seaport), callValue, fulfillmentCalldata);
        if (!ok) _bubble(returnData);
        require(returnData.length >= 32 && abi.decode(returnData, (bool)), "Seaport fill returned false");
    }

    function _executeAuthorizedSecondaryResale() private {
        (AdvancedOrder memory advanced, CriteriaResolver[] memory criteria,, address resaleRecipient) =
            this.decodeFulfillAdvancedOrder(secondaryFulfillmentCalldata);

        require(advanced.parameters.offerer == initialHolder, "secondary offerer not initial holder");
        require(advanced.parameters.orderType == OrderType.FULL_RESTRICTED, "secondary order not restricted");
        require(advanced.parameters.zone == OPENSEA_SIGNED_ZONE, "secondary zone not SignedZone");
        require(advanced.numerator == 1 && advanced.denominator == 1, "secondary not exact 1/1 fill");
        require(advanced.signature.length != 0, "secondary holder signature missing");
        require(advanced.extraData.length >= 92, "secondary SIP-7 authorization missing");
        require(criteria.length == 0, "secondary criteria unsupported");
        require(advanced.parameters.offer.length == 1, "secondary offer not singular");
        require(advanced.parameters.offer[0].itemType == ItemType.ERC721, "secondary offer not ERC721");
        require(advanced.parameters.offer[0].token == address(receipt), "secondary offer not receipt");
        require(advanced.parameters.offer[0].identifierOrCriteria == bundleId, "secondary receipt id mismatch");
        require(
            advanced.parameters.offer[0].startAmount == 1 && advanced.parameters.offer[0].endAmount == 1,
            "secondary receipt amount mismatch"
        );
        _assertPositiveSecondaryConsideration(advanced.parameters);
        require(
            resaleRecipient == address(0) ? finalHolder == secondaryFulfiller : finalHolder == resaleRecipient,
            "secondary recipient mismatch"
        );
        require(
            _orderHash(advanced.parameters, seaport.getCounter(initialHolder)) == expectedSecondaryOrderHash,
            "secondary order hash mismatch"
        );
        require(receipt.ownerOf(bundleId) == initialHolder, "secondary seller not current holder");

        (bool ok, bytes memory returnData) = _broadcastCallWithExactNativeDebit(
            secondaryFulfiller, address(seaport), secondaryCallValue, secondaryFulfillmentCalldata
        );
        if (!ok) _bubble(returnData);
        require(returnData.length >= 32 && abi.decode(returnData, (bool)), "secondary resale returned false");
        require(receipt.ownerOf(bundleId) == finalHolder, "secondary buyer did not receive receipt");

        (bool validated, bool cancelled, uint256 totalFilled, uint256 totalSize) =
            seaport.getOrderStatus(expectedSecondaryOrderHash);
        require(validated && !cancelled && totalFilled == totalSize && totalSize != 0, "secondary order not filled");
    }

    function _assertPositiveSecondaryConsideration(OrderParameters memory parameters) private pure {
        require(parameters.consideration.length != 0, "secondary consideration empty");
        ItemType paymentType = parameters.consideration[0].itemType;
        address paymentToken = parameters.consideration[0].token;
        require(paymentType == ItemType.NATIVE || paymentType == ItemType.ERC20, "secondary payment unsupported");
        uint256 total;
        for (uint256 i; i < parameters.consideration.length; ++i) {
            require(parameters.consideration[i].itemType == paymentType, "secondary mixed payment type");
            require(parameters.consideration[i].token == paymentToken, "secondary mixed payment token");
            require(
                parameters.consideration[i].startAmount == parameters.consideration[i].endAmount,
                "secondary dynamic payment"
            );
            total += parameters.consideration[i].startAmount;
        }
        require(total != 0, "secondary consideration zero");
    }

    function _redeemAndAssertAssets() private {
        Bundle memory listed = escrow.getBundle(bundleId);
        ManifestEntry[] memory manifest = escrow.getManifest(bundleId);
        bytes32 holderSalt = vm.envBytes32("REDEMPTION_HOLDER_SALT");
        (address expectedFresh,) = escrow.computeFreshAccount(bundleId, finalHolder, holderSalt);
        require(expectedFresh.code.length == 0, "fresh account already deployed");
        address vaultAddress = escrow.vault();
        uint256[] memory vaultBefore = new uint256[](manifest.length);
        uint256[] memory freshBefore = new uint256[](manifest.length);
        for (uint256 i; i < manifest.length; ++i) {
            vaultBefore[i] = _assetBalance(manifest[i], vaultAddress);
            freshBefore[i] = _assetBalance(manifest[i], expectedFresh);
            require(vaultBefore[i] >= manifest[i].amount, "vault asset missing");
        }

        address wrongActor = address(uint160(uint256(keccak256(abi.encode(bundleId, finalHolder, "wrong actor")))));
        require(wrongActor != finalHolder && wrongActor != listed.seller, "wrong actor collision");
        vm.expectRevert(UNAUTHORIZED_SELECTOR);
        vm.prank(wrongActor);
        escrow.redeemToFreshAccount(bundleId, holderSalt);

        vm.prank(finalHolder);
        address fresh = escrow.redeemToFreshAccount(bundleId, holderSalt);

        require(fresh == expectedFresh, "fresh account mismatch");
        require(fresh.code.length != 0, "fresh account not created");
        require(escrow.getBundle(bundleId).state == BundleState.Redeemed, "bundle not redeemed");
        require(IERC6551Account(fresh).isValidSigner(finalHolder, "") == ERC6551_VALID_SIGNER, "invalid fresh signer");
        require(IERC721(listed.controllingNFT).ownerOf(listed.controllingTokenId) == finalHolder, "control NFT owner");
        for (uint256 i; i < manifest.length; ++i) {
            require(_assetBalance(manifest[i], fresh) == freshBefore[i] + manifest[i].amount, "fresh asset delta");
            require(
                _assetBalance(manifest[i], vaultAddress) + manifest[i].amount == vaultBefore[i], "vault asset delta"
            );
        }

        try receipt.ownerOf(bundleId) returns (address) {
            revert("receipt not burned");
        } catch {}
    }

    /// @dev External so Solidity can decode the bytes-calldata slice without
    /// copying or hand-parsing the OpenSea transaction arguments.
    function decodeFulfillAdvancedOrder(bytes calldata raw)
        external
        pure
        returns (
            AdvancedOrder memory advanced,
            CriteriaResolver[] memory criteria,
            bytes32 fulfillerConduitKey,
            address recipient
        )
    {
        require(raw.length >= 4 && bytes4(raw[:4]) == FULFILL_ADVANCED_ORDER_SELECTOR, "selector");
        return abi.decode(raw[4:], (AdvancedOrder, CriteriaResolver[], bytes32, address));
    }

    function _orderHash(OrderParameters memory p, uint256 counter) private view returns (bytes32) {
        return seaport.getOrderHash(
            OrderComponents(
                p.offerer,
                p.zone,
                p.offer,
                p.consideration,
                p.orderType,
                p.startTime,
                p.endTime,
                p.zoneHash,
                p.salt,
                p.conduitKey,
                counter
            )
        );
    }

    function _payoutTo(Payout[] memory payouts, address recipient)
        private
        pure
        returns (uint256 amount, uint256 matchingItems)
    {
        for (uint256 i; i < payouts.length; ++i) {
            if (payouts[i].recipient == recipient) {
                amount += payouts[i].amount;
                ++matchingItems;
            }
        }
    }

    function _payoutIndex(Payout[] memory payouts, address recipient) private pure returns (uint256) {
        for (uint256 i; i < payouts.length; ++i) {
            if (payouts[i].recipient == recipient) return i;
        }
        revert("royalty recipient absent");
    }

    function _paymentBalance(address token, address account) private view returns (uint256) {
        return token == address(0) ? account.balance : IERC20(token).balanceOf(account);
    }

    function _assetBalance(ManifestEntry memory entry, address account) private view returns (uint256) {
        if (entry.kind == AssetKind.ERC20) {
            return IERC20(entry.token).balanceOf(account);
        } else if (entry.kind == AssetKind.ERC721) {
            return IERC721(entry.token).ownerOf(entry.tokenId) == account ? 1 : 0;
        } else {
            return IERC1155(entry.token).balanceOf(account, entry.tokenId);
        }
    }

    function _bubble(bytes memory reason) private pure {
        assembly ("memory-safe") {
            revert(add(reason, 0x20), mload(reason))
        }
    }
}

contract NativeValueReceiver {
    address public sender;

    receive() external payable {
        sender = msg.sender;
    }
}

/// @notice Locks in the Foundry mechanism used by the live replay. A prank is
/// insufficient because it changes msg.sender without changing the EVM CALL
/// value source; a broadcast-originated call debits the designated signer.
contract BroadcastValueSourceTest is BroadcastDebitHelper {
    function test_BroadcastDebitHelperDebitsSignerNotHarness() external {
        address signer = address(0xB0B);
        NativeValueReceiver receiver = new NativeValueReceiver();
        vm.deal(signer, 2 ether);
        (bool ok,) = _broadcastCallWithExactNativeDebit(signer, address(receiver), 1 ether, "");

        assertTrue(ok);
        assertEq(receiver.sender(), signer);
        assertEq(signer.balance, 1 ether);
    }
}
