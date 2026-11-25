// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/Test.sol";
import {V2BundleEscrowTest} from "./V2BundleEscrow.t.sol";
import {GasProbe, ProbeERC20, ProbeERC721} from "./VaultGasProbe.t.sol";
import {NewTradeEscrowV2} from "../src/NewTradeEscrowV2.sol";
import {NewTradeV2VaultV2} from "../src/NewTradeV2VaultV2.sol";
import {NewTradeV2VaultStorage} from "../src/NewTradeV2VaultStorage.sol";
import {AcceptanceMode, AssetKind, BundleState, ManifestEntry, ReleaseMode} from "../src/NewTradeV2Types.sol";
import {
    MockTokenboundAccountProxy,
    Mock6551WrongOwnerImplementation,
    ToggleReleaseFailureERC20,
    ToggleReleaseFailureERC721
} from "./helpers/ERC6551Mocks.sol";
import {VaultV2Views} from "./helpers/VaultV2Deploy.sol";

/// @notice P-1 (design 2.3, devlead review 2026-11-07): the vault's gas guards revert the
/// whole call, so an underfunded exit fails instead of succeeding having attempted
/// nothing. Everything here goes through the real escrow and the proxied vault.
///
/// Single-entry mode (decision 1, 2026-11-20): a failed attempt reverts the whole call;
/// see the `Single` tests. Redirect and first-destination rules (decision 2) are pinned
/// here too. What this does NOT establish: these are mock tokens.
contract RefusingAll {}

