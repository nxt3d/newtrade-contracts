// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {NewTradeV2VaultV2} from "../src/NewTradeV2VaultV2.sol";
import {AcceptanceMode, AssetKind, ManifestEntry, ReleaseMode} from "../src/NewTradeV2Types.sol";
import {
    ToggleReleaseFailureERC20,
    ToggleReleaseFailureERC1155,
    Mock6551Registry,
    Mock6551Implementation,
    MockTokenboundAccountProxy
} from "./helpers/ERC6551Mocks.sol";
import {VaultV2Deploy} from "./helpers/VaultV2Deploy.sol";
import {NewTradeEscrowV2} from "../src/NewTradeEscrowV2.sol";
import {NewTradeBundle} from "../src/NewTradeBundle.sol";
import {NewTradeV2Vault} from "./legacy/NewTradeV2Vault.sol";
import {BundleState, Bundle, V2Initialization} from "../src/NewTradeV2Types.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockERC721} from "./mocks/TokenMocks.sol";
import {BundleDeploy} from "./helpers/BundleDeploy.sol";
import {SeaportV2Mock} from "./helpers/SeaportV2Mock.sol";
import {ConduitMock} from "./helpers/ConduitMock.sol";

/// Gas burner shared by the probe tokens. On a transfer OUT of the vault it
/// records the gas left at its entry (transient, so the record costs ~100 gas
/// and survives only if the attempt succeeds), then burns `burnAmount` gas.
/// burnAmount == type(uint256).max burns everything it was given (OOG).
abstract contract GasProbe {
    address public vault;
    bool public failOut;
    uint256 public burnAmount;
    bool public persist;
    /// Same reading as `seen()`, kept in storage when `persist` is set: under
    /// `forge test --isolate` every top-level call is its own transaction and
    /// transient storage is gone by the time the test reads it.
    uint256 public seenStored;

    function setPersist(bool p) external {
        persist = p;
    }

    function arm(address vault_, bool fail_, uint256 burn_) external {
        vault = vault_;
        failOut = fail_;
        burnAmount = burn_;
    }

    function seen() external view returns (uint256 g) {
        assembly ("memory-safe") {
            g := tload(0)
        }
    }

    function _onOut() internal {
        uint256 g = gasleft();
        assembly ("memory-safe") {
            tstore(0, g)
        }
        if (persist) seenStored = g;
        if (failOut) revert("PROBE_FAIL");
        uint256 n = burnAmount;
        if (n == 0) return;
        if (n == type(uint256).max) {
            while (true) {}
        }
        uint256 stop = gasleft() - n;
        while (gasleft() > stop) {}
    }
}

contract ProbeERC20 is ERC20, GasProbe {
    constructor() ERC20("Probe", "PRB") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (from == vault && from != address(0)) _onOut();
        super._update(from, to, amount);
    }
}

contract ProbeERC721 is ERC721, GasProbe {
    constructor() ERC721("Probe", "P721") {}

    function mint(address to, uint256 id) external {
        _mint(to, id);
    }

    function _update(address to, uint256 id, address auth) internal override returns (address from) {
        if (_ownerOf(id) == vault && vault != address(0)) _onOut();
        from = super._update(to, id, auth);
    }
}

/// The fresh account of a redemption, as far as the vault's NFT attempt sees it.
contract ProbeAccount {
    address public owner;

    constructor(address owner_) {
        owner = owner_;
    }

    function isValidSigner(address signer, bytes calldata) external view returns (bytes4) {
        return signer == owner ? bytes4(0x523e3260) : bytes4(0);
    }
}

contract CodeStub {}

/// `vm.lastCallGas().gasRemaining` counts the transaction's intrinsic gas as
/// used under `--isolate` (each top-level call is its own transaction), but the
/// callee still receives the full gas given. `_unused` adds the intrinsic part
/// back, so both modes report the gas the call actually left unspent.
abstract contract GasProbeBase is Test {
    bool isolated;

    function _detectIsolation() internal {
        address stub = address(new CodeStub());
        (bool ok,) = stub.call{gas: 50_000}("");
        ok;
        isolated = vm.lastCallGas().gasTotalUsed >= 21_000;
    }

    function _unused(bytes memory cd) internal view returns (uint256 u) {
        u = vm.lastCallGas().gasRemaining;
        if (!isolated) return u;
        u += 21_000;
        for (uint256 i; i < cd.length; ++i) {
            u += cd[i] == 0 ? 4 : 16;
        }
    }
}

