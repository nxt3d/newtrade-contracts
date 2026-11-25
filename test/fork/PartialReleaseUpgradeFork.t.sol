// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {NewTradeEscrowV2} from "../../src/NewTradeEscrowV2.sol";
import {NewTradeV2VaultV2} from "../../src/NewTradeV2VaultV2.sol";
import {NewTradeV2VaultStorage} from "../../src/NewTradeV2VaultStorage.sol";
import {
    AcceptanceMode, AssetKind, BundleState, ManifestEntry, Payout, ReleaseMode
} from "../../src/NewTradeV2Types.sol";
import {ISeaport, Order, OrderParameters} from "../../src/interfaces/ISeaport.sol";
import {IERC6551Registry, ITokenboundAccountProxy} from "../../src/interfaces/IERC6551.sol";
import {ToggleReleaseFailureERC20} from "../helpers/ERC6551Mocks.sol";
import {MockERC1155} from "../mocks/TokenMocks.sol";
// Compiled for deployCode("RoyaltyTestNFT.sol:RoyaltyTestNFT"): a filtered `forge test` builds only the import graph.
import {RoyaltyTestNFT} from "../legacy/RoyaltyTestNFT.sol";

interface IStrictRegistryArmF01 {
    function beforeAuthorizedTransfer(address token, uint256 tokenId) external;
}

interface IRoyaltyTestNFTF01 {
    function mint(address to, uint256 tokenId) external;
}

interface IOldVaultF01 {
    function assetAcceptanceMode(AssetKind kind) external view returns (AcceptanceMode);
    function migrationIsEnabled() external view returns (bool);
    function erc20Liability(address token) external view returns (uint256);
}

contract F01ZoneStub {
    fallback() external {
        assembly ("memory-safe") {
            mstore(0, shl(224, shr(224, calldataload(0))))
            return(0, 32)
        }
    }
}

/**
 * F-01 partial release: the EXACT upgrade sequence of the unsigned package,
 * rehearsed on a Base fork by the live upgrader 0xF8e0 (IMPERSONATED; nothing
 * is broadcast), then redemption, reclaim and withdrawRemaining through the
 * upgraded proxy with a REAL Seaport fill and the real Tokenbound account.
 *
 * Two ways to run it:
 *
 *  - against a Base RPC, pinned at block 60,187,703 (`--fork-url <rpc>`): the
 *    test performs the package's ordered calls itself. The vault implementation
 *    is the build artifact as forge links it, so the two library ADDRESSES in
 *    its bytecode are forge's, not the ones the package deploys;
 *  - against the local anvil rehearsal (`F01_REHEARSED=1 --fork-url
 *    http://127.0.0.1:8545`), where the package's own commands have already
 *    run from 0xF8e0 with the libraries linked at their real addresses. The
 *    upgrade is then NOT repeated: the tests exercise the state the package
 *    left behind.
 *
 * Sequence (BUILD-PLAN section 3, decision D1; no migrator, no old-vault
 * fallback, bundle #3 is not reclaimed):
 *   deploy VaultAdmission, VaultCustodyIn, the vault implementation, the vault
 *   proxy (initialize: escrow proxy, claim collection, all three modes
 *   Disabled), the escrow implementation; freeze listings; ONE
 *   upgradeToAndCall(escrowImpl, initializeVault(vaultProxy)); post-check;
 *   ACTIVATE: three acceptance modes to Wildcard (D6) and setMigrationEnabled
 *   (the old vault has it on; a fresh vault has it off); unfreeze listings.
 */