contract VaultGasGuardTest is V2BundleEscrowTest {
    using VaultV2Views for NewTradeV2VaultV2;

    uint256 constant NFT_BIT = 1 << 32;
    uint256 constant ENTRIES_3 = 7;
    address extrasDest = address(0xE87);
    bytes lastData;

    function _call(address from, bytes memory cd, uint256 g) internal returns (bool ok) {
        vm.prank(from);
        (ok, lastData) = address(escrow).call{gas: g}(cd);
    }

    /// Smallest gas at which the call succeeds.
    function _minOk(address from, bytes memory cd, uint256 hi) internal returns (uint256) {
        uint256 lo = 21_000;
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            uint256 s = vm.snapshotState();
            bool ok = _call(from, cd, mid);
            vm.revertToState(s);
            if (ok) hi = mid;
            else lo = mid + 1;
        }
        return hi;
    }

    function _isGuard() internal view returns (bool) {
        return keccak256(lastData) == keccak256(abi.encodeWithSelector(NewTradeV2VaultV2.GasTooLow.selector));
    }

    function _digest(uint256 id) internal view returns (bytes32) {
        (NewTradeV2VaultStorage.Custody memory c, NewTradeV2VaultStorage.ReleaseRecord memory r, uint256 held) =
            custody.bundleStatus(id);
        return keccak256(
            abi.encode(
                c,
                r,
                held,
                escrow.getBundle(id),
                control.ownerOf(1),
                extra721.ownerOf(7),
                erc20.balanceOf(address(custody)),
                erc1155.balanceOf(address(custody), 3),
                custody.erc20Liability(address(erc20)),
                custody.erc1155Liability(address(erc1155), 3),
                custody.erc721Reserved(address(extra721), 7)
            )
        );
    }

    /// Below the minimum every call reverts and nothing changes; at it the exit closes.
    function _sweep(address from, bytes memory cd, uint256 id, address claimOwner, BundleState closed) internal {
        // Read everything the assertions read BEFORE searching: within one test transaction
        // a slot read warms it, and a warmer retry needs a few hundred less gas.
        bytes32 before = _digest(id);
        receipt.ownerOf(id);
        uint256 g = _minOk(from, cd, 8_000_000);
        uint256 step = (g - 40_000) / 24;
        for (uint256 tryGas = 40_000; tryGas < g; tryGas += step) {
            uint256 s = vm.snapshotState();
            assertFalse(_call(from, cd, tryGas), "underfunded must revert");
            assertEq(_digest(id), before, "underfunded must change nothing");
            assertEq(receipt.ownerOf(id), claimOwner, "claim survives");
            vm.revertToState(s);
        }
        uint256 s2 = vm.snapshotState();
        assertFalse(_call(from, cd, g - 1), "one below must revert");
        assertTrue(_isGuard(), "one below is the gas guard");
        assertEq(_digest(id), before);
        vm.revertToState(s2);
        assertTrue(_call(from, cd, g), "at the minimum it succeeds");
        assertEq(uint8(escrow.getBundle(id).state), uint8(closed), "and it closes");
    }

    function test_LowGasFirstReclaimRevertsWholeAndChangesNothing() public {
        uint256 id = deposit();
        vm.warp(deadline);
        _sweep(
            seller,
            abi.encodeCall(NewTradeEscrowV2.reclaim, (id, extrasDest)),
            id,
            address(escrow),
            BundleState.Reclaimed
        );
    }

    function test_LowGasFirstRedemptionRevertsWholeAndChangesNothing() public {
        uint256 id = deposit();
        issue(id, buyer);
        bytes32 salt = keccak256("guard");
        (address predicted,) = escrow.computeFreshAccount(id, buyer, salt);
        bytes memory cd = abi.encodeCall(NewTradeEscrowV2.redeemToFreshAccount, (id, salt));
        uint256 g = _minOk(buyer, cd, 8_000_000);
        uint256 s = vm.snapshotState();
        assertFalse(_call(buyer, cd, g - 1));
        assertEq(predicted.code.length, 0, "the fresh account creation rolled back too");
        vm.revertToState(s);
        _sweep(buyer, cd, id, buyer, BundleState.Redeemed);
    }

    /// The NFT and the first entries have really moved inside the call when a later
    /// guard fires: all of it rolls back.
    function test_LateGuardRollsBackEarlierSuccessfulReleases() public {
        uint256 id = deposit();
        vm.warp(deadline);
        bytes memory cd = abi.encodeCall(NewTradeEscrowV2.reclaim, (id, extrasDest));
        bytes32 before = _digest(id);
        uint256 g = _minOk(seller, cd, 8_000_000);
        vm.expectCall(address(custody), abi.encodeCall(NewTradeV2VaultV2.attempt, (id, 32)), 1);
        vm.expectCall(address(custody), abi.encodeCall(NewTradeV2VaultV2.attempt, (id, 0)), 1);
        assertFalse(_call(seller, cd, g - 1));
        assertTrue(_isGuard());
        assertEq(_digest(id), before);
        assertEq(control.ownerOf(1), address(custody));
        assertEq(erc20.balanceOf(extrasDest), 0);
    }

    function _stuckRedeeming() internal returns (uint256 id, address account) {
        Mock6551WrongOwnerImplementation wrong = new Mock6551WrongOwnerImplementation(address(0xDEAD));
        MockTokenboundAccountProxy wrongProxy = new MockTokenboundAccountProxy(address(wrong));
        escrow.setTrustedAccountCode(address(wrongProxy), false, true);
        escrow.setTrustedAccountCode(address(wrong), false, true);
        escrow.setFreshAccountPolicy(address(registry), address(wrongProxy), address(wrong), true);
        id = deposit();
        issue(id, buyer);
        vm.prank(buyer);
        account = escrow.redeemToFreshAccount(id, keccak256("stuck"));
        (,, uint256 held) = custody.bundleStatus(id);
        assertEq(held, NFT_BIT | ENTRIES_3);
    }

    /// A guard revert after the redirect command undoes the redirect as well.
    function test_GuardRollsBackARedirect() public {
        (uint256 id, address account) = _stuckRedeeming();
        address to = address(0x7077);
        bytes memory cd = abi.encodeCall(NewTradeEscrowV2.withdrawRemaining, (id, ENTRIES_3, abi.encode(uint8(1), to)));
        uint256 g = _minOk(buyer, cd, 8_000_000);
        uint256 s = vm.snapshotState();
        assertFalse(_call(buyer, cd, g - 1));
        (, NewTradeV2VaultStorage.ReleaseRecord memory r,) = custody.bundleStatus(id);
        assertFalse(r.redirected, "redirect rolled back");
        assertEq(r.extrasTo, account, "destination restored");
        vm.revertToState(s);
        assertTrue(_call(buyer, cd, g));
        assertEq(erc20.balanceOf(to), 20 ether);
        (,, uint256 held) = custody.bundleStatus(id);
        assertEq(held, NFT_BIT, "the entries left; the NFT is still held");
    }

    /// Entries waiting for the NFT are a dependency, not a gas skip: no revert, no attempt.
    function test_ManifestOnlyRetryWhileNftHeldIsANoOpNotAGuardRevert() public {
        (uint256 id,) = _stuckRedeeming();
        bytes32 before = _digest2(id);
        vm.expectCall(address(custody), abi.encodeWithSelector(NewTradeV2VaultV2.attempt.selector), 0);
        assertTrue(_call(holderC, abi.encodeCall(NewTradeEscrowV2.withdrawRemaining, (id, ENTRIES_3, "")), 150_000));
        assertEq(_digest2(id), before);
    }

    function _digest2(uint256 id) internal view returns (bytes32) {
        (NewTradeV2VaultStorage.Custody memory c, NewTradeV2VaultStorage.ReleaseRecord memory r, uint256 held) =
            custody.bundleStatus(id);
        return keccak256(abi.encode(c, r, held, escrow.getBundle(id)));
    }

    function test_ZeroMaskAndAlreadyReleasedBitsAreNoOpsAndBadBitsRefused() public {
        ToggleReleaseFailureERC20 t = new ToggleReleaseFailureERC20();
        uint256 id = _depositTwenty(t);
        vm.warp(deadline);
        t.setFailRelease(true);
        vm.prank(seller);
        escrow.reclaim(id, extrasDest);
        assertTrue(
            _call(holderC, abi.encodeCall(NewTradeEscrowV2.withdrawRemaining, (id, 0, "")), 150_000), "zero mask"
        );
        assertTrue(
            _call(holderC, abi.encodeCall(NewTradeEscrowV2.withdrawRemaining, (id, NFT_BIT, "")), 150_000),
            "released bit"
        );
        vm.prank(holderC);
        vm.expectRevert(NewTradeV2VaultV2.InvalidMask.selector);
        escrow.withdrawRemaining(id, 1 << 5, "");
        (,, uint256 held) = custody.bundleStatus(id);
        assertEq(held, 1);
    }

    function _depositTwenty(ToggleReleaseFailureERC20 t) internal returns (uint256 id) {
        escrow.setAssetKind(address(t), AssetKind.ERC20, true);
        t.mint(seller, 20 ether);
        vm.prank(seller);
        t.approve(address(custody), type(uint256).max);
        ManifestEntry[] memory es = new ManifestEntry[](1);
        es[0] = ManifestEntry(AssetKind.ERC20, address(t), 0, 20 ether);
        vm.prank(seller);
        id = escrow.deposit(address(control), 1, es, deadline);
    }

    /// With every attempt funded, a token that burns its whole budget leaves its healthy
    /// siblings committed.
    function test_FundedBatchKeepsHealthySiblingsBesideABudgetBurner() public {
        ProbeERC20 burner = new ProbeERC20();
        escrow.setAssetKind(address(burner), AssetKind.ERC20, true);
        burner.mint(seller, 5);
        vm.prank(seller);
        burner.approve(address(custody), type(uint256).max);
        ManifestEntry[] memory es = new ManifestEntry[](2);
        es[0] = ManifestEntry(AssetKind.ERC20, address(burner), 0, 5);
        es[1] = ManifestEntry(AssetKind.ERC721, address(extra721), 7, 1);
        vm.prank(seller);
        uint256 id = escrow.deposit(address(control), 1, es, deadline);
        burner.arm(address(custody), false, type(uint256).max);
        vm.warp(deadline);
        assertTrue(_call(seller, abi.encodeCall(NewTradeEscrowV2.reclaim, (id, extrasDest)), 3_000_000));
        (,, uint256 held) = custody.bundleStatus(id);
        assertEq(held, 1, "only the burner is held");
        assertEq(extra721.ownerOf(7), extrasDest);
        assertEq(control.ownerOf(1), seller);
    }

    /// Reclaim does not wait for the NFT.
    function test_ReclaimEntriesLeaveWhenTheNftAttemptFails() public {
        ToggleReleaseFailureERC721 nft = new ToggleReleaseFailureERC721();
        escrow.setAssetKind(address(nft), AssetKind.ERC721, true);
        nft.mint(seller, 1);
        vm.prank(seller);
        nft.setApprovalForAll(address(custody), true);
        ManifestEntry[] memory es = new ManifestEntry[](1);
        es[0] = ManifestEntry(AssetKind.ERC20, address(erc20), 0, 3 ether);
        vm.prank(seller);
        uint256 id = escrow.deposit(address(nft), 1, es, deadline);
        nft.setFailRelease(true);
        vm.warp(deadline);
        vm.prank(seller);
        escrow.reclaim(id, extrasDest);
        assertEq(erc20.balanceOf(extrasDest), 3 ether);
        assertEq(nft.ownerOf(1), address(custody));
        (,, uint256 held) = custody.bundleStatus(id);
        assertEq(held, NFT_BIT);
        assertEq(uint8(escrow.getBundle(id).state), uint8(BundleState.Reclaiming));
    }

    // ------------------------------------------------------------ single mode

    function _isReleaseFailed() internal view returns (bool) {
        return keccak256(lastData) == keccak256(abi.encodeWithSelector(NewTradeV2VaultV2.ReleaseFailed.selector));
    }

    /// Decision 1 (2026-11-20). A ONE-bit retry is single mode: the attempt gets all the
    /// gas there is and a failed attempt reverts the whole call. So no gas limit makes the
    /// call succeed without releasing: the smallest gas that succeeds closes the bundle,
    /// and everything below it reverts and changes nothing.
    function test_Single_RetrySucceedsOnlyByReleasing() public {
        ToggleReleaseFailureERC20 t = new ToggleReleaseFailureERC20();
        uint256 id = _depositTwenty(t);
        vm.warp(deadline);
        t.setFailRelease(true);
        vm.prank(seller);
        escrow.reclaim(id, extrasDest);
        t.setFailRelease(false);
        bytes memory cd = abi.encodeCall(NewTradeEscrowV2.withdrawRemaining, (id, 1, ""));
        bytes32 before = _digest2(id);
        uint256 g = _minOk(holderC, cd, 3_000_000);
        uint256 s = vm.snapshotState();
        assertTrue(_call(holderC, cd, g));
        assertEq(uint8(escrow.getBundle(id).state), uint8(BundleState.Reclaimed), "the minimum closes");
        assertEq(t.balanceOf(extrasDest), 20 ether);
        vm.revertToState(s);
        bool sawReleaseFailed;
        bool sawGuard;
        uint256 step = (g - 40_000) / 48;
        for (uint256 tryGas = 40_000; tryGas < g; tryGas += step) {
            uint256 s2 = vm.snapshotState();
            assertFalse(_call(holderC, cd, tryGas), "below the minimum must revert");
            if (_isReleaseFailed()) sawReleaseFailed = true;
            if (_isGuard()) sawGuard = true;
            assertEq(_digest2(id), before, "and change nothing");
            assertEq(t.balanceOf(extrasDest), 0);
            vm.revertToState(s2);
        }
        assertFalse(_call(holderC, cd, g - 1), "one below reverts");
        assertEq(_digest2(id), before);
        assertTrue(sawGuard, "far below: the gas guard");
        assertTrue(sawReleaseFailed, "above the guard: the starved attempt reverts the call");
    }

    /// A one-entry retry of a token that still refuses reverts with ReleaseFailed however
    /// much gas it has, and changes nothing. The same entry named beside another bit is a
    /// batch: it stays non-fatal.
    function test_Single_RetryOfAStillBrokenTokenReverts() public {
        ToggleReleaseFailureERC20 t = new ToggleReleaseFailureERC20();
        uint256 id = _depositTwenty(t);
        vm.warp(deadline);
        t.setFailRelease(true);
        vm.prank(seller);
        escrow.reclaim(id, extrasDest);
        bytes32 before = _digest2(id);
        vm.prank(holderC);
        vm.expectRevert(NewTradeV2VaultV2.ReleaseFailed.selector);
        escrow.withdrawRemaining(id, 1, "");
        // "everything" with one bit left is single mode too.
        vm.prank(holderC);
        vm.expectRevert(NewTradeV2VaultV2.ReleaseFailed.selector);
        escrow.withdrawRemaining(id, NFT_BIT | 1, "");
        assertEq(_digest2(id), before);
    }

    /// An empty-manifest first exit names only the NFT, so it is single mode: at its
    /// smallest successful gas the NFT is home and the bundle closed; one below, nothing
    /// happened and the claim is still there.
    function test_Single_EmptyManifestFirstExitReleasesTheNftOrReverts() public {
        ManifestEntry[] memory none = new ManifestEntry[](0);
        vm.prank(seller);
        uint256 id = escrow.deposit(address(control), 1, none, deadline);
        vm.warp(deadline);
        bytes memory cd = abi.encodeCall(NewTradeEscrowV2.reclaim, (id, extrasDest));
        uint256 g = _minOk(seller, cd, 3_000_000);
        uint256 s = vm.snapshotState();
        assertTrue(_call(seller, cd, g));
        assertEq(uint8(escrow.getBundle(id).state), uint8(BundleState.Reclaimed));
        assertEq(control.ownerOf(1), seller);
        vm.revertToState(s);
        assertFalse(_call(seller, cd, g - 1));
        assertEq(uint8(escrow.getBundle(id).state), uint8(BundleState.Deposited), "nothing began");
        assertEq(receipt.ownerOf(id), address(escrow), "claim not burned");
        assertEq(control.ownerOf(1), address(custody));
    }

    function _emptyBundleWithToggleNft() internal returns (ToggleReleaseFailureERC721 nft, uint256 id) {
        nft = new ToggleReleaseFailureERC721();
        escrow.setAssetKind(address(nft), AssetKind.ERC721, true);
        nft.mint(seller, 1);
        vm.prank(seller);
        nft.setApprovalForAll(address(custody), true);
        ManifestEntry[] memory none = new ManifestEntry[](0);
        vm.prank(seller);
        id = escrow.deposit(address(nft), 1, none, deadline);
    }

    /// Empty manifest, NFT that will not move: the reclaim reverts and the seller keeps
    /// every right. Nothing else was there to free, so nothing is lost by not beginning.
    function test_Single_EmptyManifestReclaimWithABrokenNftRevertsAndKeepsTheClaim() public {
        (ToggleReleaseFailureERC721 nft, uint256 id) = _emptyBundleWithToggleNft();
        nft.setFailRelease(true);
        vm.warp(deadline);
        vm.prank(seller);
        vm.expectRevert(NewTradeV2VaultV2.ReleaseFailed.selector);
        escrow.reclaim(id, extrasDest);
        assertEq(uint8(escrow.getBundle(id).state), uint8(BundleState.Deposited));
        assertEq(receipt.ownerOf(id), address(escrow));
        (, NewTradeV2VaultStorage.ReleaseRecord memory r,) = custody.bundleStatus(id);
        assertFalse(r.initialized, "no release record");
        nft.setFailRelease(false);
        vm.prank(seller);
        escrow.reclaim(id, extrasDest);
        assertEq(uint8(escrow.getBundle(id).state), uint8(BundleState.Reclaimed));
        assertEq(nft.ownerOf(1), seller);
    }

    /// The same on a redemption: the holder keeps the claim and no account is created.
    function test_Single_EmptyManifestRedeemWithABrokenNftRevertsAndKeepsTheClaim() public {
        (ToggleReleaseFailureERC721 nft, uint256 id) = _emptyBundleWithToggleNft();
        issue(id, buyer);
        nft.setFailRelease(true);
        (address predicted,) = escrow.computeFreshAccount(id, buyer, keccak256("empty"));
        vm.prank(buyer);
        vm.expectRevert(NewTradeV2VaultV2.ReleaseFailed.selector);
        escrow.redeemToFreshAccount(id, keccak256("empty"));
        assertEq(uint8(escrow.getBundle(id).state), uint8(BundleState.Issued));
        assertEq(receipt.ownerOf(id), buyer);
        assertEq(predicted.code.length, 0, "the fresh account rolled back");
        nft.setFailRelease(false);
        vm.prank(buyer);
        escrow.redeemToFreshAccount(id, keccak256("empty"));
        assertEq(uint8(escrow.getBundle(id).state), uint8(BundleState.Redeemed));
        assertEq(nft.ownerOf(1), buyer);
    }

    /// Dependency no-op, unchanged: on a redemption whose NFT is held, one named entry
    /// is not attempted at all (it waits for the NFT), so the call succeeds and changes
    /// nothing. Naming the stuck NFT alone IS an attempt, and reverts.
    function test_Single_EntryWaitingForTheNftIsANoOpNotAFailure() public {
        (uint256 id,) = _stuckRedeeming();
        bytes32 before = _digest(id);
        vm.expectCall(address(custody), abi.encodeCall(NewTradeV2VaultV2.attempt, (id, 0)), 0);
        vm.prank(holderC);
        escrow.withdrawRemaining(id, 1, "");
        assertEq(_digest(id), before);
        vm.prank(holderC);
        vm.expectRevert(NewTradeV2VaultV2.ReleaseFailed.selector);
        escrow.withdrawRemaining(id, NFT_BIT, "");
        assertEq(_digest(id), before);
    }

    // ------------------------------------------------------------ redirect rules

    /// Redemption redirect, unchanged: the redeemer only, while the NFT is held. A zero
    /// mask records it alone; the entries then leave without waiting for the NFT.
    function test_Redirect_RedeemerOnlyWhileTheNftIsHeld() public {
        (uint256 id, address account) = _stuckRedeeming();
        address to = address(0x7077);
        bytes memory cmd = abi.encode(uint8(1), to);
        vm.prank(seller);
        vm.expectRevert(NewTradeV2VaultV2.NotRedeemer.selector);
        escrow.withdrawRemaining(id, 0, cmd);
        vm.prank(holderC);
        vm.expectRevert(NewTradeV2VaultV2.NotRedeemer.selector);
        escrow.withdrawRemaining(id, 0, cmd);
        address[4] memory refused = [address(0), address(custody), address(escrow), address(receipt)];
        for (uint256 i; i < 4; ++i) {
            vm.prank(buyer);
            vm.expectRevert(NewTradeV2VaultV2.NotRedeemer.selector);
            escrow.withdrawRemaining(id, 0, abi.encode(uint8(1), refused[i]));
        }
        vm.prank(buyer);
        escrow.withdrawRemaining(id, 0, cmd);
        (, NewTradeV2VaultStorage.ReleaseRecord memory r, uint256 held) = custody.bundleStatus(id);
        assertTrue(r.redirected);
        assertEq(r.extrasTo, to);
        assertEq(r.nftTo, buyer, "the NFT's destination never changes");
        assertEq(held, NFT_BIT | ENTRIES_3, "a zero mask releases nothing");
        vm.prank(holderC);
        escrow.withdrawRemaining(id, ENTRIES_3, "");
        (,, held) = custody.bundleStatus(id);
        assertEq(held, NFT_BIT);
        assertEq(erc20.balanceOf(to), 20 ether);
        assertEq(erc20.balanceOf(account), 0);
        assertEq(extra721.ownerOf(7), to);
        assertEq(uint8(escrow.getBundle(id).state), uint8(BundleState.Redeeming));
    }

    /// Once the NFT has left a redemption, nobody redirects: the entries follow the account.
    function test_Redirect_RedemptionRefusedAfterTheNftLeft() public {
        ToggleReleaseFailureERC20 t = new ToggleReleaseFailureERC20();
        uint256 id = _depositTwenty(t);
        issue(id, buyer);
        t.setFailRelease(true);
        vm.prank(buyer);
        escrow.redeemToFreshAccount(id, keccak256("after-nft"));
        (,, uint256 held) = custody.bundleStatus(id);
        assertEq(held, 1);
        vm.prank(buyer);
        vm.expectRevert(NewTradeV2VaultV2.NotRedeemer.selector);
        escrow.withdrawRemaining(id, 0, abi.encode(uint8(1), buyer));
    }

    /// Decision 2 (2026-11-20). On a reclaim the seller alone may redirect the entries
    /// still held, also after the NFT has gone home. A redirect sent with a one-entry
    /// mask rolls back with that entry's failure; a zero mask records it alone.
    function test_Redirect_SellerRedirectsAReclaimAfterTheNftLeft() public {
        ToggleReleaseFailureERC20 t = new ToggleReleaseFailureERC20();
        uint256 id = _depositTwenty(t);
        vm.warp(deadline);
        t.setFailRelease(true);
        vm.prank(seller);
        escrow.reclaim(id, extrasDest);
        assertEq(control.ownerOf(1), seller, "NFT already home");
        address to = address(0x7078);
        bytes memory cmd = abi.encode(uint8(1), to);
        vm.prank(holderC);
        vm.expectRevert(NewTradeV2VaultV2.NotRedeemer.selector);
        escrow.withdrawRemaining(id, 0, cmd);
        vm.prank(extrasDest);
        vm.expectRevert(NewTradeV2VaultV2.NotRedeemer.selector);
        escrow.withdrawRemaining(id, 0, cmd);
        address[4] memory refused = [address(0), address(custody), address(escrow), address(receipt)];
        for (uint256 i; i < 4; ++i) {
            vm.prank(seller);
            vm.expectRevert(NewTradeV2VaultV2.NotRedeemer.selector);
            escrow.withdrawRemaining(id, 0, abi.encode(uint8(1), refused[i]));
        }
        // One-entry mask, token still failing: the whole call reverts, redirect included.
        vm.prank(seller);
        vm.expectRevert(NewTradeV2VaultV2.ReleaseFailed.selector);
        escrow.withdrawRemaining(id, 1, cmd);
        (, NewTradeV2VaultStorage.ReleaseRecord memory r,) = custody.bundleStatus(id);
        assertFalse(r.redirected);
        assertEq(r.extrasTo, extrasDest);
        // Zero mask: the redirect alone.
        vm.prank(seller);
        escrow.withdrawRemaining(id, 0, cmd);
        (, r,) = custody.bundleStatus(id);
        assertTrue(r.redirected);
        assertEq(r.extrasTo, to);
        assertEq(r.nftTo, seller);
        t.setFailRelease(false);
        vm.prank(holderC);
        escrow.withdrawRemaining(id, 1, "");
        assertEq(uint8(escrow.getBundle(id).state), uint8(BundleState.Reclaimed));
        assertEq(t.balanceOf(to), 20 ether);
        assertEq(t.balanceOf(extrasDest), 0);
        assertEq(custody.erc20Liability(address(t)), 0);
    }

    /// The reclaim redirect does not need the NFT to have left either, and never moves
    /// the NFT anywhere but to the seller.
    function test_Redirect_SellerRedirectsAReclaimWhileTheNftIsHeld() public {
        ToggleReleaseFailureERC721 nft = new ToggleReleaseFailureERC721();
        escrow.setAssetKind(address(nft), AssetKind.ERC721, true);
        nft.mint(seller, 1);
        vm.prank(seller);
        nft.setApprovalForAll(address(custody), true);
        ManifestEntry[] memory es = new ManifestEntry[](2);
        es[0] = ManifestEntry(AssetKind.ERC20, address(erc20), 0, 3 ether);
        es[1] = ManifestEntry(AssetKind.ERC721, address(extra721), 7, 1);
        vm.prank(seller);
        uint256 id = escrow.deposit(address(nft), 1, es, deadline);
        nft.setFailRelease(true);
        vm.warp(deadline);
        // A contract with no receiver hook: it refuses the ERC-721 entry.
        RefusingAll refusing = new RefusingAll();
        vm.prank(seller);
        escrow.reclaim(id, address(refusing));
        (,, uint256 held) = custody.bundleStatus(id);
        assertEq(held, NFT_BIT | 2, "ERC-20 left (no hook); NFT and the ERC-721 entry held");
        address to = address(0x7079);
        vm.prank(seller);
        escrow.withdrawRemaining(id, NFT_BIT | 2, abi.encode(uint8(1), to));
        (,, held) = custody.bundleStatus(id);
        assertEq(held, NFT_BIT, "the redirected entry left; the NFT attempt failed beside it");
        assertEq(extra721.ownerOf(7), to);
        assertEq(erc20.balanceOf(address(refusing)), 3 ether, "a released entry is never re-sent");
        assertEq(erc20.balanceOf(to), 0);
        nft.setFailRelease(false);
        vm.prank(holderC);
        escrow.withdrawRemaining(id, NFT_BIT, "");
        assertEq(nft.ownerOf(1), seller, "the NFT still goes to the seller");
        assertEq(uint8(escrow.getBundle(id).state), uint8(BundleState.Reclaimed));
    }

    // ------------------------------------------------------------ first destinations

    /// The vault refuses itself, the escrow and the claim collection as a first
    /// destination, for either asset stream and either mode.
    function test_BeginRelease_RefusesProtocolDestinations() public {
        uint256 id = deposit();
        address[3] memory refused = [address(custody), address(escrow), address(receipt)];
        for (uint256 i; i < 3; ++i) {
            for (uint256 m; m < 2; ++m) {
                vm.prank(address(escrow));
                vm.expectRevert(NewTradeV2VaultV2.InvalidDestination.selector);
                custody.beginRelease(id, ReleaseMode(m), refused[i], buyer);
                vm.prank(address(escrow));
                vm.expectRevert(NewTradeV2VaultV2.InvalidDestination.selector);
                custody.beginRelease(id, ReleaseMode(m), buyer, refused[i]);
            }
        }
        (, NewTradeV2VaultStorage.ReleaseRecord memory r,) = custody.bundleStatus(id);
        assertFalse(r.initialized);
    }

    /// A token needing more than its batch budget stays held in a batch and leaves in
    /// single mode, including after a third party turns a two-bit retry into one bit.
    function test_HeavyTokenLeavesInSingleModeAfterBatchToSingleTransition() public {
        ProbeERC20 heavy = new ProbeERC20();
        ToggleReleaseFailureERC20 t = new ToggleReleaseFailureERC20();
        escrow.setAssetKind(address(heavy), AssetKind.ERC20, true);
        escrow.setAssetKind(address(t), AssetKind.ERC20, true);
        heavy.mint(seller, 5);
        t.mint(seller, 5);
        vm.startPrank(seller);
        heavy.approve(address(custody), type(uint256).max);
        t.approve(address(custody), type(uint256).max);
        vm.stopPrank();
        (address a, address b) =
            address(heavy) < address(t) ? (address(heavy), address(t)) : (address(t), address(heavy));
        uint256 heavyBit = a == address(heavy) ? 1 : 2;
        uint256 tBit = 3 - heavyBit;
        ManifestEntry[] memory es = new ManifestEntry[](2);
        es[0] = ManifestEntry(AssetKind.ERC20, a, 0, 5);
        es[1] = ManifestEntry(AssetKind.ERC20, b, 0, 5);
        vm.prank(seller);
        uint256 id = escrow.deposit(address(control), 1, es, deadline);
        heavy.arm(address(custody), false, 1_000_000);
        t.setFailRelease(true);
        vm.warp(deadline);
        assertTrue(_call(seller, abi.encodeCall(NewTradeEscrowV2.reclaim, (id, extrasDest)), 5_000_000));
        (,, uint256 held) = custody.bundleStatus(id);
        assertEq(held, 3, "both held: over budget, and failing");

        // Batch retry naming both: the heavy token cannot leave on its budget.
        t.setFailRelease(false);
        uint256 s = vm.snapshotState();
        t.setFailRelease(true);
        assertTrue(_call(holderC, abi.encodeCall(NewTradeEscrowV2.withdrawRemaining, (id, 3, "")), 5_000_000));
        (,, held) = custody.bundleStatus(id);
        assertEq(held, 3);
        vm.revertToState(s);

        // A third party releases the other bit first: the same two-bit mask is now single mode.
        assertTrue(_call(holderC, abi.encodeCall(NewTradeEscrowV2.withdrawRemaining, (id, tBit, "")), 1_000_000));
        (,, held) = custody.bundleStatus(id);
        assertEq(held, heavyBit);
        assertTrue(_call(holderC, abi.encodeCall(NewTradeEscrowV2.withdrawRemaining, (id, 3, "")), 3_000_000));
        assertEq(heavy.balanceOf(extrasDest), 5);
        assertEq(uint8(escrow.getBundle(id).state), uint8(BundleState.Reclaimed));
    }

    // ------------------------------------------------------------ the largest bundle

    uint256 constant EXTRA_BURN_NFT = 300_000;
    uint256 constant EXTRA_BURN_20 = 130_000;
    uint256 constant GAS_CEILING = 60_000_000;

    function _sorted(GasProbe[] memory ps) internal pure {
        for (uint256 i = 1; i < ps.length; ++i) {
            GasProbe x = ps[i];
            uint256 j = i;
            for (; j > 0 && address(ps[j - 1]) > address(x); --j) {
                ps[j] = ps[j - 1];
            }
            ps[j] = x;
        }
    }

    /// 32 entries, each its own cold token contract, plus a controlling NFT of its own.
    function _largest(bool nfts)
        internal
        returns (uint256 id, GasProbe[] memory ps, ProbeERC721 nft, uint256 depositGas)
    {
        for (uint256 i; i < 3; ++i) {
            escrow.setAssetAcceptanceMode(AssetKind(i), AcceptanceMode.Wildcard);
        }
        ps = new GasProbe[](32);
        for (uint256 i; i < 32; ++i) {
            if (nfts) {
                ProbeERC721 p = new ProbeERC721();
                p.mint(seller, 1);
                vm.prank(seller);
                p.setApprovalForAll(address(custody), true);
                ps[i] = p;
            } else {
                ProbeERC20 p = new ProbeERC20();
                p.mint(seller, 1);
                vm.prank(seller);
                p.approve(address(custody), type(uint256).max);
                ps[i] = p;
            }
        }
        _sorted(ps);
        nft = new ProbeERC721();
        nft.mint(seller, 1);
        vm.prank(seller);
        nft.setApprovalForAll(address(custody), true);
        ManifestEntry[] memory es = new ManifestEntry[](32);
        for (uint256 i; i < 32; ++i) {
            es[i] = nfts
                ? ManifestEntry(AssetKind.ERC721, address(ps[i]), 1, 1)
                : ManifestEntry(AssetKind.ERC20, address(ps[i]), 0, 1);
        }
        vm.prank(seller);
        (bool ok, bytes memory ret) = address(escrow).call{gas: GAS_CEILING}(
            abi.encodeCall(NewTradeEscrowV2.deposit, (address(nft), 1, es, deadline))
        );
        assertTrue(ok, "deposit of the largest bundle");
        depositGas = vm.lastCallGas().gasTotalUsed;
        id = abi.decode(ret, (uint256));
    }

    function _arm(GasProbe[] memory ps, uint256 burn) internal {
        for (uint256 i; i < ps.length; ++i) {
            ps[i].arm(address(custody), false, burn);
        }
    }

    function _reportMax(string memory name, bytes memory cd, address from, BundleState wanted) internal {
        uint256 g = _minOk(from, cd, GAS_CEILING);
        assertTrue(_call(from, cd, g), name);
        uint256 used = vm.lastCallGas().gasTotalUsed;
        console2.log(name);
        console2.log("  min gas limit that succeeds", g);
        console2.log("  gas actually used at that limit", used);
        assertEq(uint8(escrow.getBundle(abi.decode(_slice(cd), (uint256))).state), uint8(wanted), name);
    }

    function _slice(bytes memory cd) internal pure returns (bytes memory out) {
        out = new bytes(32);
        for (uint256 i; i < 32; ++i) {
            out[i] = cd[i + 4];
        }
    }

    function test_Max_33BudgetBurners_Reclaim() public {
        (uint256 id, GasProbe[] memory ps, ProbeERC721 nft, uint256 dg) = _largest(true);
        console2.log("deposit of 32 distinct ERC-721 + NFT, gas used", dg);
        _arm(ps, type(uint256).max);
        nft.arm(address(custody), false, type(uint256).max);
        vm.warp(deadline);
        _reportMax(
            "reclaim: 33 attempts, every one burns its budget (400k each)",
            abi.encodeCall(NewTradeEscrowV2.reclaim, (id, extrasDest)),
            seller,
            BundleState.Reclaiming
        );
    }

    function test_Max_32Erc20BurnersPlusNft_Reclaim() public {
        (uint256 id, GasProbe[] memory ps, ProbeERC721 nft, uint256 dg) = _largest(false);
        console2.log("deposit of 32 distinct ERC-20 + NFT, gas used", dg);
        _arm(ps, type(uint256).max);
        nft.arm(address(custody), false, type(uint256).max);
        vm.warp(deadline);
        _reportMax(
            "reclaim: 32 ERC-20 burners (200k each) + NFT burner (400k)",
            abi.encodeCall(NewTradeEscrowV2.reclaim, (id, extrasDest)),
            seller,
            BundleState.Reclaiming
        );
    }

    function test_Max_33ExpensiveSuccesses_ReclaimCloses() public {
        (uint256 id, GasProbe[] memory ps, ProbeERC721 nft,) = _largest(true);
        _arm(ps, EXTRA_BURN_NFT);
        nft.arm(address(custody), false, EXTRA_BURN_NFT);
        vm.warp(deadline);
        _reportMax(
            "reclaim: 33 successful expensive transfers (300k extra burn each), closes",
            abi.encodeCall(NewTradeEscrowV2.reclaim, (id, extrasDest)),
            seller,
            BundleState.Reclaimed
        );
    }

    function test_Max_33ExpensiveSuccesses_RedeemCloses() public {
        (uint256 id, GasProbe[] memory ps, ProbeERC721 nft,) = _largest(true);
        issue(id, buyer);
        _arm(ps, EXTRA_BURN_NFT);
        nft.arm(address(custody), false, EXTRA_BURN_NFT);
        _reportMax(
            "redeem: fresh account + 33 successful expensive transfers, closes",
            abi.encodeCall(NewTradeEscrowV2.redeemToFreshAccount, (id, keccak256("max"))),
            buyer,
            BundleState.Redeemed
        );
    }

    function test_Max_NftThen32BudgetBurners_Redeem() public {
        (uint256 id, GasProbe[] memory ps, ProbeERC721 nft,) = _largest(true);
        issue(id, buyer);
        _arm(ps, type(uint256).max);
        nft.arm(address(custody), false, EXTRA_BURN_NFT);
        _reportMax(
            "redeem: fresh account, NFT expensive success, 32 budget burners",
            abi.encodeCall(NewTradeEscrowV2.redeemToFreshAccount, (id, keccak256("max"))),
            buyer,
            BundleState.Redeeming
        );
    }
}
