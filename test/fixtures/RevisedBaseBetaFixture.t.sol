// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {IERC6551Account} from "../../src/interfaces/IERC6551.sol";
import {NewTradeEscrowV2} from "../../src/NewTradeEscrowV2.sol";
import {NewTradeBundle} from "../../src/NewTradeBundle.sol";
import {BundleDeploy} from "../helpers/BundleDeploy.sol";
import {NewTradeV2Vault} from "../legacy/NewTradeV2Vault.sol";
import {NewTradeV2VaultV2} from "../../src/NewTradeV2VaultV2.sol";
import {VaultV2Deploy} from "../helpers/VaultV2Deploy.sol";
import {
    AcceptanceMode,
    AssetKind,
    BundleState,
    ManifestEntry,
    Payout,
    V2Initialization
} from "../../src/NewTradeV2Types.sol";
import {OrderParameters} from "../../src/interfaces/ISeaport.sol";
import {MockERC20} from "../mocks/TokenMocks.sol";
import {Mock6551Registry, Mock6551Implementation, MockTokenboundAccountProxy} from "../helpers/ERC6551Mocks.sol";
import {SeaportV2Mock} from "../helpers/SeaportV2Mock.sol";
import {ConduitMock} from "../helpers/ConduitMock.sol";
import {FixtureCustodyValidator, RevisedBaseBetaFixture} from "./RevisedBaseBetaFixture.sol";

