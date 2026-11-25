// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {NewTradeEscrowV2} from "../../src/NewTradeEscrowV2.sol";
import {Bundle, BundleState, Payout} from "../../src/NewTradeV2Types.sol";
import {ISeaport, OrderParameters, OrderComponents} from "../../src/interfaces/ISeaport.sol";

/**
 * Bundle 1 must survive this upgrade untouched.
 *
 * The check is done the only way that means anything: take the REAL live proxy
 * on a Base fork, upgrade it in memory to the candidate implementation, and
 * compare bundle 1 before and after - its state, its payouts, and above all its
 * recorded Seaport order hash, which is a commitment to every field of the
 * legacy order.
 *
 * This is a fork simulation. Nothing is broadcast and the live proxy is not
 * touched.
 */
contract Bundle1CompatibilityForkTest is Test {
    address constant PROXY = 0x2D2cb241ACf45bDCa0cefF0d8C5Eac7Ff1b4304F;
    address constant SEAPORT = 0x0000000000000068F116a894984e2DB1123eB395;
    /**
     * Bundle 1's CURRENT order hash.
     *
     * Not 0xb389bbce..., which is the pre-repair value recorded in the older
     * upgrade evidence. The seller repair changed the order, so the live record
     * moved. Pinning the stale one here would have quietly asserted the repair
     * never happened; it failed loudly instead, which is why this comment
     * exists.
     */
    bytes32 constant RECORDED_ORDER_HASH = 0xa7b5758e27cb1b075f7a99359b2901669cc6f41ac7b4bfdafe73a1c97ccba3b2;
    bytes32 constant PRE_REPAIR_ORDER_HASH = 0xb389bbcec22f0d60bcfdace9a2ceb871a19f613df6394fa56614c2629ae89a6e;

    bool forked;

    function setUp() public {
        forked = PROXY.code.length > 0;
    }

    function test_Bundle1SurvivesTheUpgradeByteForByte() public {
        if (!forked) return;
        NewTradeEscrowV2 escrow = NewTradeEscrowV2(payable(PROXY));

        // ---- before -------------------------------------------------------
        Bundle memory before_ = escrow.getBundle(1);
        Payout[] memory payoutsBefore = escrow.getPayouts(1);
        (
            OrderParameters memory orderBefore,
            uint256 counterBefore,
            bytes32 hashBefore,
            uint256 chainBefore,
            address protocolBefore
        ) = escrow.getOrder(1);
        assertEq(hashBefore, RECORDED_ORDER_HASH, "the live bundle is not the one this test pins");
        assertTrue(hashBefore != PRE_REPAIR_ORDER_HASH, "the executed seller repair must still be reflected");

        // The legacy order really does hash to its record under live Seaport.
        assertEq(
            ISeaport(SEAPORT).getOrderHash(_components(orderBefore, counterBefore)),
            RECORDED_ORDER_HASH,
            "legacy order must reconstruct to its recorded hash BEFORE the upgrade"
        );

        // ---- upgrade, in memory only --------------------------------------
        NewTradeEscrowV2 candidate = new NewTradeEscrowV2();
        vm.prank(_upgrader(escrow));
        escrow.upgradeToAndCall(address(candidate), "");
        assertEq(
            address(uint160(uint256(vm.load(PROXY, 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc)))),
            address(candidate)
        );

        // ---- after --------------------------------------------------------
        Bundle memory after_ = escrow.getBundle(1);
        assertEq(keccak256(abi.encode(after_)), keccak256(abi.encode(before_)), "bundle record changed");
        assertEq(
            keccak256(abi.encode(escrow.getPayouts(1))),
            keccak256(abi.encode(payoutsBefore)),
            "payouts changed"
        );

        (
            OrderParameters memory orderAfter,
            uint256 counterAfter,
            bytes32 hashAfter,
            uint256 chainAfter,
            address protocolAfter
        ) = escrow.getOrder(1);
        assertEq(hashAfter, RECORDED_ORDER_HASH, "recorded order hash changed");
        assertEq(counterAfter, counterBefore);
        assertEq(chainAfter, chainBefore);
        assertEq(protocolAfter, protocolBefore);

        // The reconstruction is the real test. The new code reads a conduit key
        // and a start time from appended mappings that bundle 1 never wrote, so
        // it must read zero from both and rebuild the identical legacy order.
        assertEq(
            keccak256(abi.encode(orderAfter)),
            keccak256(abi.encode(orderBefore)),
            "reconstructed order parameters changed"
        );
        assertEq(orderAfter.conduitKey, bytes32(0), "bundle 1 must keep its zero conduit key");
        assertEq(orderAfter.startTime, orderBefore.startTime, "bundle 1 must keep its stored start time");
        assertEq(
            ISeaport(SEAPORT).getOrderHash(_components(orderAfter, counterAfter)),
            RECORDED_ORDER_HASH,
            "legacy order must STILL reconstruct to its recorded hash after the upgrade"
        );

        // The appended state is empty for bundle 1, as it must be.
        assertEq(escrow.claimable(before_.seller, before_.paymentToken), 0, "no phantom credit");
        assertEq(escrow.listingSigningDigest(1), _digest(RECORDED_ORDER_HASH), "digest derives from the legacy hash");
        // ...and that digest is NOT signed, because it was never recorded at
        // list() - bundle 1 was listed by the old implementation.
        assertEq(escrow.isValidSignature(escrow.listingSigningDigest(1), ""), bytes4(0xffffffff));
    }

    function _digest(bytes32 orderHash) internal view returns (bytes32) {
        (, bytes32 domainSeparator,) = ISeaport(SEAPORT).information();
        return keccak256(abi.encodePacked(bytes2(0x1901), domainSeparator, orderHash));
    }

    /// The live upgrader, read from prior evidence and then VERIFIED on chain
    /// rather than assumed.
    function _upgrader(NewTradeEscrowV2 escrow) internal view returns (address) {
        address seller = 0xF8e03bd4436371E0e2F7C02E529b2172fe72b4EF;
        assertTrue(escrow.hasRole(escrow.UPGRADER_ROLE(), seller), "pinned upgrader no longer holds the role");
        return seller;
    }

    function _components(OrderParameters memory p, uint256 counter)
        internal
        pure
        returns (OrderComponents memory)
    {
        return OrderComponents(
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
        );
    }
}