/// @notice F-01 build step 1 (BUILD-PLAN section 5): measures the per-entry gas
/// isolation of the upgradeable vault THROUGH ITS PROXY, with the linked libraries,
/// under the production compiler settings. The test contract is the controller.
///
/// Every scenario is a bundle whose probe entry is still held after `beginRelease`
/// (the probe was armed to fail), plus a filler ERC-1155 entry that keeps failing,
/// so the retry mask names two bits and the vault runs in BATCH mode (budget B per
/// attempt), not single-entry mode.
///
/// Numbers are printed with `-vv`; the assertions pin the properties the design
/// promises (2.3) so a later change that breaks them fails here.
contract VaultGasProbeTest is GasProbeBase {
    uint256 constant BUDGET_ERC20 = 200_000;
    uint256 constant BUDGET_NFT = 400_000;
    uint256 constant GAS_OVERHEAD = 12_000;
    uint256 constant GAS_RESERVE = 40_000;
    uint256 constant NFT_BIT = 1 << 32;

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
        _detectIsolation();
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

    // ------------------------------------------------------------------ scenarios

    enum Kind {
        ERC20Entry,
        ERC721Entry,
        NFTReclaim,
        NFTRedeem
    }

    /// Deposits a bundle, begins its release with the probe failing, then re-arms
    /// the probe healthy. Returns the bundle, the probe's bit, the retry mask and
    /// the probe contract.
    function _scenario(Kind k) internal returns (uint256 id, uint256 probeBit, uint256 mask, GasProbe probe) {
        id = nextBundle++;
        uint256 nftId = 1000 + id;
        control.mint(seller, nftId);
        ManifestEntry[] memory es;
        if (k == Kind.ERC20Entry) {
            es = new ManifestEntry[](2);
            es[0] = ManifestEntry(AssetKind.ERC20, address(p20), 0, 1 ether);
            es[1] = ManifestEntry(AssetKind.ERC1155, address(filler), 1, 1);
            probeBit = 1;
            probe = p20;
        } else if (k == Kind.ERC721Entry) {
            p721.mint(seller, id);
            es = new ManifestEntry[](2);
            es[0] = ManifestEntry(AssetKind.ERC721, address(p721), id, 1);
            es[1] = ManifestEntry(AssetKind.ERC1155, address(filler), 1, 1);
            probeBit = 1;
            probe = p721;
        } else {
            es = new ManifestEntry[](1);
            es[0] = ManifestEntry(AssetKind.ERC1155, address(filler), 1, 1);
            probeBit = NFT_BIT;
            probe = control;
        }
        // The filler is the second bit; on a redemption it waits for the NFT anyway.
        mask = probeBit | (k == Kind.ERC20Entry || k == Kind.ERC721Entry ? 2 : 1);
        filler.setFailRelease(false);
        vault.deposit(id, seller, address(control), nftId, es);
        filler.setFailRelease(true);

        // Everything fails at the first release: the probe and (for entries) the NFT stay healthy.
        GasProbe(address(probe)).arm(address(vault), true, 0);
        if (address(probe) != address(control)) control.arm(address(vault), false, 0);
        if (k == Kind.NFTRedeem) {
            address account = address(new ProbeAccount(seller));
            vault.beginRelease(id, ReleaseMode.Redeem, account, seller);
        } else {
            vault.beginRelease(id, ReleaseMode.Reclaim, extrasTo, seller);
        }
        assertTrue(_held(id, probeBit), "probe must still be held after beginRelease");
        probe.arm(address(vault), false, 0);
    }

    function _held(uint256 id, uint256 bit) internal view returns (bool) {
        (,, uint256 held) = vault.bundleStatus(id);
        return held & bit != 0;
    }

    /// One retry with exactly `g` gas into the vault proxy. Returns whether the call
    /// succeeded and whether the probe left, and the gas the vault returned unused.
    function _retry(uint256 id, uint256 mask, uint256 probeBit, uint256 g)
        internal
        returns (bool callOk, bool released, uint256 unused)
    {
        bytes memory cd = abi.encodeCall(NewTradeV2VaultV2.releaseRemaining, (id, mask, address(this), ""));
        address v = address(vault);
        (callOk, lastReturn) = v.call{gas: g}(cd);
        unused = _unused(cd);
        released = !_held(id, probeBit);
    }

    /// Largest burn (gas the token's own code spends on top of a plain transfer)
    /// for which the entry still releases with ample transaction gas.
    function _maxBurn(uint256 id, uint256 mask, uint256 probeBit, GasProbe probe, uint256 budget)
        internal
        returns (uint256 lo)
    {
        uint256 hi = budget;
        while (lo < hi) {
            uint256 mid = (lo + hi + 1) / 2;
            uint256 snap = vm.snapshotState();
            probe.arm(address(vault), false, mid);
            (, bool released,) = _retry(id, mask, probeBit, 5_000_000);
            vm.revertToState(snap);
            if (released) lo = mid;
            else hi = mid - 1;
        }
    }

    /// P-1: the smallest gas into the vault proxy at which the retry SUCCEEDS with the
    /// probe armed to burn `burn`. Below it the gas guard reverts the whole call.
    function _threshold(uint256 id, uint256 mask, uint256 probeBit, GasProbe probe, uint256 burn)
        internal
        returns (uint256 hi)
    {
        uint256 lo = 30_000;
        hi = 3_000_000;
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            uint256 snap = vm.snapshotState();
            probe.arm(address(vault), false, burn);
            (bool ok,,) = _retry(id, mask, probeBit, mid);
            vm.revertToState(snap);
            if (ok) hi = mid;
            else lo = mid + 1;
        }
    }

    struct Result {
        uint256 atEntry;
        uint256 maxBurn;
        uint256 threshold;
        bool belowOk;
        bool belowReleased;
        bool belowIsGuard;
        uint256 maxBurnThreshold;
        bool maxBurnReleased;
        bool maxBurnBelowOk;
        uint256 oogThreshold;
        bool oogOk;
        bool oogHeld;
        uint256 oogUnused;
        bool oogBelowOk;
        bool noBudgetOk;
    }

    function _measure(Kind k, uint256 budget) internal returns (Result memory r) {
        (uint256 id, uint256 bit, uint256 mask, GasProbe probe) = _scenario(k);

        // 1. Gas at the token's transfer, healthy, ample gas.
        uint256 snap = vm.snapshotState();
        probe.setPersist(true);
        (, bool released,) = _retry(id, mask, bit, 5_000_000);
        assertTrue(released, "healthy probe must release");
        r.atEntry = probe.seenStored();
        vm.revertToState(snap);

        // 2. What the token's own code may burn inside the budget and still release.
        r.maxBurn = _maxBurn(id, mask, bit, probe, budget);

        // 3. Healthy probe: the smallest gas that succeeds, and one unit below it.
        r.threshold = _threshold(id, mask, bit, probe, 0);
        snap = vm.snapshotState();
        probe.arm(address(vault), false, 0);
        (r.belowOk, r.belowReleased,) = _retry(id, mask, bit, r.threshold - 1);
        r.belowIsGuard =
            keccak256(lastReturn) == keccak256(abi.encodeWithSelector(NewTradeV2VaultV2.GasTooLow.selector));
        vm.revertToState(snap);

        // 4. A token that needs almost the whole budget: every call that SUCCEEDS gave
        //    it the full budget, so at the smallest succeeding gas it has been released.
        r.maxBurnThreshold = _threshold(id, mask, bit, probe, r.maxBurn);
        snap = vm.snapshotState();
        probe.arm(address(vault), false, r.maxBurn);
        (, r.maxBurnReleased,) = _retry(id, mask, bit, r.maxBurnThreshold);
        vm.revertToState(snap);
        snap = vm.snapshotState();
        probe.arm(address(vault), false, r.maxBurn);
        (r.maxBurnBelowOk,,) = _retry(id, mask, bit, r.maxBurnThreshold - 1);
        vm.revertToState(snap);

        // 5. A token that burns everything it is given cannot take a funded batch down:
        //    the call completes, the entry stays held, gas is left over.
        r.oogThreshold = _threshold(id, mask, bit, probe, type(uint256).max);
        snap = vm.snapshotState();
        probe.arm(address(vault), false, type(uint256).max);
        bool oogReleased;
        (r.oogOk, oogReleased, r.oogUnused) = _retry(id, mask, bit, r.oogThreshold);
        r.oogHeld = !oogReleased;
        vm.revertToState(snap);
        snap = vm.snapshotState();
        probe.arm(address(vault), false, type(uint256).max);
        (r.oogBelowOk,,) = _retry(id, mask, bit, r.oogThreshold - 1);
        vm.revertToState(snap);

        // 6. With less than the first attempt's budget the guard reverts before any
        //    attempt frame is entered. Last: expectCall counts every later call.
        vm.expectCall(address(vault), abi.encodeWithSelector(NewTradeV2VaultV2.attempt.selector), 0);
        (r.noBudgetOk,,) = _retry(id, mask, bit, budget);
    }

    function _report(string memory name, uint256 budget, Result memory r) internal view {
        console2.log("==", name, isolated ? "(isolated: cold state, one tx per call)" : "(one tx: warm state)");
        console2.log("  budget B (gas into the proxy for one attempt)  ", budget);
        console2.log("  gas left at the token's transfer, healthy      ", r.atEntry);
        console2.log("  max extra burn in the token that still releases", r.maxBurn);
        console2.log("  usable share of B for the token's own code (bp)", r.maxBurn * 10_000 / budget);
        console2.log("  healthy: min gas into proxy for the batch      ", r.threshold);
        console2.log("  healthy, one below: call ok / released / guard ", r.belowOk ? 1 : 0, r.belowReleased ? 1 : 0);
        console2.log("    revert is GasTooLow                          ", r.belowIsGuard ? 1 : 0);
        console2.log("  max burn: min gas / released / ok one below    ", r.maxBurnThreshold);
        console2.log(
            "    released, ok one below                       ", r.maxBurnReleased ? 1 : 0, r.maxBurnBelowOk ? 1 : 0
        );
        console2.log("  OOG token: min gas                             ", r.oogThreshold);
        console2.log("    call ok, entry held                          ", r.oogOk ? 1 : 0, r.oogHeld ? 1 : 0);
        console2.log("    ok one below                                 ", r.oogBelowOk ? 1 : 0);
        console2.log("    gas the vault returned at that minimum       ", r.oogUnused);
    }

    function _check(Result memory r) internal pure {
        // P-1: below the batch's gas the guard reverts the whole call; nothing moves.
        assertFalse(r.belowOk, "below threshold: the call must revert");
        assertFalse(r.belowReleased, "below threshold: entry must stay held");
        assertTrue(r.belowIsGuard, "below threshold: the revert must be GasTooLow");
        // Every successful call delivered the full budget: the heaviest healthy token left.
        assertTrue(r.maxBurnReleased, "the smallest succeeding gas must deliver the full budget");
        assertFalse(r.maxBurnBelowOk, "max burn: one below must revert");
        // A budget-eating token never takes a funded batch down.
        assertTrue(r.oogOk, "OOG token must not revert a funded batch");
        assertTrue(r.oogHeld, "OOG token must stay held");
        assertFalse(r.oogBelowOk, "OOG token: one below must revert");
        assertFalse(r.noBudgetOk, "less than one budget must revert before any attempt");
    }

    function test_probe_erc20Entry() public {
        Result memory r = _measure(Kind.ERC20Entry, BUDGET_ERC20);
        _report("ERC-20 entry", BUDGET_ERC20, r);
        _check(r);
    }

    function test_probe_erc721Entry() public {
        Result memory r = _measure(Kind.ERC721Entry, BUDGET_NFT);
        _report("ERC-721 entry", BUDGET_NFT, r);
        _check(r);
    }

    function test_probe_controllingNFT_reclaim() public {
        Result memory r = _measure(Kind.NFTReclaim, BUDGET_NFT);
        _report("controlling NFT, reclaim", BUDGET_NFT, r);
        _check(r);
    }

    function test_probe_controllingNFT_redeem() public {
        Result memory r = _measure(Kind.NFTRedeem, BUDGET_NFT);
        _report("controlling NFT, redeem (account check)", BUDGET_NFT, r);
        _check(r);
    }
}

