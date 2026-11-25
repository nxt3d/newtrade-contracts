// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BundleForkBase} from "./BundleForkBase.sol";
import {CardTestKit} from "../helpers/BundleCardHelpers.sol";

/**
 * HISTORICAL SUITE (bundle-fork-repin-sep27): it describes the world at block 51798787,
 * so every test runs ONLY on a fork at exactly that block (`MODULAR_LIVE_SUITES_BLOCK` in
 * BundleForkBase) and is SKIPPED, with the reason, at any other block - e.g. a
 * `forge test --fork-url …` at the head. The live Bundle (0x9182…, non-transferable)
 * is pinned by BundleNonTransferableLiveFork. Run it as its RUN line says:
 *   --fork-block-number 51798787
 *
 * op2-check-fork-tests-post-modular-sep25: the rollback tests in
 * BundleImageModularLiveForkTest compare the proxy after each rollback step with
 * what Base served at a historical block. Those comparisons only mean something
 * if the three JSONs DIFFER before the rollback: if today's JSON already equalled
 * the block-51,798,717 one, a setExternalBaseURI("") that did nothing would pass.
 * This pins that they differ, and in exactly the expected way.
 *
 * RUN like the live suite (read-only; RPC_8453 from YOUR environment):
 *   forge test --match-contract BundleImageModularLiveForkOp2Test \
 *     --fork-url "$RPC_8453" --fork-block-number 51798787
 */
contract BundleImageModularLiveForkOp2Test is BundleForkBase {
    uint256 constant BEFORE_UPGRADE_BLOCK = 51_798_690; // the card implementation 0x9Cc1
    uint256 constant BEFORE_EXTERNAL_BASE_BLOCK = 51_798_717; // renderer set, no external_url yet

    function _jsonAt(uint256 blockNumber) internal returns (bytes memory json) {
        uint256 here = vm.activeFork();
        vm.selectFork(vm.createFork(vm.envString("RPC_8453"), blockNumber));
        json = CardTestKit.jsonOf(bundle.tokenURI(BUNDLE));
        vm.selectFork(here);
    }

    function _image(bytes memory json) internal pure returns (bytes memory) {
        int256 at = CardTestKit.indexOf(json, '"image":"', 0);
        require(at >= 0, "NO_IMAGE");
        uint256 start = uint256(at) + 9;
        int256 close = CardTestKit.indexOf(json, '",', start);
        require(close >= 0, "UNCLOSED");
        return CardTestKit.slice(json, start, uint256(close));
    }

    function test_TheRollbackTargets_DifferFromTodayAndFromEachOther_InTheExpectedWay() public {
        if (!_atPinnedBlock(MODULAR_LIVE_SUITES_BLOCK)) return;
        assertGt(block.number, 51_798_731, "fork after the last modular-deployment tx");
        bytes memory today = CardTestKit.jsonOf(bundle.tokenURI(BUNDLE));
        bytes memory beforeExternal = _jsonAt(BEFORE_EXTERNAL_BASE_BLOCK);
        bytes memory beforeUpgrade = _jsonAt(BEFORE_UPGRADE_BLOCK);

        // external_url: present today only.
        assertTrue(CardTestKit.contains(today, '"external_url"'), "today: external_url present");
        assertFalse(CardTestKit.contains(beforeExternal, '"external_url"'), "51,798,717: no external_url");
        assertFalse(CardTestKit.contains(beforeUpgrade, '"external_url"'), "51,798,690: no external_url");

        // The image: the renderer's today and at 51,798,717; the built-in card at 51,798,690.
        assertEq(_image(today), _image(beforeExternal), "the renderer's image both today and at 51,798,717");
        assertTrue(keccak256(_image(beforeExternal)) != keccak256(_image(beforeUpgrade)), "the renderer's image differs from the card");

        // Hence all three JSONs differ pairwise: each rollback step has something to undo.
        assertTrue(keccak256(today) != keccak256(beforeExternal), "today != 51,798,717");
        assertTrue(keccak256(beforeExternal) != keccak256(beforeUpgrade), "51,798,717 != 51,798,690");
        assertTrue(keccak256(today) != keccak256(beforeUpgrade), "today != 51,798,690");
    }
}
