// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {BundleNonTransferableUpgradeForkTest} from "./BundleNonTransferableUpgradeFork.t.sol";
import {BundleState} from "../../src/NewTradeV2Types.sol";
import {CardTestKit} from "../helpers/BundleCardHelpers.sol";
contract DevleadNTReviewTest is BundleNonTransferableUpgradeForkTest {
    function test_Devlead_RedemptionBoundary() public onlyFork {
        assertEq(bundle.ownerOf(4), HOLDER_4);
        assertEq(uint8(escrow.getBundle(4).state), uint8(BundleState.Issued));
        vm.rollFork(FORK_BLOCK + 1);
        assertEq(uint8(escrow.getBundle(4).state), uint8(BundleState.Redeemed));
        vm.expectRevert();
        bundle.ownerOf(4);
    }
    function test_Devlead_MetadataParsesAndAttributeIsExact() public onlyFork {
        _upgrade();
        string memory json = string(CardTestKit.jsonOf(bundle.tokenURI(3)));
        vm.parseJson(json);
        assertEq(vm.parseJsonString(json, ".attributes[5].trait_type"), "Transferable");
        assertEq(vm.parseJsonString(json, ".attributes[5].value"), "No (redeem only)");
        bytes memory needle = bytes('"trait_type":"Transferable"');
        int256 at = CardTestKit.indexOf(bytes(json), needle, 0);
        assertTrue(at >= 0);
        assertEq(CardTestKit.indexOf(bytes(json), needle, uint256(at) + 1), -1);
    }
}
