// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {NewTradeBundle} from "../src/NewTradeBundle.sol";
import {BundleDeploy} from "./helpers/BundleDeploy.sol";
import {CardTestKit} from "./helpers/BundleCardHelpers.sol";
import {CardController, CardValidator} from "./BundleCard.t.sol";

/**
 * op2 review (op2-review-bundle-svg-upgrade-sep25): `tokenURI` is a view, so
 * its only limit is what a node allows an `eth_call` (commonly 25M-550M gas;
 * Base's public RPC answered bundle #3's in ~340k). This pins the WORST case the
 * card can hit -- the longest bundle id and original token id (both shortened
 * on the card, all 78 digits kept in the metadata) and a checksummed address
 * whose kept characters are letters -- well under the smallest common cap, so a
 * later change that makes the card expensive fails here, not in a wallet.
 */
contract BundleCardGasTest is Test {
    NewTradeBundle bundle;
    CardController controller;

    function setUp() public {
        controller = new CardController();
        bundle = BundleDeploy.deploy(address(this), address(0x5EA), address(new CardValidator()), address(0xB0B));
        bundle.bindController(address(controller));
    }

    function test_WorstCaseTokenUriGas_StaysFarBelowAnEthCallCap() public {
        uint256 id = type(uint256).max;
        controller.set(id, 0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF, type(uint256).max, bytes32(type(uint256).max));
        controller.mint(bundle, id);

        uint256 before = gasleft();
        string memory uri = bundle.tokenURI(id);
        uint256 used = before - gasleft();
        console2.log("worst-case tokenURI gas", used);

        assertLt(used, 2_000_000, "worst-case tokenURI stays far below a 25M eth_call cap");
        // And the card in that worst case is still the small SVG the review measured.
        (, bytes memory b64) = CardTestKit.stripImage(CardTestKit.jsonOf(uri));
        assertLe(CardTestKit.decodeBase64(b64).length, 2048);
    }
}
