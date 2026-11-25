// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {NewTradeEscrowV2} from "../../src/NewTradeEscrowV2.sol";
import {NewTradeBundle} from "../../src/NewTradeBundle.sol";
import {NewTradeV2Vault} from "../legacy/NewTradeV2Vault.sol";
import {NewTradeV2VaultV2} from "../../src/NewTradeV2VaultV2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AcceptanceMode, AssetKind, BundleState, ManifestEntry, Payout} from "../../src/NewTradeV2Types.sol";
import {ISeaport, Order, OrderParameters} from "../../src/interfaces/ISeaport.sol";
import {RevisedBaseBetaFixture} from "../fixtures/RevisedBaseBetaFixture.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IStrictRegistry {
    function beforeAuthorizedTransfer(address token, uint256 tokenId) external;
}

/**
 * UNSIGNED preflight simulation of the whole fresh-beta sequence, on a Base
 * fork at current head, against the REAL deployed proxy, Seaport, conduit,
 * transfer-security registry and ERC-6551 registry.
 *
 * Nothing here is signed or broadcast. It exists to resolve the preflight's
 * placeholders with values that are actually reachable, and to produce exact
 * per-step gas.
 *
 * IMPERSONATED, and labelled wherever it occurs: the upgrader (`vm.prank` of
 * the role holder) and the SignedZone authorizer call. Authorizer impersonation
 * proves the REGISTRY admits the fill; it proves nothing about OpenSea's server
 * issuing SIP-7 substandard-8 extraData. The zone on the order is the real
 * SignedZone address, so the purchase leg here is registry-armed only and is
 * NOT a proof of authentic fulfilment.
 */
