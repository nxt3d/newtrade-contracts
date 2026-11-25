// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {NewTradeV2VaultV2} from "../src/NewTradeV2VaultV2.sol";
import {AcceptanceMode, AssetKind, ManifestEntry, ReleaseMode} from "../src/NewTradeV2Types.sol";
import {ToggleReleaseFailureERC1155} from "./helpers/ERC6551Mocks.sol";
import {VaultV2Deploy} from "./helpers/VaultV2Deploy.sol";
import {CodeStub, GasProbe, ProbeERC20, ProbeERC721} from "./VaultGasProbe.t.sol";

/// @notice F-01: pins each branch of the vault's gas rule separately, through the proxy,
/// with the test contract as controller. The gas figures sit inside the windows measured
/// in GAS-PROBE.md (proxy and preamble cost 7.4k warm, 23k cold before the rule runs), so
/// they hold both warm and under --isolate.
contract VaultGasGuardEdgesTest is Test {
    uint256 constant ENOUGH = 5_000_000;
    /// In batch mode with an ERC-20 first this leaves 203,175 <= a < 240,000: the
    /// 63/64 inequality holds and the reserve inequality does not.
    uint256 constant RESERVE_WINDOW = 250_000;
    /// Below the batch budget: a < 200,000.
    uint256 constant BELOW_BUDGET = 100_000;
    /// In single mode this leaves a <= GAS_RESERVE.
    uint256 constant BELOW_SINGLE_RESERVE = 50_000;

    NewTradeV2VaultV2 vault;
    ProbeERC20 p20;
    ProbeERC721 p721;
    ProbeERC721 control;
    ToggleReleaseFailureERC1155 filler;
    address seller = makeAddr("seller");
    address extrasTo = makeAddr("extrasTo");
    uint256 nextBundle = 1;
    bytes lastReturn;

    function setUp() public {
        AcceptanceMode[3] memory wild = [AcceptanceMode.Wildcard, AcceptanceMode.Wildcard, AcceptanceMode.Wildcard];
        vault = VaultV2Deploy.deployProxy(address(this), address(new CodeStub()), wild);
        p20 = new ProbeERC20();
        p721 = new ProbeERC721();
        control = new ProbeERC721();
        filler = new ToggleReleaseFailureERC1155();
        p20.mint(seller, 100 ether);
        filler.mint(seller, 1, 100);
        vm.startPrank(seller);
        p20.approve(address(vault), type(uint256).max);
        p721.setApprovalForAll(address(vault), true);
        control.setApprovalForAll(address(vault), true);
        filler.setApprovalForAll(address(vault), true);
        vm.stopPrank();
    }

    /// Deposits `es`, begins a reclaim with `probe` and the filler failing (the NFT
    /// leaves), then re-arms the probe healthy. Everything in `es` is still held.
    function _held(ManifestEntry[] memory es, GasProbe probe) internal returns (uint256 id) {
        id = nextBundle++;
        control.mint(seller, id);
        filler.setFailRelease(false);
        vault.deposit(id, seller, address(control), id, es);
        filler.setFailRelease(true);
        probe.arm(address(vault), true, 0);
        vault.beginRelease(id, ReleaseMode.Reclaim, extrasTo, seller);
        probe.arm(address(vault), false, 0);
        (,, uint256 held) = vault.bundleStatus(id);
        assertEq(held, (1 << es.length) - 1);
    }

    function _erc20ThenFiller() internal returns (uint256) {
        ManifestEntry[] memory es = new ManifestEntry[](2);
        es[0] = ManifestEntry(AssetKind.ERC20, address(p20), 0, 1 ether);
        es[1] = ManifestEntry(AssetKind.ERC1155, address(filler), 1, 1);
        return _held(es, p20);
    }

    function _erc20Only() internal returns (uint256) {
        ManifestEntry[] memory es = new ManifestEntry[](1);
        es[0] = ManifestEntry(AssetKind.ERC20, address(p20), 0, 1 ether);
        return _held(es, p20);
    }

    function _retry(uint256 id, uint256 mask, uint256 g) internal returns (bool ok) {
        (ok, lastReturn) =
            address(vault).call{gas: g}(abi.encodeCall(NewTradeV2VaultV2.releaseRemaining, (id, mask, address(this), "")));
    }

    function _assertGuardNoAttempt(uint256 id, uint256 mask, uint256 g) internal {
        vm.expectCall(address(vault), abi.encodeWithSelector(NewTradeV2VaultV2.attempt.selector), 0);
        assertFalse(_retry(id, mask, g), "must revert");
        assertEq(lastReturn, abi.encodeWithSelector(NewTradeV2VaultV2.GasTooLow.selector), "must be the guard");
    }

    /// `a` below the budget: the 63/64 inequality is what stops the `a - budget` underflow.
    function test_Batch_BelowBudget_IsTheGuardNotAPanic() public {
        _assertGuardNoAttempt(_erc20ThenFiller(), 3, BELOW_BUDGET);
    }

    /// 63/64 satisfied, reserve not: the reserve inequality alone must stop the attempt.
    function test_Batch_ReserveInequalityStopsTheAttemptOnItsOwn() public {
        _assertGuardNoAttempt(_erc20ThenFiller(), 3, RESERVE_WINDOW);
    }

    function test_Single_BelowReserve_IsTheGuard() public {
        _assertGuardNoAttempt(_erc20Only(), 1, BELOW_SINGLE_RESERVE);
    }

    /// No gas figure below the single-mode guard may return success, including the
    /// narrow band where `a <= GAS_OVERHEAD`.
    function test_Single_NoGasBelowTheGuardEverSucceeds() public {
        uint256 id = _erc20Only();
        for (uint256 g = 5_000; g <= BELOW_SINGLE_RESERVE; g += 100) {
            assertFalse(_retry(id, 1, g), "underfunded single retry must not succeed");
        }
    }

    /// Failing entry first, probe last: at the smallest gas that succeeds the rule binds at the
    /// probe, and it must still receive its whole budget. At current constants the reserve
    /// implies this; the test exists so a later lower reserve cannot lose the 63/64 cap.
    function test_Batch_AttemptAtTheMarginGetsItsWholeBudget() public {
        // Sorted by kind: an always-failing ERC-20 first, the probe NFT last.
        ProbeERC20 first = new ProbeERC20();
        first.mint(seller, 1 ether);
        vm.prank(seller);
        first.approve(address(vault), type(uint256).max);
        first.arm(address(vault), true, 0);
        ProbeERC721 last = new ProbeERC721();
        last.mint(seller, 1);
        vm.prank(seller);
        last.setApprovalForAll(address(vault), true);
        ManifestEntry[] memory es = new ManifestEntry[](2);
        es[0] = ManifestEntry(AssetKind.ERC20, address(first), 0, 1 ether);
        es[1] = ManifestEntry(AssetKind.ERC721, address(last), 1, 1);
        uint256 id = _held(es, last);
        last.setPersist(true);

        uint256 s = vm.snapshotState();
        assertTrue(_retry(id, 3, ENOUGH));
        uint256 ample = last.seenStored();
        vm.revertToState(s);

        uint256 lo = 21_000;
        uint256 hi = 3_000_000;
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            s = vm.snapshotState();
            bool ok = _retry(id, 3, mid);
            vm.revertToState(s);
            if (ok) hi = mid;
            else lo = mid + 1;
        }
        assertTrue(_retry(id, 3, hi));
        assertApproxEqAbs(last.seenStored(), ample, 2_000, "the attempt at the margin must get the full budget");
    }
}