contract RevisedBaseBetaFixtureTest is Test {
    uint256 private constant BASE_CHAIN_ID = 8453;
    uint256 private constant TOKEN_ID = 42;
    uint256 private constant SEED_UNITS = 10;
    uint256 private constant SALE_PRICE = 1_000_001;
    uint16 private constant ROYALTY_BPS = 750;
    uint256 private constant EXPECTED_ROYALTY = 75_000; // floor(1_000_001 * 750 / 10_000)
    /// OpenSea's canonical fee recipient and its 1%, carried as an EXPLICIT
    /// consideration item exactly as the published beta order must carry it.
    address private constant OPENSEA_FEE_RECIPIENT = 0x0000a26b00c1F0DF003000390027140000fAa719;
    uint256 private constant OPENSEA_FEE = SALE_PRICE / 100; // 10_000
    string private constant BASE_INDEX_ZERO = "account[0x0001000002210500][0]";
    string private constant IMAGE = "ipfs://bafybeigdyrzt/example.png";
    string private constant DESCRIPTION = "Disposable NewTrade Base beta lifecycle fixture.";
    bytes32 private constant SALT = keccak256("newtrade-base-beta-example-v2");
    address private constant SEAPORT = 0x0000000000000068F116a894984e2DB1123eB395;

    address private seller = address(0xA11CE);
    address private buyer = address(0xB0B);
    address private laterHolder = address(0xBEEF);
    address private attacker = address(0xBAD);
    address private royaltyRecipient = address(0xC0FFEE);
    Mock6551Registry private registry;
    Mock6551Implementation private accountLogic;
    MockTokenboundAccountProxy private accountProxy;
    FixtureCustodyValidator private validator;
    RevisedBaseBetaFixture private fixture;

    function setUp() public {
        vm.chainId(BASE_CHAIN_ID);
        registry = new Mock6551Registry();
        accountLogic = new Mock6551Implementation();
        accountProxy = new MockTokenboundAccountProxy(address(accountLogic));
        validator = new FixtureCustodyValidator(address(this));
        fixture = new RevisedBaseBetaFixture(
            address(registry),
            address(accountProxy),
            address(accountLogic),
            SALT,
            royaltyRecipient,
            ROYALTY_BPS,
            IMAGE,
            DESCRIPTION
        );
        fixture.setTransferValidator(address(validator));
    }

    function test_RoyaltyRoundsDownAtConcreteSalePriceAndIsDiscoverable() public {
        fixture.mint(seller, TOKEN_ID);
        (address recipient, uint256 amount) = fixture.royaltyInfo(TOKEN_ID, SALE_PRICE);
        assertEq(recipient, royaltyRecipient);
        assertEq(amount, EXPECTED_ROYALTY);
        assertTrue(fixture.supportsInterface(type(IERC2981).interfaceId));
    }

    function test_DisplayMetadataAndErc8048IndexZeroDiscovery() public {
        address account = fixture.mint(seller, TOKEN_ID);
        string memory expectedJson = string.concat(
            '{"name":"NewTrade Beta NFT #42","description":"', DESCRIPTION, '","image":"', IMAGE, '"}'
        );
        assertEq(fixture.name(), "NewTrade Beta NFT");
        assertEq(
            fixture.tokenURI(TOKEN_ID),
            string.concat("data:application/json;base64,", Base64.encode(bytes(expectedJson)))
        );
        assertEq(fixture.metadata(TOKEN_ID, BASE_INDEX_ZERO), abi.encodePacked(account));
        assertEq(fixture.metadata(TOKEN_ID, "account[0x0001000002210500][1]"), bytes(""));
        assertTrue(fixture.supportsInterface(fixture.ERC8048_INTERFACE_ID()));
    }

    function test_MetadataEscapesJsonSpecialCharactersAndParses() public {
        string memory unsafeImage = 'ipfs://example/"quoted"\\image\n.png';
        string memory unsafeDescription =
            string(abi.encodePacked("quote: \\\"; controls: ", bytes1(0x08), bytes1(0x0c), "\n\r\t", bytes1(0x01)));
        RevisedBaseBetaFixture escapedFixture = new RevisedBaseBetaFixture(
            address(registry),
            address(accountProxy),
            address(accountLogic),
            SALT,
            royaltyRecipient,
            ROYALTY_BPS,
            unsafeImage,
            unsafeDescription
        );
        escapedFixture.mint(seller, TOKEN_ID);

        string memory expectedJson =
            '{"name":"NewTrade Beta NFT #42","description":"quote: \\\\\\"; controls: \\b\\f\\n\\r\\t\\u0001","image":"ipfs://example/\\\"quoted\\\"\\\\image\\n.png"}';
        assertEq(
            escapedFixture.tokenURI(TOKEN_ID),
            string.concat("data:application/json;base64,", Base64.encode(bytes(expectedJson)))
        );
        assertEq(vm.parseJsonString(expectedJson, ".description"), unsafeDescription);
        assertEq(vm.parseJsonString(expectedJson, ".image"), unsafeImage);
    }

    /// @dev Local lifecycle coverage only: registry/account, payment token and
    /// Seaport/receipt-validator execution are mocks. This proves the V2 state
    /// transition after a validator-authorized transfer, not that OpenSea's
    /// deployed strict validator permits a real buyer-to-later-holder route.
    /// RE-ANCHORED (bundle-non-transferable-sep26): the buyer can no longer pass
    /// the claim to a later holder; the buyer redeems it.
    function test_LocalMockLifecycleBuyerCannotResellAndRedeemsItself() public {
        address sourceAccount = fixture.mint(seller, TOKEN_ID);
        MockERC20 mockUsdc = new MockERC20("Fixture USDC", "fUSDC", 6);
        mockUsdc.mint(sourceAccount, SEED_UNITS);
        (NewTradeEscrowV2 escrow, NewTradeV2VaultV2 vault, NewTradeBundle receipt) = _deployV2(mockUsdc);

        validator.setApprovedCustody(address(vault), true);
        assertGt(address(vault).code.length, 0);
        assertEq(vault.controller(), address(escrow));
        assertTrue(validator.approvedCustody(address(vault)));
        vm.prank(seller);
        fixture.setApprovalForAll(address(vault), true);
        escrow.setMigrationEnabled(true);

        ManifestEntry[] memory entries = new ManifestEntry[](1);
        entries[0] = ManifestEntry(AssetKind.ERC20, address(mockUsdc), 0, SEED_UNITS);
        vm.prank(seller);
        uint256 bundleId = escrow.depositFromAccount(
            sourceAccount,
            address(fixture),
            TOKEN_ID,
            entries,
            uint64(block.timestamp + 1 days),
            keccak256("fixture-migration")
        );
        assertEq(fixture.ownerOf(TOKEN_ID), address(vault));
        assertEq(mockUsdc.balanceOf(address(vault)), SEED_UNITS);

        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(FixtureCustodyValidator.TransferDenied.selector, attacker, address(vault), attacker)
        );
        fixture.transferFrom(address(vault), attacker, TOKEN_ID);
        assertEq(fixture.ownerOf(TOKEN_ID), address(vault));

        // OPTION B (escrow-option-b-sep26): the two items the published order carries:
        //   [0] the ESCROW, because OpenSea requires offerer == first recipient;
        //       the seller's share AND the creator royalty settle onward from it
        //       as withdrawable credits;
        //   [1] OpenSea's 1% marketplace fee.
        // A creator item is refused: the creator is credited, never paid twice.
        Payout[] memory payouts = new Payout[](2);
        payouts[0] = Payout(payable(address(escrow)), SALE_PRICE - OPENSEA_FEE);
        payouts[1] = Payout(payable(OPENSEA_FEE_RECIPIENT), OPENSEA_FEE);
        vm.prank(seller);
        escrow.list(bundleId, address(mockUsdc), SALE_PRICE, uint64(block.timestamp + 1 days), ROYALTY_BPS, payouts);
        (OrderParameters memory order,,,,) = escrow.getOrder(bundleId);
        // Pay for real, so the credit the escrow writes is backed by tokens it
        // actually received rather than by an assertion.
        mockUsdc.mint(buyer, SALE_PRICE);
        vm.prank(buyer);
        mockUsdc.approve(SEAPORT, SALE_PRICE);
        SeaportV2Mock(SEAPORT).fillAndPay(order, buyer, buyer);
        assertEq(mockUsdc.balanceOf(royaltyRecipient), 0, "no item pays the creator");
        assertEq(mockUsdc.balanceOf(OPENSEA_FEE_RECIPIENT), OPENSEA_FEE);
        assertEq(mockUsdc.balanceOf(address(escrow)), SALE_PRICE - OPENSEA_FEE);
        // The creator royalty is CREDITED out of the escrow item.
        assertEq(escrow.claimable(royaltyRecipient, address(mockUsdc)), EXPECTED_ROYALTY);
        (OrderParameters memory recorded,,,,) = escrow.getOrder(bundleId);
        assertEq(recorded.consideration.length, 2);
        assertEq(recorded.consideration[1].recipient, OPENSEA_FEE_RECIPIENT);
        assertEq(recorded.consideration[1].startAmount, OPENSEA_FEE);
        // ...and the listing carries a real start time and the OpenSea conduit.
        assertTrue(recorded.startTime != 0 && recorded.startTime <= block.timestamp);
        assertEq(recorded.conduitKey, escrow.OPENSEA_CONDUIT_KEY());
        assertEq(receipt.ownerOf(bundleId), buyer);
        assertEq(uint8(escrow.getBundle(bundleId).state), uint8(BundleState.Issued));
        // The seller is paid by withdrawal; so is the royalty recipient.
        assertEq(escrow.claimable(seller, address(mockUsdc)), SALE_PRICE - EXPECTED_ROYALTY - OPENSEA_FEE);
        uint256 sellerBefore = mockUsdc.balanceOf(seller);
        vm.prank(seller);
        escrow.withdraw(address(mockUsdc));
        assertEq(mockUsdc.balanceOf(seller) - sellerBefore, SALE_PRICE - EXPECTED_ROYALTY - OPENSEA_FEE);
        assertEq(escrow.claimable(seller, address(mockUsdc)), 0);
        // zero-royalty-wrapper: the claim answers marketplaces zero; the creator
        // was paid through the escrow ledger instead (checked above).
        (address wrappedRecipient, uint256 wrappedAmount) = receipt.royaltyInfo(bundleId, SALE_PRICE);
        assertEq(wrappedRecipient, address(0));
        assertEq(wrappedAmount, 0);

        vm.prank(buyer);
        receipt.approve(0x1E0049783F008A0085193E00003D00cd54003c71, bundleId);
        vm.expectRevert(NewTradeBundle.NonTransferable.selector);
        SeaportV2Mock(SEAPORT).transferReceipt(address(receipt), buyer, laterHolder, bundleId);
        assertEq(receipt.ownerOf(bundleId), buyer);

        bytes32 holderSalt = keccak256("distinct-final-holder");
        (address expectedFresh,) = escrow.computeFreshAccount(bundleId, buyer, holderSalt);
        vm.prank(laterHolder);
        vm.expectRevert(NewTradeEscrowV2.Unauthorized.selector);
        escrow.redeemToFreshAccount(bundleId, holderSalt);
        vm.prank(attacker);
        vm.expectRevert(NewTradeEscrowV2.Unauthorized.selector);
        escrow.redeemToFreshAccount(bundleId, holderSalt);
        vm.prank(buyer);
        address fresh = escrow.redeemToFreshAccount(bundleId, holderSalt);

        assertEq(fresh, expectedFresh);
        assertEq(fixture.ownerOf(TOKEN_ID), buyer);
        assertEq(mockUsdc.balanceOf(fresh), SEED_UNITS);
        assertEq(mockUsdc.balanceOf(address(vault)), 0);
        assertEq(IERC6551Account(fresh).isValidSigner(buyer, ""), bytes4(0x523e3260));
        assertEq(uint8(escrow.getBundle(bundleId).state), uint8(BundleState.Redeemed));
    }

    function test_RejectsZeroRoyaltyInputs() public {
        vm.expectRevert(RevisedBaseBetaFixture.InvalidRoyalty.selector);
        new RevisedBaseBetaFixture(
            address(registry),
            address(accountProxy),
            address(accountLogic),
            SALT,
            address(0),
            ROYALTY_BPS,
            IMAGE,
            DESCRIPTION
        );
        vm.expectRevert(RevisedBaseBetaFixture.InvalidRoyalty.selector);
        new RevisedBaseBetaFixture(
            address(registry),
            address(accountProxy),
            address(accountLogic),
            SALT,
            royaltyRecipient,
            0,
            IMAGE,
            DESCRIPTION
        );
    }

    function test_RejectsEmptyMetadata() public {
        vm.expectRevert(RevisedBaseBetaFixture.InvalidMetadata.selector);
        new RevisedBaseBetaFixture(
            address(registry),
            address(accountProxy),
            address(accountLogic),
            SALT,
            royaltyRecipient,
            ROYALTY_BPS,
            "",
            DESCRIPTION
        );
        vm.expectRevert(RevisedBaseBetaFixture.InvalidMetadata.selector);
        new RevisedBaseBetaFixture(
            address(registry),
            address(accountProxy),
            address(accountLogic),
            SALT,
            royaltyRecipient,
            ROYALTY_BPS,
            IMAGE,
            ""
        );
    }

    function test_CustodyApprovalRequiresDeployedContract() public {
        vm.expectRevert(abi.encodeWithSelector(FixtureCustodyValidator.InvalidCustody.selector, address(0)));
        validator.setApprovedCustody(address(0), true);
        vm.expectRevert(abi.encodeWithSelector(FixtureCustodyValidator.InvalidCustody.selector, seller));
        validator.setApprovedCustody(seller, true);

        validator.setApprovedCustody(address(registry), true);
        assertTrue(validator.approvedCustody(address(registry)));
        validator.setApprovedCustody(address(registry), false);
        assertFalse(validator.approvedCustody(address(registry)));
    }

    function _deployV2(MockERC20 mockUsdc)
        private
        returns (NewTradeEscrowV2 escrow, NewTradeV2VaultV2 vault, NewTradeBundle receipt)
    {
        vm.etch(SEAPORT, address(new SeaportV2Mock()).code);
        // The conduit is a real operator in this design, so it must exist locally.
        vm.etch(0x1E0049783F008A0085193E00003D00cd54003c71, address(new ConduitMock()).code);
        SeaportV2Mock(SEAPORT).setCounter(42);
        address[] memory payments = new address[](2);
        payments[0] = address(0);
        payments[1] = address(mockUsdc);
        address[] memory assets = new address[](2);
        assets[0] = address(mockUsdc);
        assets[1] = address(fixture);
        AssetKind[] memory kinds = new AssetKind[](2);
        kinds[0] = AssetKind.ERC20;
        kinds[1] = AssetKind.ERC721;
        AcceptanceMode[3] memory modes = [AcceptanceMode.Allowlist, AcceptanceMode.Allowlist, AcceptanceMode.Disabled];

        receipt = BundleDeploy.deploy(address(this), SEAPORT, SEAPORT, address(this));
        NewTradeV2Vault legacyVault = new NewTradeV2Vault(address(this), address(receipt), assets, kinds, modes);
        V2Initialization memory config = V2Initialization(
            address(this),
            address(0xFEE),
            0,
            payments,
            assets,
            kinds,
            modes,
            address(registry),
            address(accountProxy),
            address(accountLogic),
            address(receipt),
            address(legacyVault),
            SEAPORT,
            SEAPORT,
            address(0)
        );
        NewTradeEscrowV2 implementation = new NewTradeEscrowV2();
        escrow = NewTradeEscrowV2(
            payable(address(new ERC1967Proxy(address(implementation), abi.encodeCall(NewTradeEscrowV2.initialize, (config))))
        ));
        receipt.bindController(address(escrow));
        legacyVault.bindController(address(escrow));
        vault = VaultV2Deploy.switchEscrowMirroring(escrow, address(receipt), assets, kinds, modes);
    }
}