contract FreshBetaSequenceForkTest is Test {
    address constant PROXY = 0x2D2cb241ACf45bDCa0cefF0d8C5Eac7Ff1b4304F;
    address constant SELLER = 0xF8e03bd4436371E0e2F7C02E529b2172fe72b4EF;
    address constant BUYER = 0x9a704664009d615A90ddDf9345B6b8B2A214cFb2;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant REGISTRY_6551 = 0x000000006551c19487814612e58FE06813775758;
    address constant ACCOUNT_PROXY = 0x55266d75D1a14E4572138116aF39863Ed6596E7F;
    address constant ACCOUNT_LOGIC = 0x41C8f39463A868d3A88af00cd0fe7102F30E44eC;
    address constant SEAPORT = 0x0000000000000068F116a894984e2DB1123eB395;
    address constant VALIDATOR = 0xA000027A9B2802E1ddf7000061001e5c005A0000;
    address constant SIGNED_ZONE = 0x000056F7000000EcE9003ca63978907a00FFD100;
    address constant OPENSEA_FEE = 0x0000a26b00c1F0DF003000390027140000fAa719;

    // ---- PROPOSED fixture choices, collision-checked below -----------------
    bytes32 constant FRESH_SALT = keccak256("newtrade-base-beta-fresh-2026-09-16");
    uint256 constant FRESH_TOKEN_ID = 101;
    /// SELECTED DEFAULT for the fresh fixture, approved by the user. This is a
    /// fixture-level SELECTION, not a protocol constant: the contract's only
    /// rule is 0 < deadline - depositTime <= MAX_CUSTODY_DURATION (90 days).
    /// Exercised below at a non-default value and at both bounds.
    uint64 constant CUSTODY_DURATION_DEFAULT = 14 days;
    uint64 constant CUSTODY_DURATION = CUSTODY_DURATION_DEFAULT;
    uint256 constant SEED_UNITS = 10; // USDC BASE UNITS = 0.00001 USDC
    uint256 constant PRICE = 10_000_000_000;
    uint256 constant ESCROW_CUT = 9_400_000_000;
    uint256 constant CREATOR_CUT = 500_000_000;
    uint256 constant MARKET_CUT = 100_000_000;
    /// OPTION B (escrow-option-b-sep26): the creator royalty is not an item; the
    /// escrow item carries it and the first exit credits it to the ERC-2981
    /// recipient (here the seller itself, so one balance).
    uint256 constant ESCROW_ITEM_B = ESCROW_CUT + CREATOR_CUT;
    uint16 constant ROYALTY_BPS = 500;

    bool forked;

    /// Last Base block at which SELLER's nonce is still 205, the nonce this file's deployment
    /// sequence is derived from. At later blocks the nonce (and the live state the sequence
    /// assumes) has moved on and three tests fail for that reason alone. Needs an archive RPC.
    uint256 private constant PINNED_FORK_BLOCK = 51_416_822;

    function setUp() public {
        forked = PROXY.code.length > 0 && SEAPORT.code.length > 0;
        // Pinned: seller nonce 205 at this block (see PINNED_FORK_BLOCK). No-op without a fork.
        if (forked) vm.rollFork(PINNED_FORK_BLOCK);
    }


    /// THE COMPATIBLE UPGRADE (F-01, partial release). The current implementation's exits go
    /// through `beginRelease` on the per-entry vault, so upgrading to it means switching the
    /// vault IN THE SAME TRANSACTION: `upgradeToAndCall(impl, initializeVault(vault))`, then
    /// opening the new vault with the policy the old one had (Wildcard for the three kinds).
    /// A bare `upgradeToAndCall(impl, "")` leaves the new code on the old vault, where every
    /// redemption and reclaim reverts; that incompatible sequence is pinned as a negative in
    /// `test_BareUpgradeWithoutTheVaultSwitch_RedemptionReverts`.
    /// The vault is deployed by THIS contract, not by SELLER, so the SELLER nonces that this
    /// file's historical address derivation depends on are untouched.
    function _upgradeWithVaultSwitch(NewTradeEscrowV2 escrow, address impl) internal returns (address vault) {
        AcceptanceMode[3] memory disabled;
        address vaultImpl = address(new NewTradeV2VaultV2());
        address receipt = escrow.receipt();
        vault = address(new ERC1967Proxy(vaultImpl, abi.encodeCall(NewTradeV2VaultV2.initialize, (PROXY, receipt, disabled))));
        vm.startPrank(SELLER);
        escrow.upgradeToAndCall(impl, abi.encodeCall(NewTradeEscrowV2.initializeVault, (vault)));
        for (uint8 k; k < 3; ++k) escrow.setAssetAcceptanceMode(AssetKind(k), AcceptanceMode.Wildcard);
        vm.stopPrank();
    }

    function test_FreshSequenceIsReachableAndResolvesEveryPlaceholder() public {
        if (!forked) return;
        NewTradeEscrowV2 escrow = NewTradeEscrowV2(payable(PROXY));

        // ---- historical observation: bundle 1 before we touch anything ----
        bytes32 bundle1Before = keccak256(abi.encode(escrow.getBundle(1)));
        (, , bytes32 order1Before, ,) = escrow.getOrder(1);

        // The vault that holds historical bundle 1, read BEFORE the upgrade: the compatible
        // upgrade switches the escrow to a new vault and leaves this one untouched.
        address historicalVault = escrow.vault();
        uint256 historicalUnits = IERC20(USDC).balanceOf(historicalVault);

        // ---- step 1-2: deploy + upgrade (upgrader IMPERSONATED) -----------
        uint256 g = gasleft();
        NewTradeEscrowV2 impl = new NewTradeEscrowV2();
        console2.log("gas step1 deploy implementation", g - gasleft());

        g = gasleft();
        _upgradeWithVaultSwitch(escrow, address(impl));
        console2.log("gas step2 upgradeToAndCall", g - gasleft());

        // Historical bundle 1 must be untouched by the upgrade.
        assertEq(keccak256(abi.encode(escrow.getBundle(1))), bundle1Before, "bundle 1 changed");
        (, , bytes32 order1After, ,) = escrow.getOrder(1);
        assertEq(order1After, order1Before, "bundle 1 order hash changed");

        // ---- step 3: deploy the fresh fixture -----------------------------
        g = gasleft();
        vm.prank(SELLER);
        RevisedBaseBetaFixture fixture = new RevisedBaseBetaFixture(
            REGISTRY_6551, ACCOUNT_PROXY, ACCOUNT_LOGIC, FRESH_SALT, SELLER, ROYALTY_BPS,
            "data:image/svg+xml;base64,PHN2Zz48L3N2Zz4=", "NewTrade Base beta fresh fixture."
        );
        console2.log("gas step3 deploy fixture", g - gasleft());

        // COLLISION CHECK: the ERC-6551 account for (fixture, FRESH_TOKEN_ID,
        // FRESH_SALT) must not already exist on chain.
        address predicted = IRegistry6551(REGISTRY_6551)
            .account(ACCOUNT_PROXY, FRESH_SALT, block.chainid, address(fixture), FRESH_TOKEN_ID);
        assertEq(predicted.code.length, 0, "PROPOSED salt/tokenId collide with a deployed account");
        console2.log("predicted fresh tokenbound account", predicted);

        // ---- step 4: mint + create the tokenbound account ------------------
        g = gasleft();
        vm.prank(SELLER);
        address account = fixture.mint(SELLER, FRESH_TOKEN_ID);
        console2.log("gas step4 mint+createAccount", g - gasleft());
        assertEq(account, predicted, "account derivation drifted");

        // ---- step 5: seed the account with 10 USDC BASE UNITS --------------
        // From deployer funds only: the seller already holds these units.
        uint256 sellerUnits = IERC20(USDC).balanceOf(SELLER);
        assertGe(sellerUnits, SEED_UNITS, "seller cannot fund the seed");
        g = gasleft();
        vm.prank(SELLER);
        IERC20(USDC).transfer(account, SEED_UNITS);
        console2.log("gas step5 seed account", g - gasleft());
        assertEq(IERC20(USDC).balanceOf(account), SEED_UNITS);

        // ---- step 6-7: approve vault, migrate the seeded account into custody
        //
        // CUSTODY TREATMENT. The seed is pulled OUT of the tokenbound account
        // and INTO the vault as a manifest entry, using depositFromAccount -
        // the same route the reviewed historical fixture used.
        //
        // Why it must be in the manifest: redemption calls
        // _vault.release(bundleId, nft, tokenId, freshAccount, holder), which
        // delivers manifest assets to the buyer's FRESH account atomically with
        // the burn. That is a contract-level guarantee. If the seed were left in
        // the controlling NFT's original account instead, the buyer would end up
        // owning that account only indirectly, and would have to drive
        // ERC-6551 `execute` themselves to get the asset out - no guarantee from
        // the escrow, and a second step that can fail.
        address vault = escrow.vault();
        // The vault ALREADY custodies historical bundle 1's own 10 units, so
        // only the delta is ours. Asserting an absolute balance here was wrong
        // and caught exactly that.
        uint256 vaultUnitsBefore = IERC20(USDC).balanceOf(vault);
        vm.startPrank(SELLER);
        uint256 g6 = gasleft();
        fixture.approve(vault, FRESH_TOKEN_ID);
        console2.log("gas step6 approve vault", g6 - gasleft());
        escrow.setMigrationEnabled(true);
        vm.stopPrank();

        ManifestEntry[] memory manifest = new ManifestEntry[](1);
        manifest[0] = ManifestEntry(AssetKind.ERC20, USDC, 0, SEED_UNITS);
        uint64 deadline = uint64(block.timestamp) + CUSTODY_DURATION;

        vm.startPrank(SELLER);
        g = gasleft();
        uint256 bundleId = escrow.depositFromAccount(
            account, address(fixture), FRESH_TOKEN_ID, manifest, deadline,
            keccak256("newtrade-base-beta-fresh-migration-v1")
        );
        console2.log("gas step7 depositFromAccount", g - gasleft());
        escrow.setMigrationEnabled(false);
        console2.log("fresh bundleId", bundleId);
        assertTrue(bundleId != 1, "fresh bundle must not be bundle 1");
        // The account is emptied and the vault now custodies the seed.
        assertEq(IERC20(USDC).balanceOf(account), 0, "seed must leave the account");
        assertEq(IERC20(USDC).balanceOf(vault) - vaultUnitsBefore, SEED_UNITS, "vault must custody OUR seed");
        // ...and historical bundle 1's custody is undisturbed underneath it.
        // It stays in the vault the escrow used before the switch; the new vault started empty.
        assertEq(historicalUnits, 10, "historical bundle 1 units were in the vault before the upgrade");
        assertEq(IERC20(USDC).balanceOf(historicalVault), 10, "historical bundle 1 units must still be in ITS vault");
        assertTrue(vault != historicalVault, "the escrow now uses the per-entry vault");
        assertEq(vaultUnitsBefore, 0, "the new vault held nothing before our deposit");

        // ---- step 8: list with the three approved payouts ------------------
        Payout[] memory payouts = new Payout[](2);
        payouts[0] = Payout(payable(PROXY), ESCROW_ITEM_B);
        payouts[1] = Payout(payable(OPENSEA_FEE), MARKET_CUT);
        g = gasleft();
        bytes32 freshOrderHash = escrow.list(bundleId, address(0), PRICE, deadline, ROYALTY_BPS, payouts);
        console2.log("gas step8 list", g - gasleft());
        vm.stopPrank();

        // ---- the authoritative hash exists only now ------------------------
        (OrderParameters memory p, , bytes32 storedHash, ,) = escrow.getOrder(bundleId);
        assertEq(storedHash, freshOrderHash, "getOrder must agree with list()");
        assertTrue(storedHash != order1Before, "fresh order must not equal bundle 1");
        console2.logBytes32(storedHash);
        assertTrue(p.startTime != 0, "startTime must be non-zero");
        assertEq(p.startTime, block.timestamp, "startTime is the listing block time");
        assertEq(p.conduitKey, escrow.OPENSEA_CONDUIT_KEY());
        assertEq(p.consideration.length, 2);
        assertEq(p.consideration[0].recipient, PROXY);
        assertEq(p.consideration[0].startAmount, ESCROW_ITEM_B);
        assertEq(p.consideration[1].recipient, OPENSEA_FEE);
        assertEq(p.consideration[1].startAmount, MARKET_CUT);
        console2.log("fresh startTime", p.startTime);
        console2.log("fresh endTime", p.endTime);

        // ---- purchase leg: registry armed by IMPERSONATED authorizer -------
        address receipt = escrow.receipt();
        vm.prank(SIGNED_ZONE);
        IStrictRegistry(VALIDATOR).beforeAuthorizedTransfer(receipt, bundleId);

        vm.deal(BUYER, PRICE);
        uint256 creatorBefore = SELLER.balance;
        uint256 marketBefore = OPENSEA_FEE.balance;
        // Real Seaport consults the REAL SignedZone, which requires server-signed
        // SIP-7 extraData we cannot produce. This MUST revert - asserted, not
        // tolerated, so the boundary is proven rather than merely observed. The
        // registry-armed fill itself is proven separately in RealRegistryFork
        // against a stub zone.
        vm.prank(BUYER);
        vm.expectRevert();
        ISeaport(SEAPORT).fulfillOrder{value: PRICE}(Order(p, ""), bytes32(0));
        assertEq(escrow.claimable(SELLER, address(0)), 0, "nothing may settle without authentic zone data");
        assertEq(SELLER.balance, creatorBefore);
        assertEq(OPENSEA_FEE.balance, marketBefore);

        // ---- historical bundle 1 still untouched at the end ----------------
        assertEq(keccak256(abi.encode(escrow.getBundle(1))), bundle1Before, "bundle 1 changed by the fresh run");
    }

    /**
     * Purchase and redemption, with the SignedZone STUBBED OUT at its real
     * address so the fill can proceed.
     *
     * ================== WHAT IS IMPERSONATED HERE ==================
     * The zone. `vm.etch` replaces the real SignedZone with a stub that returns
     * the selector Seaport asks for and verifies NOTHING. The registry arming is
     * also impersonated. Everything else - Seaport, the conduit, the transfer
     * registry, the ERC-6551 registry, USDC, the live proxy - is real.
     *
     * This proves the ESCROW mechanics: that a fill credits the seller and that
     * redemption delivers the manifest seed into the buyer's fresh account. It
     * proves NOTHING about OpenSea issuing extraData, which the test above
     * asserts is still required.
     */
    function test_BuyerRedemptionDeliversTheSeededAssetWhenTheZoneIsStubbed() public {
        if (!forked) return;
        NewTradeEscrowV2 escrow = NewTradeEscrowV2(payable(PROXY));
        // Deploy FIRST: vm.prank applies to the next call, and an inline `new`
        // would consume it before reaching upgradeToAndCall.
        NewTradeEscrowV2 nextImpl = new NewTradeEscrowV2();
        _upgradeWithVaultSwitch(escrow, address(nextImpl));

        vm.prank(SELLER);
        RevisedBaseBetaFixture fixture = new RevisedBaseBetaFixture(
            REGISTRY_6551, ACCOUNT_PROXY, ACCOUNT_LOGIC, FRESH_SALT, SELLER, ROYALTY_BPS,
            "data:image/svg+xml;base64,PHN2Zz48L3N2Zz4=", "NewTrade Base beta fresh fixture."
        );
        vm.prank(SELLER);
        address account = fixture.mint(SELLER, FRESH_TOKEN_ID);
        vm.prank(SELLER);
        IERC20(USDC).transfer(account, SEED_UNITS);

        address vault = escrow.vault();
        vm.startPrank(SELLER);
        fixture.approve(vault, FRESH_TOKEN_ID);
        escrow.setMigrationEnabled(true);
        ManifestEntry[] memory manifest = new ManifestEntry[](1);
        manifest[0] = ManifestEntry(AssetKind.ERC20, USDC, 0, SEED_UNITS);
        uint64 deadline = uint64(block.timestamp) + CUSTODY_DURATION;
        uint256 bundleId = escrow.depositFromAccount(
            account, address(fixture), FRESH_TOKEN_ID, manifest, deadline,
            keccak256("newtrade-base-beta-fresh-migration-v1")
        );
        escrow.setMigrationEnabled(false);
        Payout[] memory payouts = new Payout[](2);
        payouts[0] = Payout(payable(PROXY), ESCROW_ITEM_B);
        payouts[1] = Payout(payable(OPENSEA_FEE), MARKET_CUT);
        escrow.list(bundleId, address(0), PRICE, deadline, ROYALTY_BPS, payouts);
        vm.stopPrank();

        // IMPERSONATION. Order matters: arm the registry while the SignedZone
        // still has its real code, THEN replace it with the stub. Etching first
        // makes the registry refuse the arming with CallerIsNotValidAuthorizer.
        address receipt = escrow.receipt(); // hoisted: an inline call would consume the prank
        vm.prank(SIGNED_ZONE);
        IStrictRegistry(VALIDATOR).beforeAuthorizedTransfer(receipt, bundleId);
        PermissiveZoneStub stub = new PermissiveZoneStub();
        vm.etch(SIGNED_ZONE, address(stub).code);

        (OrderParameters memory p,,,,) = escrow.getOrder(bundleId);
        vm.deal(BUYER, PRICE);
        uint256 creatorBefore = SELLER.balance;
        uint256 marketBefore = OPENSEA_FEE.balance;
        vm.prank(BUYER);
        assertTrue(ISeaport(SEAPORT).fulfillOrder{value: PRICE}(Order(p, ""), bytes32(0)));

        // Seller == creator: the seller credit and the creator credit are one balance.
        assertEq(escrow.claimable(SELLER, address(0)), ESCROW_ITEM_B, "seller + creator credit");
        assertEq(SELLER.balance - creatorBefore, 0, "no item pays the creator");
        assertEq(OPENSEA_FEE.balance - marketBefore, MARKET_CUT, "marketplace fee paid directly");

        // THE POINT: redemption hands the seeded asset to the buyer's fresh
        // account, by contract, atomically with the burn.
        uint256 buyerUnitsBefore = IERC20(USDC).balanceOf(BUYER);
        vm.prank(BUYER);
        address fresh = escrow.redeemToFreshAccount(bundleId, keccak256("fresh-holder-salt"));
        assertEq(IERC20(USDC).balanceOf(fresh), SEED_UNITS, "buyer's fresh account must hold the seed");
        assertEq(fixture.ownerOf(FRESH_TOKEN_ID), BUYER, "buyer must own the controlling NFT");
        assertEq(uint8(escrow.getBundle(bundleId).state), uint8(BundleState.Redeemed));
        // The seed arrives in the FRESH account, not the buyer's own wallet.
        assertEq(IERC20(USDC).balanceOf(BUYER), buyerUnitsBefore);

        // The seller can then withdraw their credit for real.
        uint256 sellerBefore = SELLER.balance;
        vm.prank(SELLER);
        assertEq(escrow.withdraw(address(0)), ESCROW_ITEM_B);
        assertEq(SELLER.balance - sellerBefore, ESCROW_ITEM_B);
    }

    /// NEGATIVE, kept from the original failure of the test above: the current implementation
    /// WITHOUT the vault switch. Deposit, listing and the Seaport fill still work (they do not
    /// exit), but the redemption calls `beginRelease` on a vault that has no such function and
    /// reverts whole: the claim is not burned and the buyer keeps it. Not a supported sequence.
    function test_BareUpgradeWithoutTheVaultSwitch_RedemptionReverts() public {
        if (!forked) return;
        NewTradeEscrowV2 escrow = NewTradeEscrowV2(payable(PROXY));
        NewTradeEscrowV2 nextImpl = new NewTradeEscrowV2();
        vm.prank(SELLER);
        escrow.upgradeToAndCall(address(nextImpl), "");

        vm.prank(SELLER);
        RevisedBaseBetaFixture fixture = new RevisedBaseBetaFixture(
            REGISTRY_6551, ACCOUNT_PROXY, ACCOUNT_LOGIC, FRESH_SALT, SELLER, ROYALTY_BPS,
            "data:image/svg+xml;base64,PHN2Zz48L3N2Zz4=", "NewTrade Base beta fresh fixture."
        );
        vm.prank(SELLER);
        address account = fixture.mint(SELLER, FRESH_TOKEN_ID);
        vm.prank(SELLER);
        IERC20(USDC).transfer(account, SEED_UNITS);
        address vault = escrow.vault();
        vm.startPrank(SELLER);
        fixture.approve(vault, FRESH_TOKEN_ID);
        escrow.setMigrationEnabled(true);
        ManifestEntry[] memory manifest = new ManifestEntry[](1);
        manifest[0] = ManifestEntry(AssetKind.ERC20, USDC, 0, SEED_UNITS);
        uint64 deadline = uint64(block.timestamp) + CUSTODY_DURATION;
        uint256 bundleId = escrow.depositFromAccount(
            account, address(fixture), FRESH_TOKEN_ID, manifest, deadline, keccak256("newtrade-base-beta-fresh-migration-v1")
        );
        Payout[] memory payouts = new Payout[](2);
        payouts[0] = Payout(payable(PROXY), ESCROW_ITEM_B);
        payouts[1] = Payout(payable(OPENSEA_FEE), MARKET_CUT);
        escrow.list(bundleId, address(0), PRICE, deadline, ROYALTY_BPS, payouts);
        vm.stopPrank();
        address receipt = escrow.receipt();
        vm.prank(SIGNED_ZONE);
        IStrictRegistry(VALIDATOR).beforeAuthorizedTransfer(receipt, bundleId);
        PermissiveZoneStub stub = new PermissiveZoneStub();
        vm.etch(SIGNED_ZONE, address(stub).code);
        (OrderParameters memory p,,,,) = escrow.getOrder(bundleId);
        vm.deal(BUYER, PRICE);
        vm.prank(BUYER);
        assertTrue(ISeaport(SEAPORT).fulfillOrder{value: PRICE}(Order(p, ""), bytes32(0)));

        vm.prank(BUYER);
        vm.expectRevert();
        escrow.redeemToFreshAccount(bundleId, keccak256("fresh-holder-salt"));
        assertEq(uint8(escrow.getBundle(bundleId).state), uint8(BundleState.Issued), "nothing changed");
        assertEq(NewTradeBundle(receipt).ownerOf(bundleId), BUYER, "the claim is not burned");
        assertEq(fixture.ownerOf(FRESH_TOKEN_ID), vault, "the NFT is still in the old vault");
    }

    // ----------------------------------------------------- configurability

    /**
     * The custody duration is an INPUT, not a constant.
     *
     * 14 days is the selected fixture default. This runs a NON-DEFAULT value
     * through the identical path, and pins the contract's actual bounds so a
     * future selection cannot silently exceed them.
     */
    function test_CustodyDurationIsSelectableAndBoundsAreEnforced() public {
        if (!forked) return;
        NewTradeEscrowV2 escrow = NewTradeEscrowV2(payable(PROXY));
        NewTradeEscrowV2 nextImpl = new NewTradeEscrowV2();
        _upgradeWithVaultSwitch(escrow, address(nextImpl));

        // The default and a NON-DEFAULT duration both work, identical path.
        assertEq(_depositWithDuration(escrow, 1, CUSTODY_DURATION_DEFAULT), uint64(block.timestamp) + 14 days);
        assertEq(_depositWithDuration(escrow, 2, 30 days), uint64(block.timestamp) + 30 days);
        // ...and so does the exact upper bound.
        assertEq(_depositWithDuration(escrow, 3, escrow.MAX_CUSTODY_DURATION()), uint64(block.timestamp) + 90 days);

        // Bounds read from the contract rather than asserted in a comment:
        // the deadline must be strictly in the future...
        _expectDeadlineRevert(escrow, 4, uint64(block.timestamp));
        // ...and no further out than MAX_CUSTODY_DURATION.
        _expectDeadlineRevert(escrow, 5, uint64(block.timestamp) + escrow.MAX_CUSTODY_DURATION() + 1);
    }

    /**
     * `list` must carry the SAME absolute deadline the bundle was deposited
     * with. This is exactly why the unsigned package pins ONE absolute value
     * and reuses it in both calls rather than recomputing a duration.
     */
    function test_ListMustCarryTheSameAbsoluteDeadlineAsTheDeposit() public {
        if (!forked) return;
        NewTradeEscrowV2 escrow = NewTradeEscrowV2(payable(PROXY));
        NewTradeEscrowV2 nextImpl = new NewTradeEscrowV2();
        _upgradeWithVaultSwitch(escrow, address(nextImpl));

        (RevisedBaseBetaFixture fixture, uint256 tokenId) = _freshFixture(11);
        uint64 deadline = uint64(block.timestamp) + CUSTODY_DURATION_DEFAULT;
        address vault = escrow.vault();
        vm.startPrank(SELLER);
        fixture.approve(vault, tokenId);
        uint256 bundleId = escrow.deposit(address(fixture), tokenId, new ManifestEntry[](0), deadline);

        Payout[] memory payouts = new Payout[](2);
        payouts[0] = Payout(payable(PROXY), ESCROW_ITEM_B);
        payouts[1] = Payout(payable(OPENSEA_FEE), MARKET_CUT);

        vm.expectRevert(NewTradeEscrowV2.InvalidOrder.selector);
        escrow.list(bundleId, address(0), PRICE, deadline + 1, ROYALTY_BPS, payouts);
        vm.expectRevert(NewTradeEscrowV2.InvalidOrder.selector);
        escrow.list(bundleId, address(0), PRICE, deadline - 1, ROYALTY_BPS, payouts);
        escrow.list(bundleId, address(0), PRICE, deadline, ROYALTY_BPS, payouts);
        vm.stopPrank();
        (OrderParameters memory p,,,,) = escrow.getOrder(bundleId);
        assertEq(p.endTime, deadline, "order end time must equal the pinned deadline");
    }

    function _freshFixture(uint256 tokenId) internal returns (RevisedBaseBetaFixture fixture, uint256 id) {
        vm.prank(SELLER);
        fixture = new RevisedBaseBetaFixture(
            REGISTRY_6551, ACCOUNT_PROXY, ACCOUNT_LOGIC, keccak256(abi.encode(FRESH_SALT, tokenId)),
            SELLER, ROYALTY_BPS, "data:image/svg+xml;base64,PHN2Zz48L3N2Zz4=", "duration probe"
        );
        vm.prank(SELLER);
        fixture.mint(SELLER, tokenId);
        id = tokenId;
    }

    function _depositWithDuration(NewTradeEscrowV2 escrow, uint256 tokenId, uint64 duration)
        internal
        returns (uint64 storedDeadline)
    {
        (RevisedBaseBetaFixture fixture, uint256 id) = _freshFixture(tokenId);
        uint64 deadline = uint64(block.timestamp) + duration;
        address vault = escrow.vault();
        vm.startPrank(SELLER);
        fixture.approve(vault, id);
        uint256 bundleId = escrow.deposit(address(fixture), id, new ManifestEntry[](0), deadline);
        vm.stopPrank();
        storedDeadline = escrow.getBundle(bundleId).custodyDeadline;
    }

    function _expectDeadlineRevert(NewTradeEscrowV2 escrow, uint256 tokenId, uint64 deadline) internal {
        (RevisedBaseBetaFixture fixture, uint256 id) = _freshFixture(tokenId);
        address vault = escrow.vault();
        vm.startPrank(SELLER);
        fixture.approve(vault, id);
        vm.expectRevert(NewTradeEscrowV2.InvalidDeadline.selector);
        escrow.deposit(address(fixture), id, new ManifestEntry[](0), deadline);
        vm.stopPrank();
    }

    // ------------------------------------------- exact nonce-derived proof

    /**
     * EXACT proof, not a generic simulation.
     *
     * op2 correctly distinguished these: the other tests deploy at the TEST
     * contract's nonce, so they prove the sequence shape but say nothing about
     * the specific addresses in `unsigned-calls.json`. This one pins the
     * seller's nonce to the package's value and deploys AS THE SELLER, so the
     * implementation, fixture and tokenbound account it produces are the exact
     * addresses the package publishes.
     *
     * It also measures the two `setMigrationEnabled` calls, which were the only
     * steps carrying an unmeasured gas bound.
     */
    function test_ExactNonceDerivedAddressesAndMigrationToggleGas() public {
        if (!forked) return;
        NewTradeEscrowV2 escrow = NewTradeEscrowV2(payable(PROXY));

        // The package is built at seller nonce 205. Pin it so the CREATE
        // addresses derive exactly as the package says they will.
        uint64 packagedNonce = 205;
        vm.setNonce(SELLER, packagedNonce);
        assertEq(vm.getNonce(SELLER), packagedNonce);

        address expectedImpl = vm.computeCreateAddress(SELLER, packagedNonce);
        address expectedFixture = vm.computeCreateAddress(SELLER, packagedNonce + 2);
        console2.log("expected implementation", expectedImpl);
        console2.log("expected fixture", expectedFixture);

        // step 1 - deploy the implementation AS THE SELLER
        vm.prank(SELLER);
        NewTradeEscrowV2 impl = new NewTradeEscrowV2();
        assertEq(address(impl), expectedImpl, "implementation address must match the package");

        // step 2
        _upgradeWithVaultSwitch(escrow, address(impl));

        // step 3 - deploy the fixture AS THE SELLER, at nonce+2.
        //
        // The nonce has to be set explicitly here. In a real run every
        // transaction from the seller increments the nonce, so the upgrade in
        // step 2 moves it 206 -> 207. Under `vm.prank` a CALL does not bump the
        // EOA nonce - only a CREATE does - so without this the fixture would
        // deploy at 206 and land on a different address than the package
        // publishes. Modelling the real progression is the point of this test.
        assertEq(vm.getNonce(SELLER), packagedNonce + 1, "only the CREATE bumped it");
        vm.setNonce(SELLER, packagedNonce + 2);
        vm.prank(SELLER);
        RevisedBaseBetaFixture fixture = new RevisedBaseBetaFixture(
            REGISTRY_6551, ACCOUNT_PROXY, ACCOUNT_LOGIC, FRESH_SALT, SELLER, ROYALTY_BPS,
            "data:image/svg+xml;base64,PHN2Zz48L3N2Zz4=", "NewTrade Base beta fresh fixture."
        );
        assertEq(address(fixture), expectedFixture, "fixture address must match the package");

        // step 4 - the tokenbound account is then fully determined
        vm.prank(SELLER);
        address account = fixture.mint(SELLER, FRESH_TOKEN_ID);
        console2.log("exact tokenbound account", account);
        assertEq(
            account,
            IRegistry6551(REGISTRY_6551).account(ACCOUNT_PROXY, FRESH_SALT, block.chainid, expectedFixture, FRESH_TOKEN_ID),
            "account must match the registry derivation the package uses"
        );

        // steps 5-6
        vm.prank(SELLER);
        IERC20(USDC).transfer(account, SEED_UNITS);
        address vault = escrow.vault();
        vm.prank(SELLER);
        fixture.approve(vault, FRESH_TOKEN_ID);

        // step 7 - MEASURED migration toggle on
        uint256 g = gasleft();
        vm.prank(SELLER);
        escrow.setMigrationEnabled(true);
        console2.log("gas step7 setMigrationEnabled(true)", g - gasleft());

        ManifestEntry[] memory manifest = new ManifestEntry[](1);
        manifest[0] = ManifestEntry(AssetKind.ERC20, USDC, 0, SEED_UNITS);
        uint64 deadline = uint64(block.timestamp) + CUSTODY_DURATION_DEFAULT;
        vm.prank(SELLER);
        uint256 bundleId = escrow.depositFromAccount(
            account, address(fixture), FRESH_TOKEN_ID, manifest, deadline,
            keccak256("newtrade-base-beta-fresh-migration-v1")
        );

        // step 9 - MEASURED migration toggle off
        g = gasleft();
        vm.prank(SELLER);
        escrow.setMigrationEnabled(false);
        console2.log("gas step9 setMigrationEnabled(false)", g - gasleft());

        // The finalizer's input: the assigned id is NOT 1 and NOT predictable.
        console2.log("assigned bundleId", bundleId);
        assertTrue(bundleId != 1, "assigned bundle must never be the historical one");
        assertEq(escrow.getBundle(bundleId).custodyDeadline, deadline);
        assertEq(escrow.getBundle(bundleId).seller, SELLER);
        assertEq(escrow.getBundle(bundleId).controllingNFT, expectedFixture);
    }
}

interface IRegistry6551 {
    function account(address impl, bytes32 salt, uint256 chainId, address tokenContract, uint256 tokenId)
        external view returns (address);
}


/// Returns whatever selector Seaport asks for; verifies nothing. Stand-in only.
contract PermissiveZoneStub {
    fallback() external {
        assembly ("memory-safe") {
            mstore(0, shl(224, shr(224, calldataload(0))))
            return(0, 32)
        }
    }
}