contract PartialReleaseUpgradeForkTest is Test {
    uint256 constant PINNED_FORK_BLOCK = 60_187_703;

    address constant PROXY = 0xCc29F5c82C8b7c01Cac6036047E7413Df458f86d;
    address constant LIVE_IMPL = 0x0c2e731755A069423CDD779CFDEc6146B2D9ba8a;
    address constant OLD_VAULT = 0xF39e70134782D7b27d4DBA01a0b98B1D69E49B12;
    address constant BUNDLE = 0x59900b207ea703B0bBcF8fD84C5E11dE46826185;
    address constant ADMIN = 0xF8e03bd4436371E0e2F7C02E529b2172fe72b4EF;
    address constant C3F9 = 0xc3F96C409d26272fDB592c0d04e1D771A7df032e;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant SEAPORT = 0x0000000000000068F116a894984e2DB1123eB395;
    address constant VALIDATOR = 0xA000027A9B2802E1ddf7000061001e5c005A0000;
    address constant SIGNED_ZONE = 0x000056F7000000EcE9003ca63978907a00FFD100;
    address constant OPENSEA_FEE = 0x0000a26b00c1F0DF003000390027140000fAa719;
    bytes32 constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    /// OpenZeppelin Initializable's ERC-7201 slot: the low 8 bytes are the version.
    bytes32 constant INITIALIZABLE_SLOT = 0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;
    /// `_vault` in NewTradeEscrowV2Storage (test/layout/escrow-baseline-86bbb204.json).
    uint256 constant VAULT_SLOT = 6;
    uint256 constant SEQUENTIAL_SLOTS = 64;
    uint256 constant NFT_BIT = 1 << 32;
    uint256 constant TX_CAP = 16_777_216;
    uint256 constant P = 1 ether;
    uint256 constant BUNDLE_3 = 3;

    NewTradeEscrowV2 escrow = NewTradeEscrowV2(payable(PROXY));
    NewTradeV2VaultV2 vault;
    address escrowImpl;
    address vaultImpl;
    bool forked;
    /// True when the package already ran on this chain (the anvil rehearsal).
    bool rehearsed;
    uint256 nonceTag;

    address seller = address(0x5E11E0B);
    address buyer = address(0xB0B0B0B);
    address stranger = address(0x5757);
    address elsewhere = address(0xE15E);

    function setUp() public {
        forked = PROXY.code.length > 0 && SEAPORT.code.length > 0;
        if (!forked) return;
        rehearsed = vm.envOr("F01_REHEARSED", false);
        if (rehearsed) {
            vault = NewTradeV2VaultV2(escrow.vault());
            require(address(vault) != OLD_VAULT, "F01_REHEARSED is set but the escrow still points at the old vault");
            escrowImpl = _impl();
            vaultImpl = vault.implementation();
        } else {
            vm.rollFork(PINNED_FORK_BLOCK);
        }
    }

    modifier onlyFork() {
        if (!forked) {
            vm.skip(true);
            return;
        }
        _;
    }

    /// Tests about the pre-upgrade chain and the sequence itself cannot run on a chain where it already ran.
    modifier notRehearsed() {
        if (!forked || rehearsed) {
            vm.skip(true);
            return;
        }
        _;
    }

    // ------------------------------------------------------------------ the package

    function _impl() internal view returns (address) {
        return address(uint160(uint256(vm.load(PROXY, IMPLEMENTATION_SLOT))));
    }

    function _paymentTokens() internal pure returns (address[3] memory) {
        return [address(0), WETH, USDC];
    }

    function _setListing(bool open) internal {
        address[3] memory t = _paymentTokens();
        for (uint256 i; i < 3; ++i) {
            vm.prank(ADMIN);
            escrow.setPaymentTokenAllowed(t[i], open);
        }
    }

    /// Steps D1..D5: the five deployments. Nothing on the live proxy changes.
    function _deploy() internal {
        vm.startPrank(ADMIN);
        vaultImpl = address(new NewTradeV2VaultV2());
        AcceptanceMode[3] memory disabled;
        vault = NewTradeV2VaultV2(
            address(new ERC1967Proxy(vaultImpl, abi.encodeCall(NewTradeV2VaultV2.initialize, (PROXY, BUNDLE, disabled))))
        );
        escrowImpl = address(new NewTradeEscrowV2());
        vm.stopPrank();
    }

    /// Steps C1..C3: close deposits on the OLD vault (the escrow still points at it), so nothing
    /// can be deposited into the vault that S leaves behind.
    function _closeOldVault() internal {
        vm.startPrank(ADMIN);
        for (uint8 k; k < 3; ++k) escrow.setAssetAcceptanceMode(AssetKind(k), AcceptanceMode.Disabled);
        vm.stopPrank();
    }

    /// Step S: the one switch transaction.
    function _switch() internal {
        vm.prank(ADMIN);
        escrow.upgradeToAndCall(escrowImpl, abi.encodeCall(NewTradeEscrowV2.initializeVault, (address(vault))));
    }

    /// Steps A1..A4: activation. Until these, nothing can enter the new vault.
    function _activate() internal {
        vm.startPrank(ADMIN);
        escrow.setAssetAcceptanceMode(AssetKind.ERC20, AcceptanceMode.Wildcard);
        escrow.setAssetAcceptanceMode(AssetKind.ERC721, AcceptanceMode.Wildcard);
        escrow.setAssetAcceptanceMode(AssetKind.ERC1155, AcceptanceMode.Wildcard);
        escrow.setMigrationEnabled(true);
        vm.stopPrank();
    }

    /// The whole package, in order. A no-op on the rehearsed chain.
    function _runPackage() internal {
        if (rehearsed) return;
        _deploy();
        _setListing(false);
        _closeOldVault();
        _switch();
        _activate();
        _setListing(true);
    }

    // ------------------------------------------------------------------ helpers

    function _policy() internal view returns (address registry, address logic, address accountProxy) {
        registry = address(uint160(uint256(vm.load(PROXY, bytes32(uint256(8))))));
        logic = address(uint160(uint256(vm.load(PROXY, bytes32(uint256(9))))));
        accountProxy = address(uint160(uint256(vm.load(PROXY, bytes32(uint256(12))))));
    }

    function _armAndStub(uint256 id) internal {
        vm.prank(SIGNED_ZONE);
        IStrictRegistryArmF01(VALIDATOR).beforeAuthorizedTransfer(BUNDLE, id);
        vm.etch(SIGNED_ZONE, address(new F01ZoneStub()).code);
    }

    function _fill(uint256 id, uint256 price) internal {
        (OrderParameters memory p,,,,) = escrow.getOrder(id);
        vm.deal(buyer, price);
        vm.prank(buyer);
        assertTrue(ISeaport(SEAPORT).fulfillOrder{value: price}(Order(p, ""), bytes32(0)));
    }

    function _newNft() internal returns (address nft) {
        nft = deployCode("RoyaltyTestNFT.sol:RoyaltyTestNFT", abi.encode(C3F9, uint96(250)));
        IRoyaltyTestNFTF01(nft).mint(seller, 1);
    }

    /// A bundle deposited from the NFT's own Tokenbound account: 10 USDC plus, optionally, a token that can be made to refuse.
    function _depositFromAccount(ToggleReleaseFailureERC20 toggle)
        internal
        returns (uint256 id, address nft, uint64 deadline)
    {
        nft = _newNft();
        (address registry, address logic, address accountProxy) = _policy();
        address account = IERC6551Registry(registry).createAccount(accountProxy, bytes32(0), block.chainid, nft, 1);
        ITokenboundAccountProxy(account).initialize(logic);
        deal(USDC, account, 10);
        ManifestEntry[] memory manifest = new ManifestEntry[](address(toggle) == address(0) ? 1 : 2);
        // Manifest order is by kind, then token address ascending.
        if (address(toggle) == address(0)) {
            manifest[0] = ManifestEntry(AssetKind.ERC20, USDC, 0, 10);
        } else {
            toggle.mint(account, 7);
            bool usdcFirst = uint160(USDC) < uint160(address(toggle));
            manifest[usdcFirst ? 0 : 1] = ManifestEntry(AssetKind.ERC20, USDC, 0, 10);
            manifest[usdcFirst ? 1 : 0] = ManifestEntry(AssetKind.ERC20, address(toggle), 0, 7);
        }
        deadline = uint64(block.timestamp + 14 days);
        vm.startPrank(seller);
        IERC721(nft).approve(address(vault), 1);
        id = escrow.depositFromAccount(account, nft, 1, manifest, deadline, keccak256(abi.encode("f01", nonceTag++)));
        vm.stopPrank();
    }

    function _toggleBit(ToggleReleaseFailureERC20 toggle) internal pure returns (uint256) {
        return uint160(USDC) < uint160(address(toggle)) ? 2 : 1;
    }

    function _listAndFill(uint256 id, uint64 deadline) internal {
        Payout[] memory ps = new Payout[](2);
        ps[0] = Payout(payable(PROXY), 0.99 ether);
        ps[1] = Payout(payable(OPENSEA_FEE), 0.01 ether);
        vm.prank(seller);
        escrow.list(id, address(0), P, deadline, 250, ps);
        _armAndStub(id);
        _fill(id, P);
        assertEq(uint8(escrow.getBundle(id).state), uint8(BundleState.Issued));
        assertEq(IERC721(BUNDLE).ownerOf(id), buyer);
    }

    function _held(uint256 id) internal view returns (uint256 held) {
        (,, held) = vault.bundleStatus(id);
    }

    function _sequential() internal view returns (bytes32[] memory slots) {
        slots = new bytes32[](SEQUENTIAL_SLOTS);
        for (uint256 i; i < SEQUENTIAL_SLOTS; ++i) slots[i] = vm.load(PROXY, bytes32(i));
    }

    function _bundlesDigest() internal view returns (bytes32 h) {
        uint256 n = uint256(vm.load(PROXY, bytes32(uint256(3))));
        for (uint256 id = 1; id <= n; ++id) {
            h = keccak256(
                abi.encode(h, escrow.getBundle(id), escrow.getPayouts(id), escrow.getRoyaltySnapshot(id), escrow.getManifest(id))
            );
        }
    }

    // =================================================================== the chain before

    function test_Preconditions_TheLiveProxyAtThePinnedBlock() public notRehearsed {
        assertEq(block.number, PINNED_FORK_BLOCK);
        assertEq(block.chainid, 8453);
        assertEq(_impl(), LIVE_IMPL, "the live implementation is option B, the rollback target");
        assertEq(escrow.vault(), OLD_VAULT);
        assertEq(escrow.receipt(), BUNDLE);
        assertTrue(escrow.hasRole(escrow.UPGRADER_ROLE(), ADMIN));
        assertTrue(escrow.hasRole(escrow.DEFAULT_ADMIN_ROLE(), ADMIN));
        assertEq(uint64(uint256(vm.load(PROXY, INITIALIZABLE_SLOT))), 2, "reinitializer(3) is the next version");
        assertEq(address(uint160(uint256(vm.load(PROXY, bytes32(VAULT_SLOT))))), OLD_VAULT, "_vault is slot 6");
        // The policy the activation steps must reproduce on the new vault.
        for (uint8 k; k < 3; ++k) {
            assertEq(uint8(IOldVaultF01(OLD_VAULT).assetAcceptanceMode(AssetKind(k))), uint8(AcceptanceMode.Wildcard));
        }
        assertTrue(IOldVaultF01(OLD_VAULT).migrationIsEnabled(), "deposits from an account are open today");
        address[3] memory t = _paymentTokens();
        for (uint256 i; i < 3; ++i) assertTrue(escrow.isPaymentTokenAllowed(t[i]));
        // Six bundles; only #3 is open, and its listing has expired with its custody deadline.
        assertEq(uint256(vm.load(PROXY, bytes32(uint256(3)))), 6);
        for (uint256 id = 1; id <= 6; ++id) {
            BundleState s = escrow.getBundle(id).state;
            if (id == BUNDLE_3) assertEq(uint8(s), uint8(BundleState.Listed));
            else assertTrue(s == BundleState.Redeemed || s == BundleState.Reclaimed, "every other bundle is closed");
        }
        assertLt(escrow.getBundle(BUNDLE_3).custodyDeadline, block.timestamp, "#3 is past its deadline");
        assertGe(PROXY.balance, escrow.totalOwed(address(0)), "the ledger is backed");
    }

    // =================================================================== the sequence

    function test_Package_ExactSequence_WiringStorageAndLedgerVerified() public notRehearsed {
        bytes32[] memory before = _sequential();
        bytes32 bundlesBefore = _bundlesDigest();
        uint256 owedEth = escrow.totalOwed(address(0));
        uint256 owedUsdc = escrow.totalOwed(USDC);
        uint256 balance = PROXY.balance;
        uint256 oldVaultUsdc = IERC20(USDC).balanceOf(OLD_VAULT);

        // D: deployments change nothing on the proxy.
        _deploy();
        assertEq(_impl(), LIVE_IMPL);
        assertEq(escrow.vault(), OLD_VAULT);
        // The new vault's wiring, checked BEFORE the switch (the escrow does not check it on chain: BUILD-PLAN section 1).
        assertEq(vault.controller(), PROXY, "controller is the escrow proxy");
        assertEq(vault.receipt(), BUNDLE, "claim collection");
        assertEq(vault.implementation(), vaultImpl);
        assertEq(address(uint160(uint256(vm.load(address(vault), IMPLEMENTATION_SLOT)))), vaultImpl);
        assertEq(vault.VAULT_FAMILY(), keccak256("newtrade.v2.vault"));
        for (uint8 k; k < 3; ++k) assertEq(uint8(vault.assetAcceptanceMode(AssetKind(k))), uint8(AcceptanceMode.Disabled));
        // The implementations cannot be initialized directly.
        AcceptanceMode[3] memory disabled;
        vm.expectRevert();
        NewTradeV2VaultV2(vaultImpl).initialize(PROXY, BUNDLE, disabled);
        vm.expectRevert();
        NewTradeEscrowV2(payable(escrowImpl)).initializeVault(address(vault));
        // Nobody but the upgrader can switch.
        vm.prank(stranger);
        vm.expectRevert();
        escrow.upgradeToAndCall(escrowImpl, abi.encodeCall(NewTradeEscrowV2.initializeVault, (address(vault))));

        // F: freeze listings.
        _setListing(false);
        address[3] memory t = _paymentTokens();
        for (uint256 i; i < 3; ++i) assertFalse(escrow.isPaymentTokenAllowed(t[i]));

        // C: close deposits on the old vault. From here to activation nothing can be deposited anywhere.
        _closeOldVault();
        for (uint8 k; k < 3; ++k) {
            assertEq(uint8(IOldVaultF01(OLD_VAULT).assetAcceptanceMode(AssetKind(k))), uint8(AcceptanceMode.Disabled));
        }
        {
            address early = _newNft();
            ManifestEntry[] memory empty = new ManifestEntry[](0);
            vm.startPrank(seller);
            IERC721(early).approve(OLD_VAULT, 1);
            vm.expectRevert();
            escrow.deposit(early, 1, empty, uint64(block.timestamp + 14 days));
            vm.stopPrank();
        }

        // S: the switch.
        uint256 g = gasleft();
        _switch();
        console2.log("upgradeToAndCall gas", g - gasleft());

        // Post-check: wiring.
        assertEq(_impl(), escrowImpl, "the proxy runs the new implementation");
        assertEq(escrow.vault(), address(vault), "the escrow uses the new vault");
        assertEq(uint64(uint256(vm.load(PROXY, INITIALIZABLE_SLOT))), 3, "initializer version 3");
        // Post-check: storage. Every sequential slot is identical except `_vault`.
        bytes32[] memory afterSlots = _sequential();
        for (uint256 i; i < SEQUENTIAL_SLOTS; ++i) {
            if (i == VAULT_SLOT) {
                assertEq(address(uint160(uint256(afterSlots[i]))), address(vault));
                continue;
            }
            // Slot 2 is the payment-token mapping's own slot (always zero); the freeze writes hashed keys, not slot 2.
            assertEq(afterSlots[i], before[i], "a sequential slot other than _vault changed");
        }
        // Post-check: every bundle, payout, snapshot and manifest reads the same... except that
        // manifests now come from the NEW vault, which has none for old bundles (D1: no fallback).
        assertEq(escrow.totalOwed(address(0)), owedEth, "totalOwed(ETH) unchanged");
        assertEq(escrow.totalOwed(USDC), owedUsdc);
        assertEq(PROXY.balance, balance);
        assertEq(uint256(vm.load(PROXY, bytes32(uint256(3)))), 6, "_counter unchanged");
        assertTrue(escrow.hasRole(escrow.UPGRADER_ROLE(), ADMIN));
        assertTrue(escrow.hasRole(escrow.DEFAULT_ADMIN_ROLE(), ADMIN));
        assertEq(escrow.receipt(), BUNDLE);
        // The old vault is untouched and still holds #3's 10 USDC.
        assertEq(IERC20(USDC).balanceOf(OLD_VAULT), oldVaultUsdc);
        // The switch cannot be run twice.
        vm.prank(ADMIN);
        vm.expectRevert();
        escrow.initializeVault(address(vault));

        // Between the switch and activation NOTHING can enter the new vault.
        address nft = _newNft();
        ManifestEntry[] memory none = new ManifestEntry[](0);
        vm.startPrank(seller);
        IERC721(nft).approve(address(vault), 1);
        vm.expectRevert();
        escrow.deposit(nft, 1, none, uint64(block.timestamp + 14 days));
        vm.stopPrank();

        // A: activation, then unfreeze.
        _activate();
        for (uint8 k; k < 3; ++k) assertEq(uint8(vault.assetAcceptanceMode(AssetKind(k))), uint8(AcceptanceMode.Wildcard));
        _setListing(true);
        for (uint256 i; i < 3; ++i) assertTrue(escrow.isPaymentTokenAllowed(t[i]));
        vm.prank(seller);
        uint256 id = escrow.deposit(nft, 1, none, uint64(block.timestamp + 14 days));
        assertEq(id, 7, "the first bundle of the new vault");
        assertEq(IERC721(nft).ownerOf(1), address(vault));
        bundlesBefore; // silence: digests of old bundles are compared field by field in the next test
    }

    // ------------------------------------------------------------------ the operator's timing table

    /// One ordinary deposit attempt of the given manifest shape; true when it is admitted.
    /// `shape`: 0 = NFT only, 1 = one ERC-20 entry, 2 = one ERC-1155 entry.
    function _tryDeposit(address targetVault, uint8 shape) internal returns (bool ok) {
        address nft = _newNft();
        ManifestEntry[] memory m = new ManifestEntry[](shape == 0 ? 0 : 1);
        vm.startPrank(seller);
        IERC721(nft).approve(targetVault, 1);
        if (shape == 1) {
            deal(USDC, seller, 10);
            IERC20(USDC).approve(targetVault, 10);
            m[0] = ManifestEntry(AssetKind.ERC20, USDC, 0, 10);
        } else if (shape == 2) {
            erc1155.mint(seller, 1, 3);
            erc1155.setApprovalForAll(targetVault, true);
            m[0] = ManifestEntry(AssetKind.ERC1155, address(erc1155), 1, 3);
        }
        (ok,) = PROXY.call(abi.encodeCall(NewTradeEscrowV2.deposit, (nft, 1, m, uint64(block.timestamp + 14 days))));
        vm.stopPrank();
    }

    /// One deposit-from-account attempt (10 USDC in the NFT's Tokenbound account); true when admitted.
    function _tryAccountDeposit(address targetVault) internal returns (bool ok) {
        address nft = _newNft();
        (address registry, address logic, address accountProxy) = _policy();
        address account = IERC6551Registry(registry).createAccount(accountProxy, bytes32(0), block.chainid, nft, 1);
        ITokenboundAccountProxy(account).initialize(logic);
        deal(USDC, account, 10);
        ManifestEntry[] memory m = new ManifestEntry[](1);
        m[0] = ManifestEntry(AssetKind.ERC20, USDC, 0, 10);
        vm.startPrank(seller);
        IERC721(nft).approve(targetVault, 1);
        (ok,) = PROXY.call(
            abi.encodeCall(NewTradeEscrowV2.depositFromAccount, (account, nft, 1, m, uint64(block.timestamp + 14 days), keccak256(abi.encode("window", nonceTag++))))
        );
        vm.stopPrank();
    }

    function _listable(address token) internal view returns (bool) {
        return escrow.isPaymentTokenAllowed(token);
    }

    MockERC1155 erc1155;

    /// EVERY PARTIAL WINDOW of the operator timing table (op, f01-operator-timing-table), call by
    /// call. Each probe is made on a snapshot and reverted, so a probe that succeeds never becomes
    /// a bundle in the vault being left behind and never moves the next probe's starting state.
    function test_Package_TimingTable_EveryPartialWindow_CallByCall() public notRehearsed {
        erc1155 = new MockERC1155();
        _deploy();
        // start: everything open on the old vault.
        _assertWindow("start", OLD_VAULT, true, true, true, true);

        // F1, F2, F3: listing freezes one token at a time; deposits are untouched.
        address[3] memory t = _paymentTokens();
        for (uint256 i; i < 3; ++i) {
            vm.prank(ADMIN);
            escrow.setPaymentTokenAllowed(t[i], false);
            for (uint256 j; j < 3; ++j) assertEq(_listable(t[j]), j > i, "listing freezes token by token");
        }
        _assertWindow("after F3", OLD_VAULT, true, true, true, true);

        // C1 (ERC20 Disabled, old): only ERC-20-bearing deposits close.
        vm.prank(ADMIN);
        escrow.setAssetAcceptanceMode(AssetKind.ERC20, AcceptanceMode.Disabled);
        _assertWindow("after C1", OLD_VAULT, true, false, true, false);
        // C2 (ERC721 Disabled, old): everything closes, because the controlling NFT itself is ERC721.
        vm.prank(ADMIN);
        escrow.setAssetAcceptanceMode(AssetKind.ERC721, AcceptanceMode.Disabled);
        _assertWindow("after C2", OLD_VAULT, false, false, false, false);
        // C3 closes nothing new.
        vm.prank(ADMIN);
        escrow.setAssetAcceptanceMode(AssetKind.ERC1155, AcceptanceMode.Disabled);
        _assertWindow("after C3", OLD_VAULT, false, false, false, false);

        // S: the new vault, all Disabled, migration off.
        _switch();
        _assertWindow("after S", address(vault), false, false, false, false);
        // A1 (ERC20 Wildcard, new) alone opens nothing.
        vm.prank(ADMIN);
        escrow.setAssetAcceptanceMode(AssetKind.ERC20, AcceptanceMode.Wildcard);
        _assertWindow("after A1", address(vault), false, false, false, false);
        // A2 (ERC721 Wildcard, new): NFT-only and ERC-20 manifests open; ERC-1155 and account deposits do not.
        vm.prank(ADMIN);
        escrow.setAssetAcceptanceMode(AssetKind.ERC721, AcceptanceMode.Wildcard);
        _assertWindow("after A2", address(vault), true, true, false, false);
        // A3 (ERC1155 Wildcard, new): every ordinary deposit; account deposits still closed.
        vm.prank(ADMIN);
        escrow.setAssetAcceptanceMode(AssetKind.ERC1155, AcceptanceMode.Wildcard);
        _assertWindow("after A3", address(vault), true, true, true, false);
        // A4: account deposits open.
        vm.prank(ADMIN);
        escrow.setMigrationEnabled(true);
        _assertWindow("after A4", address(vault), true, true, true, true);

        // U1, U2, U3: listing reopens one token at a time.
        for (uint256 i; i < 3; ++i) {
            vm.prank(ADMIN);
            escrow.setPaymentTokenAllowed(t[i], true);
            for (uint256 j; j < 3; ++j) assertEq(_listable(t[j]), j <= i, "listing reopens token by token");
        }
    }

    function _assertWindow(string memory at, address targetVault, bool nftOnly, bool erc20, bool erc1155Entry, bool account) internal {
        assertEq(escrow.vault(), targetVault, at);
        uint256 s = vm.snapshotState();
        assertEq(_tryDeposit(targetVault, 0), nftOnly, string.concat(at, ": NFT-only deposit"));
        vm.revertToState(s);
        s = vm.snapshotState();
        assertEq(_tryDeposit(targetVault, 1), erc20, string.concat(at, ": deposit with an ERC-20 entry"));
        vm.revertToState(s);
        s = vm.snapshotState();
        assertEq(_tryDeposit(targetVault, 2), erc1155Entry, string.concat(at, ": deposit with an ERC-1155 entry"));
        vm.revertToState(s);
        s = vm.snapshotState();
        assertEq(_tryAccountDeposit(targetVault), account, string.concat(at, ": deposit from an account"));
        vm.revertToState(s);
    }

    function test_Package_OldBundlesKeepTheirRecords_AndAreNotReachable() public notRehearsed {
        bytes32[6] memory records;
        for (uint256 id = 1; id <= 6; ++id) {
            records[id - 1] = keccak256(abi.encode(escrow.getBundle(id), escrow.getPayouts(id), escrow.getRoyaltySnapshot(id)));
        }
        (OrderParameters memory order3,,,,) = escrow.getOrder(BUNDLE_3);
        bytes32 order3Hash = keccak256(abi.encode(order3));
        assertEq(escrow.getManifest(BUNDLE_3).length, 1, "before: #3's manifest reads from the old vault");
        _runPackage();
        // D1, no old-vault read fallback: `getManifest` is answered by the NEW vault, which has no
        // manifest for an old bundle. The escrow keeps the manifest HASH; the entries themselves are
        // readable only from the old vault directly.
        for (uint256 id = 1; id <= 6; ++id) assertEq(escrow.getManifest(id).length, 0, "old manifests read empty through the escrow");
        for (uint256 id = 1; id <= 6; ++id) {
            assertEq(
                keccak256(abi.encode(escrow.getBundle(id), escrow.getPayouts(id), escrow.getRoyaltySnapshot(id))),
                records[id - 1],
                "an old bundle's escrow record changed"
            );
        }
        (OrderParameters memory after3,,,,) = escrow.getOrder(BUNDLE_3);
        assertEq(keccak256(abi.encode(after3)), order3Hash, "getOrder(3) byte-identical");

        // D1: bundle #3 stays in the OLD vault. There is no migrator and no fallback, so the
        // seller's reclaim reverts WHOLE (the new vault has no custody for it) and nothing changes:
        // the claim is not burned and the 10 USDC stay where they were.
        address seller3 = escrow.getBundle(BUNDLE_3).seller;
        uint256 oldVaultUsdc = IERC20(USDC).balanceOf(OLD_VAULT);
        vm.prank(seller3);
        vm.expectRevert(NewTradeV2VaultV2.NoRelease.selector);
        escrow.reclaim(BUNDLE_3, seller3);
        assertEq(uint8(escrow.getBundle(BUNDLE_3).state), uint8(BundleState.Listed));
        assertEq(IERC721(BUNDLE).ownerOf(BUNDLE_3), PROXY, "claim #3 is still held by the escrow");
        assertEq(IERC20(USDC).balanceOf(OLD_VAULT), oldVaultUsdc);
        // Its order expired with its custody deadline, so nobody can buy an unredeemable claim.
        assertLt(order3.endTime, block.timestamp, "order #3 has expired");
        uint256 price3 = escrow.getBundle(BUNDLE_3).price;
        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        vm.expectRevert();
        ISeaport(SEAPORT).fulfillOrder{value: price3}(Order(order3, ""), bytes32(0));
        // The new vault knows nothing of the old bundles.
        for (uint256 id = 1; id <= 6; ++id) {
            (NewTradeV2VaultStorage.Custody memory c,, uint256 held) = vault.bundleStatus(id);
            assertFalse(c.exists);
            assertEq(held, 0);
        }
    }

    function test_Package_WithoutTheMigrationStep_DepositsFromAnAccountAreClosed() public notRehearsed {
        _deploy();
        _setListing(false);
        _switch();
        vm.startPrank(ADMIN);
        escrow.setAssetAcceptanceMode(AssetKind.ERC20, AcceptanceMode.Wildcard);
        escrow.setAssetAcceptanceMode(AssetKind.ERC721, AcceptanceMode.Wildcard);
        escrow.setAssetAcceptanceMode(AssetKind.ERC1155, AcceptanceMode.Wildcard);
        vm.stopPrank();
        _setListing(true);
        // The three modes alone leave `depositFromAccount` closed: a fresh vault starts with migration off.
        address nft = _newNft();
        (address registry, address logic, address accountProxy) = _policy();
        address account = IERC6551Registry(registry).createAccount(accountProxy, bytes32(0), block.chainid, nft, 1);
        ITokenboundAccountProxy(account).initialize(logic);
        deal(USDC, account, 10);
        ManifestEntry[] memory manifest = new ManifestEntry[](1);
        manifest[0] = ManifestEntry(AssetKind.ERC20, USDC, 0, 10);
        vm.startPrank(seller);
        IERC721(nft).approve(address(vault), 1);
        vm.expectRevert();
        escrow.depositFromAccount(account, nft, 1, manifest, uint64(block.timestamp + 14 days), keccak256("closed"));
        vm.stopPrank();
        vm.prank(ADMIN);
        escrow.setMigrationEnabled(true);
        vm.prank(seller);
        uint256 id = escrow.depositFromAccount(account, nft, 1, manifest, uint64(block.timestamp + 14 days), keccak256("open"));
        assertEq(IERC20(USDC).balanceOf(address(vault)), 10);
        assertEq(uint8(escrow.getBundle(id).state), uint8(BundleState.Deposited));
    }

    // =================================================================== exits through the upgraded proxy

    function test_Redeem_FullExit_RealSeaportFill_RealTokenboundAccount() public onlyFork {
        _runPackage();
        (uint256 id, address nft, uint64 deadline) = _depositFromAccount(ToggleReleaseFailureERC20(address(0)));
        _listAndFill(id, deadline);
        (address account,) = escrow.computeFreshAccount(id, buyer, keccak256("full"));
        bytes memory cd = abi.encodeCall(NewTradeEscrowV2.redeemToFreshAccount, (id, keccak256("full")));
        vm.prank(buyer);
        uint256 g = gasleft();
        (bool ok,) = PROXY.call(cd);
        uint256 used = g - gasleft();
        assertTrue(ok);
        console2.log("normal clean redemption gas (1 ERC-20 + NFT, fresh account)", used);
        assertLt(used, TX_CAP);
        assertEq(uint8(escrow.getBundle(id).state), uint8(BundleState.Redeemed), "closed in one transaction");
        assertEq(_held(id), 0);
        assertEq(IERC721(nft).ownerOf(1), buyer);
        assertEq(IERC20(USDC).balanceOf(account), 10);
        assertGt(account.code.length, 0);
        vm.expectRevert();
        IERC721(BUNDLE).ownerOf(id);
        // Nothing is left to withdraw.
        vm.prank(stranger);
        vm.expectRevert(NewTradeEscrowV2.InvalidState.selector);
        escrow.withdrawRemaining(id, 1, "");
    }

    function test_Redeem_PartialExit_ThenAnyoneWithdrawsTheRest() public onlyFork {
        _runPackage();
        ToggleReleaseFailureERC20 toggle = new ToggleReleaseFailureERC20();
        (uint256 id, address nft, uint64 deadline) = _depositFromAccount(toggle);
        uint256 bit = _toggleBit(toggle);
        _listAndFill(id, deadline);
        (address account,) = escrow.computeFreshAccount(id, buyer, keccak256("partial"));

        toggle.setFailRelease(true);
        vm.prank(buyer);
        escrow.redeemToFreshAccount(id, keccak256("partial"));
        assertEq(uint8(escrow.getBundle(id).state), uint8(BundleState.Redeeming), "the exit began; one asset is held");
        assertEq(_held(id), bit, "exactly the refusing token is held");
        assertEq(IERC721(nft).ownerOf(1), buyer, "the NFT left");
        assertEq(IERC20(USDC).balanceOf(account), 10, "the healthy entry left");
        assertEq(toggle.balanceOf(address(vault)), 7);
        vm.expectRevert();
        IERC721(BUNDLE).ownerOf(id); // the claim is burned at the start

        // Single mode: a retry while the token still refuses reverts whole and changes nothing.
        vm.prank(stranger);
        vm.expectRevert(NewTradeV2VaultV2.ReleaseFailed.selector);
        escrow.withdrawRemaining(id, bit, "");
        assertEq(_held(id), bit);
        // The NFT has left, so nobody may redirect a redemption any more.
        vm.prank(buyer);
        vm.expectRevert(NewTradeV2VaultV2.NotRedeemer.selector);
        escrow.withdrawRemaining(id, 0, abi.encode(uint8(1), buyer));

        toggle.setFailRelease(false);
        vm.prank(stranger);
        escrow.withdrawRemaining(id, bit, "");
        assertEq(uint8(escrow.getBundle(id).state), uint8(BundleState.Redeemed));
        assertEq(_held(id), 0);
        assertEq(toggle.balanceOf(account), 7, "to the recorded destination, not the caller");
        assertEq(toggle.balanceOf(stranger), 0);
    }

    function test_Reclaim_FullExit_AndProtocolDestinationsRefused() public onlyFork {
        _runPackage();
        (uint256 id, address nft, uint64 deadline) = _depositFromAccount(ToggleReleaseFailureERC20(address(0)));
        vm.warp(deadline);
        address[3] memory refused = [address(vault), PROXY, BUNDLE];
        for (uint256 i; i < 3; ++i) {
            vm.prank(seller);
            vm.expectRevert(NewTradeV2VaultV2.InvalidDestination.selector);
            escrow.reclaim(id, refused[i]);
        }
        assertEq(uint8(escrow.getBundle(id).state), uint8(BundleState.Deposited), "a refused destination changes nothing");
        bytes memory cd = abi.encodeCall(NewTradeEscrowV2.reclaim, (id, seller));
        vm.prank(seller);
        uint256 g = gasleft();
        (bool ok,) = PROXY.call(cd);
        uint256 used = g - gasleft();
        assertTrue(ok);
        console2.log("normal clean reclaim gas (1 ERC-20 + NFT)", used);
        assertEq(uint8(escrow.getBundle(id).state), uint8(BundleState.Reclaimed));
        assertEq(_held(id), 0);
        assertEq(IERC721(nft).ownerOf(1), seller);
        assertEq(IERC20(USDC).balanceOf(seller), 10);
    }

    function test_Reclaim_PartialExit_SellerRedirectsAfterTheNftLeft_ThenAnyoneWithdraws() public onlyFork {
        _runPackage();
        ToggleReleaseFailureERC20 toggle = new ToggleReleaseFailureERC20();
        (uint256 id, address nft, uint64 deadline) = _depositFromAccount(toggle);
        uint256 bit = _toggleBit(toggle);
        vm.warp(deadline);
        toggle.setFailRelease(true);
        vm.prank(seller);
        escrow.reclaim(id, seller);
        assertEq(uint8(escrow.getBundle(id).state), uint8(BundleState.Reclaiming));
        assertEq(_held(id), bit);
        assertEq(IERC721(nft).ownerOf(1), seller, "the NFT is home");
        assertEq(IERC20(USDC).balanceOf(seller), 10);

        // Only the seller may redirect, and not to a protocol contract.
        bytes memory cmd = abi.encode(uint8(1), elsewhere);
        vm.prank(stranger);
        vm.expectRevert(NewTradeV2VaultV2.NotRedeemer.selector);
        escrow.withdrawRemaining(id, 0, cmd);
        vm.prank(seller);
        vm.expectRevert(NewTradeV2VaultV2.NotRedeemer.selector);
        escrow.withdrawRemaining(id, 0, abi.encode(uint8(1), address(vault)));
        // The app's shape: the redirect alone, with a zero mask. It moves nothing.
        vm.prank(seller);
        escrow.withdrawRemaining(id, 0, cmd);
        (, NewTradeV2VaultStorage.ReleaseRecord memory r, uint256 held) = vault.bundleStatus(id);
        assertTrue(r.redirected);
        assertEq(r.extrasTo, elsewhere);
        assertEq(r.nftTo, seller);
        assertEq(uint8(r.mode), uint8(ReleaseMode.Reclaim));
        assertEq(held, bit);
        assertEq(uint8(escrow.getBundle(id).state), uint8(BundleState.Reclaiming));

        toggle.setFailRelease(false);
        vm.prank(stranger);
        escrow.withdrawRemaining(id, bit, "");
        assertEq(uint8(escrow.getBundle(id).state), uint8(BundleState.Reclaimed));
        assertEq(toggle.balanceOf(elsewhere), 7, "the redirected entry went to the new destination");
        assertEq(toggle.balanceOf(seller), 0);
        assertEq(IERC20(USDC).balanceOf(seller), 10, "a released entry is never re-sent");
    }

    /// THE HAZARD the two historical fork failures show (EscrowOptionBUpgradeFork
    /// test_RollbackCheck_PassesOnceTheOpenBListingIsReclaimed, FreshBetaSequenceFork
    /// test_BuyerRedemptionDeliversTheSeededAssetWhenTheZoneIsStubbed): the new escrow
    /// implementation on the OLD vault. Both tests upgrade with `upgradeToAndCall(impl, "")`
    /// and no vault switch, so every exit calls `beginRelease` on a vault that has no such
    /// function. The package never makes that state: S carries `initializeVault` in the SAME
    /// transaction. This pins what the state would be, and that it is recoverable.
    function test_Hazard_ABareUpgradeWithoutTheVaultSwitch_ExitsRevertWhole_AndTheSwitchStillRecovers() public notRehearsed {
        _deploy();
        _setListing(false);
        vm.prank(ADMIN);
        escrow.upgradeToAndCall(escrowImpl, ""); // NOT the package's call
        assertEq(_impl(), escrowImpl);
        assertEq(escrow.vault(), OLD_VAULT, "new code, old vault");
        // Exits revert whole: the claim is not burned and nothing moves.
        address seller3 = escrow.getBundle(BUNDLE_3).seller;
        vm.prank(seller3);
        vm.expectRevert();
        escrow.reclaim(BUNDLE_3, seller3);
        assertEq(uint8(escrow.getBundle(BUNDLE_3).state), uint8(BundleState.Listed));
        assertEq(IERC721(BUNDLE).ownerOf(BUNDLE_3), PROXY);
        // A deposit in that state would go INTO the old vault, which the switch then leaves behind.
        address nft = _newNft();
        ManifestEntry[] memory none = new ManifestEntry[](0);
        vm.startPrank(seller);
        IERC721(nft).approve(OLD_VAULT, 1);
        (bool deposited,) = PROXY.call(abi.encodeCall(NewTradeEscrowV2.deposit, (nft, 1, none, uint64(block.timestamp + 14 days))));
        vm.stopPrank();
        emit log_named_string("deposit into the OLD vault under the new code", deposited ? "SUCCEEDS (would be stranded by the switch)" : "reverts");
        // Recovery: the switch is still available, because version 3 was not consumed.
        vm.prank(ADMIN);
        escrow.upgradeToAndCall(escrowImpl, abi.encodeCall(NewTradeEscrowV2.initializeVault, (address(vault))));
        assertEq(escrow.vault(), address(vault));
        assertEq(uint64(uint256(vm.load(PROXY, INITIALIZABLE_SLOT))), 3);
    }

    function test_Rollback_IsPossibleOnlyBeforeCustodyEntersTheNewVault_AndLeavesTheVaultPointer() public notRehearsed {
        _deploy();
        _setListing(false);
        _switch();
        // Before activation the new vault is empty: the proxy can be put back on the option-B
        // implementation. `_vault` STAYS the new vault (the old implementation has no setter and
        // reads the same slot), so this alone does not restore the old vault.
        vm.prank(ADMIN);
        escrow.upgradeToAndCall(LIVE_IMPL, "");
        assertEq(_impl(), LIVE_IMPL);
        assertEq(escrow.vault(), address(vault), "the pointer is not restored by a rollback of the implementation");
        assertEq(uint64(uint256(vm.load(PROXY, INITIALIZABLE_SLOT))), 3, "version 3 stays consumed");
        // Going forward again cannot re-run initializeVault (version 3 is spent), so the switch
        // is repeated as a plain upgrade; the pointer is already the new vault.
        vm.prank(ADMIN);
        vm.expectRevert();
        escrow.upgradeToAndCall(escrowImpl, abi.encodeCall(NewTradeEscrowV2.initializeVault, (address(vault))));
        vm.prank(ADMIN);
        escrow.upgradeToAndCall(escrowImpl, "");
        assertEq(_impl(), escrowImpl);
        assertEq(escrow.vault(), address(vault));
    }
}
