// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {V2BundleEscrowTest} from "./V2BundleEscrow.t.sol";
import {NewTradeEscrowV2} from "../src/NewTradeEscrowV2.sol";
import {Payout, BundleState, ManifestEntry} from "../src/NewTradeV2Types.sol";
import {OrderParameters} from "../src/interfaces/ISeaport.sol";
import {SeaportV2Mock} from "./helpers/SeaportV2Mock.sol";

/**
 * EIP-1271 on the escrow.
 *
 * The escrow is the offerer and has no private key, so the marketplace API can
 * only establish authorship by asking it. These tests pin down exactly what it
 * will say yes to - one live listing of its own - and, at greater length, every
 * case it must say no to.
 *
 * None of this proves OpenSea's API accepts the result. That is server
 * behaviour and is deliberately left unproven.
 */
contract V2ContractSignatureTest is V2BundleEscrowTest {
    bytes4 constant MAGIC = 0x1626ba7e;
    bytes4 constant BAD = 0xffffffff;

    /// The digest an offchain publisher computes, written out longhand rather
    /// than read from the contract: if the contract's construction ever drifts
    /// from the EIP-712 standard, this is what catches it.
    function expectedDigest(bytes32 orderHash) internal view returns (bytes32) {
        return keccak256(
            abi.encodePacked(bytes2(0x1901), SeaportV2Mock(SEAPORT).domainSeparator(), orderHash)
        );
    }

    function test_DigestIsTheStandardEip712ConstructionOverTheStoredOrderHash() public {
        uint256 id = deposit();
        (bytes32 orderHash,) = list(id);
        bytes32 digest = escrow.listingSigningDigest(id);
        assertEq(digest, expectedDigest(orderHash));
        assertTrue(digest != bytes32(0));
        // It must bind the ORDER HASH, not just any 32 bytes.
        assertTrue(digest != expectedDigest(keccak256("other")));
    }

    function test_LiveListingValidatesForAnySignatureBytesIncludingEmpty() public {
        uint256 id = deposit();
        list(id);
        bytes32 digest = escrow.listingSigningDigest(id);
        // The digest is the authorization; the bytes are not inspected, because
        // what the API sends in the signature field is unproven.
        assertEq(escrow.isValidSignature(digest, ""), MAGIC);
        assertEq(escrow.isValidSignature(digest, hex"00"), MAGIC);
        assertEq(escrow.isValidSignature(digest, new bytes(65)), MAGIC);
    }

    function test_UnlistedAndUnknownDigestsAreNeverApproved() public {
        uint256 id = deposit();
        // Deposited, never listed: there is no digest at all.
        assertEq(escrow.listingSigningDigest(id), bytes32(0));
        assertEq(escrow.isValidSignature(bytes32(0), ""), BAD);
        assertEq(escrow.isValidSignature(keccak256("anything"), ""), BAD);
        // A digest built over a plausible but unlisted order hash.
        assertEq(escrow.isValidSignature(expectedDigest(keccak256("plausible")), ""), BAD);

        list(id);
        // Listing one bundle does not open the door to arbitrary digests.
        assertEq(escrow.isValidSignature(keccak256("anything"), ""), BAD);
        assertEq(escrow.isValidSignature(expectedDigest(keccak256("plausible")), ""), BAD);
    }

    function test_IssuanceRevokesTheSignature() public {
        uint256 id = deposit();
        (, OrderParameters memory p) = list(id);
        bytes32 digest = escrow.listingSigningDigest(id);
        assertEq(escrow.isValidSignature(digest, ""), MAGIC);
        SeaportV2Mock(SEAPORT).fill(p, buyer);
        assertEq(uint8(escrow.getBundle(id).state), uint8(BundleState.Issued));
        assertEq(escrow.isValidSignature(digest, ""), BAD);
    }

    function test_RedemptionRevokesTheSignature() public {
        uint256 id = deposit();
        (, OrderParameters memory p) = list(id);
        bytes32 digest = escrow.listingSigningDigest(id);
        SeaportV2Mock(SEAPORT).fill(p, buyer);
        vm.prank(buyer);
        escrow.redeemToFreshAccount(id, keccak256("s"));
        assertEq(uint8(escrow.getBundle(id).state), uint8(BundleState.Redeemed));
        assertEq(escrow.isValidSignature(digest, ""), BAD);
    }

    function test_ReclaimRevokesTheSignature() public {
        uint256 id = deposit();
        list(id);
        bytes32 digest = escrow.listingSigningDigest(id);
        assertEq(escrow.isValidSignature(digest, ""), MAGIC);
        vm.warp(deadline);
        vm.prank(seller);
        escrow.reclaim(id, seller);
        assertEq(uint8(escrow.getBundle(id).state), uint8(BundleState.Reclaimed));
        assertEq(escrow.isValidSignature(digest, ""), BAD);
    }

    function test_CancellationOnSeaportRevokesTheSignature() public {
        uint256 id = deposit();
        (bytes32 orderHash,) = list(id);
        bytes32 digest = escrow.listingSigningDigest(id);
        SeaportV2Mock(SEAPORT).setCancelled(orderHash, true);
        assertEq(escrow.isValidSignature(digest, ""), BAD);
        SeaportV2Mock(SEAPORT).setCancelled(orderHash, false);
        assertEq(escrow.isValidSignature(digest, ""), MAGIC);
    }

    function test_LosingValidatedStatusOrBecomingFilledRevokesTheSignature() public {
        uint256 id = deposit();
        (bytes32 orderHash,) = list(id);
        bytes32 digest = escrow.listingSigningDigest(id);

        SeaportV2Mock(SEAPORT).setValidated(orderHash, false);
        assertEq(escrow.isValidSignature(digest, ""), BAD);
        SeaportV2Mock(SEAPORT).setValidated(orderHash, true);
        assertEq(escrow.isValidSignature(digest, ""), MAGIC);

        // Seaport and the escrow's own state machine disagreeing is itself a
        // reason to refuse, whichever of them is behind.
        SeaportV2Mock(SEAPORT).setFilled(orderHash, 1);
        assertEq(escrow.isValidSignature(digest, ""), BAD);
    }

    function test_ADifferentDomainSeparatorRevokesTheSignature() public {
        uint256 id = deposit();
        list(id);
        bytes32 digest = escrow.listingSigningDigest(id);
        assertEq(escrow.isValidSignature(digest, ""), MAGIC);

        // A different chain, a different protocol deployment, or a Seaport that
        // changed its domain: the old digest must stop validating, and it must
        // not be silently replaced by a new one for the same order.
        SeaportV2Mock(SEAPORT).setDomainSeparator(keccak256("SOME_OTHER_CHAIN"));
        assertEq(escrow.isValidSignature(digest, ""), BAD);
        // The digest the contract would now advertise is different...
        bytes32 moved = escrow.listingSigningDigest(id);
        assertTrue(moved != digest);
        // ...and is not in the lookup, so it does not validate either. Only a
        // digest recorded at list() under the domain still in force can pass.
        assertEq(escrow.isValidSignature(moved, ""), BAD);
    }

    function test_OneBundlesDigestNeverValidatesAnothersListing() public {
        uint256 first = deposit();
        list(first);
        bytes32 firstDigest = escrow.listingSigningDigest(first);

        control.mint(seller, 2);
        ManifestEntry[] memory none = new ManifestEntry[](0);
        vm.prank(seller);
        uint256 second = escrow.deposit(address(control), 2, none, deadline);
        list(second);
        bytes32 secondDigest = escrow.listingSigningDigest(second);

        assertTrue(firstDigest != secondDigest);
        assertEq(escrow.isValidSignature(firstDigest, ""), MAGIC);
        assertEq(escrow.isValidSignature(secondDigest, ""), MAGIC);

        // Retiring one leaves the other untouched: approval is per bundle, not
        // a global "this contract is currently signing" flag.
        SeaportV2Mock(SEAPORT).setCancelled(escrow.getBundle(first).orderHash, true);
        assertEq(escrow.isValidSignature(firstDigest, ""), BAD);
        assertEq(escrow.isValidSignature(secondDigest, ""), MAGIC);
    }

    /**
     * Two of the guards in isValidSignature survive mutation testing, because
     * other guards independently reject the same cases. The tests below isolate
     * them, so the defence in depth is deliberate rather than accidental: if one
     * layer is later removed, these still fail.
     */
    function test_StateGuardRejectsIndependentlyOfTheSeaportStatusGuard() public {
        uint256 id = deposit();
        (bytes32 orderHash, OrderParameters memory p) = list(id);
        bytes32 digest = escrow.listingSigningDigest(id);
        SeaportV2Mock(SEAPORT).fill(p, buyer);
        // Put Seaport's status back to "validated, uncancelled, unfilled", so
        // the status guard can no longer be what rejects this. The bundle's own
        // state must still be enough.
        SeaportV2Mock(SEAPORT).setFilled(orderHash, 0);
        SeaportV2Mock(SEAPORT).setValidated(orderHash, true);
        assertEq(uint8(escrow.getBundle(id).state), uint8(BundleState.Issued));
        assertEq(escrow.isValidSignature(digest, ""), BAD);
    }

    function test_StateGuardRejectsAReclaimedBundleIndependentlyOfExpiry() public {
        uint256 id = deposit();
        list(id);
        bytes32 digest = escrow.listingSigningDigest(id);
        vm.warp(deadline);
        vm.prank(seller);
        escrow.reclaim(id, seller);
        // Wind the clock back inside the listing window, so the expiry guard can
        // no longer be what rejects this.
        vm.warp(deadline - 1);
        assertEq(uint8(escrow.getBundle(id).state), uint8(BundleState.Reclaimed));
        assertEq(escrow.isValidSignature(digest, ""), BAD);
    }

    /**
     * The zero bundle is why `bundleId == 0` in the lookup is belt-and-braces
     * rather than load-bearing: an unwritten bundle reads state None, which is
     * not Listed, so it could never validate even if the lookup guard went. That
     * only holds while None is the zero value - pin it here, because reordering
     * the enum would silently turn slot zero into a live listing.
     */
    function test_TheZeroValueOfBundleStateIsNotListed() public pure {
        assertTrue(uint8(BundleState.None) == 0);
        assertTrue(uint8(BundleState.Listed) != 0);
    }

    function test_AnExpiredListingIsNoLongerSigned() public {
        uint256 id = deposit();
        list(id);
        bytes32 digest = escrow.listingSigningDigest(id);
        vm.warp(deadline - 1);
        assertEq(escrow.isValidSignature(digest, ""), MAGIC);
        // Exactly at the deadline the order can no longer be filled, so the
        // escrow stops vouching for it even though the bundle is still Listed.
        vm.warp(deadline);
        assertEq(uint8(escrow.getBundle(id).state), uint8(BundleState.Listed));
        assertEq(escrow.isValidSignature(digest, ""), BAD);
    }
}