/// @notice The escrow's own reserve around its vault call (VAULT_CALL_RESERVE,
/// 30,000), measured through the production switch: an escrow proxy built with
/// the old vault, then a vault proxy and `initializeVault` (D1).
///
/// For each escrow entry point: the smallest gas at which the call succeeds,
/// what that leaves the bundle in, and the gas left unspent at that minimum.
contract EscrowReserveProbeTest is GasProbeBase {
    address constant SEAPORT = 0x0000000000000068F116a894984e2DB1123eB395;
    address constant CONDUIT = 0x1E0049783F008A0085193E00003D00cd54003c71;
    address seller = address(0xA11CE);
    address extrasTo = address(0xE87);

    NewTradeEscrowV2 escrow;
    NewTradeV2VaultV2 vault;
    ToggleReleaseFailureERC20 t20;
    MockERC721 control;
    uint64 deadline;
    uint256 nextNft = 1;

    function setUp() public {
        _detectIsolation();
        vm.warp(1_757_000_000);
        vm.etch(SEAPORT, address(new SeaportV2Mock()).code);
        vm.etch(CONDUIT, address(new ConduitMock()).code);
        NewTradeBundle receipt = BundleDeploy.deploy(address(this), SEAPORT, SEAPORT, address(0x0113E2));
        AssetKind[] memory kinds = new AssetKind[](0);
        address[] memory tokens = new address[](0);
        AcceptanceMode[3] memory disabled;
        Mock6551Registry registry = new Mock6551Registry();
        Mock6551Implementation accountImpl = new Mock6551Implementation();
        MockTokenboundAccountProxy accountProxy = new MockTokenboundAccountProxy(address(accountImpl));
        NewTradeV2Vault old = new NewTradeV2Vault(address(this), address(receipt), tokens, kinds, disabled);
        V2Initialization memory c = V2Initialization(
            address(this),
            address(0xFEE),
            250,
            tokens,
            tokens,
            kinds,
            disabled,
            address(registry),
            address(accountProxy),
            address(accountImpl),
            address(receipt),
            address(old),
            SEAPORT,
            SEAPORT,
            address(0)
        );
        NewTradeEscrowV2 impl = new NewTradeEscrowV2();
        escrow = NewTradeEscrowV2(
            payable(address(new ERC1967Proxy(address(impl), abi.encodeCall(NewTradeEscrowV2.initialize, (c)))))
        );
        receipt.bindController(address(escrow));
        old.bindController(address(escrow));

        vault = VaultV2Deploy.switchEscrow(escrow, address(receipt));
        for (uint256 i; i < 3; ++i) {
            escrow.setAssetAcceptanceMode(AssetKind(i), AcceptanceMode.Wildcard);
        }
        t20 = new ToggleReleaseFailureERC20();
        control = new MockERC721();
        t20.mint(seller, 100 ether);
        vm.startPrank(seller);
        t20.approve(address(vault), type(uint256).max);
        control.setApprovalForAll(address(vault), true);
        vm.stopPrank();
        deadline = uint64(block.timestamp + 1 days);
    }

    function _deposit() internal returns (uint256 id) {
        uint256 nftId = nextNft++;
        control.mint(seller, nftId);
        ManifestEntry[] memory es = new ManifestEntry[](1);
        es[0] = ManifestEntry(AssetKind.ERC20, address(t20), 0, 1 ether);
        vm.prank(seller);
        id = escrow.deposit(address(control), nftId, es, deadline);
    }

    function _state(uint256 id) internal view returns (BundleState) {
        Bundle memory b = escrow.getBundle(id);
        return b.state;
    }

    /// Smallest gas at which `seller` calling `escrow` with `cd` succeeds and
    /// (if `wantClosed`) leaves the bundle in `closed`.
    function _min(uint256 id, bytes memory cd, bool wantClosed, BundleState closed)
        internal
        returns (uint256 hi, uint256 unused)
    {
        uint256 lo = 21_000;
        hi = 3_000_000;
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            uint256 snap = vm.snapshotState();
            vm.prank(seller);
            (bool ok,) = address(escrow).call{gas: mid}(cd);
            bool good = ok && (!wantClosed || _state(id) == closed);
            vm.revertToState(snap);
            if (good) hi = mid;
            else lo = mid + 1;
        }
        uint256 s = vm.snapshotState();
        vm.prank(seller);
        (bool ok2,) = address(escrow).call{gas: hi}(cd);
        assertTrue(ok2);
        unused = _unused(cd);
        vm.revertToState(s);
    }

    function test_probe_escrowReserve() public {
        // Reclaim of a healthy bundle: the smallest gas that succeeds at all, and
        // the smallest that closes it.
        uint256 a = _deposit();
        vm.warp(deadline + 1);
        bytes memory rc = abi.encodeCall(NewTradeEscrowV2.reclaim, (a, extrasTo));
        (uint256 anyGas, uint256 anyUnused) = _min(a, rc, false, BundleState.None);
        uint256 s = vm.snapshotState();
        vm.prank(seller);
        (bool ok,) = address(escrow).call{gas: anyGas}(rc);
        assertTrue(ok);
        BundleState atAny = _state(a);
        (,, uint256 heldAtAny) = vault.bundleStatus(a);
        vm.revertToState(s);
        (uint256 closeGas, uint256 closeUnused) = _min(a, rc, true, BundleState.Reclaimed);

        // A bundle left Reclaiming (its ERC-20 entry failed), then retried.
        vm.warp(1_757_000_000);
        deadline = uint64(block.timestamp + 1 days);
        uint256 b = _deposit();
        vm.warp(deadline + 1);
        t20.setFailRelease(true);
        vm.prank(seller);
        escrow.reclaim(b, extrasTo);
        assertEq(uint8(_state(b)), uint8(BundleState.Reclaiming));
        t20.setFailRelease(false);
        bytes memory wr = abi.encodeCall(NewTradeEscrowV2.withdrawRemaining, (b, 1, ""));
        (uint256 wAny, uint256 wAnyUnused) = _min(b, wr, false, BundleState.None);
        (uint256 wClose, uint256 wCloseUnused) = _min(b, wr, true, BundleState.Reclaimed);

        console2.log("== escrow reserve (VAULT_CALL_RESERVE 30,000)", isolated ? "(isolated)" : "(one tx)");
        console2.log("  reclaim: min gas that succeeds                 ", anyGas);
        console2.log("    bundle state / vault bits held at that gas    ", uint8(atAny), heldAtAny);
        console2.log("    gas unspent at that minimum                   ", anyUnused);
        console2.log("  reclaim: min gas that closes the bundle         ", closeGas);
        console2.log("    gas unspent at that minimum                   ", closeUnused);
        console2.log("  withdrawRemaining: min gas that succeeds        ", wAny);
        console2.log("    gas unspent at that minimum                   ", wAnyUnused);
        console2.log("  withdrawRemaining: min gas that closes          ", wClose);
        console2.log("    gas unspent at that minimum                   ", wCloseUnused);

        // P-1: a batch first exit cannot succeed without funding every attempt, so the
        // smallest gas that succeeds is the gas that closes.
        assertEq(anyGas, closeGas);
        assertEq(uint8(atAny), uint8(BundleState.Reclaimed));
        // Single mode (decision 1, 2026-11-20): a one-entry retry whose attempt fails
        // reverts the whole call, so here too the smallest gas that succeeds closes.
        assertEq(wAny, wClose);
    }
}
