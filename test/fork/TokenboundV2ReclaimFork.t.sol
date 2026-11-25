// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {NewTradeEscrowV2} from "../../src/NewTradeEscrowV2.sol";
import {NewTradeBundle} from "../../src/NewTradeBundle.sol";
import {BundleDeploy} from "../helpers/BundleDeploy.sol";
import {NewTradeV2Vault} from "../legacy/NewTradeV2Vault.sol";
import {NewTradeV2VaultV2} from "../../src/NewTradeV2VaultV2.sol";
import {VaultV2Deploy, VaultV2Views} from "../helpers/VaultV2Deploy.sol";
import {
    AcceptanceMode,
    AssetKind,
    Bundle,
    BundleState,
    ManifestEntry,
    V2Initialization
} from "../../src/NewTradeV2Types.sol";
import {
    IERC6551Registry,
    IERC6551OwnerAccount,
    ITokenboundAccountProxy
} from "../../src/interfaces/IERC6551.sol";
import {MockERC20, MockERC721, MockERC1155} from "../mocks/TokenMocks.sol";

contract TokenboundReclaimForkZone {
    fallback() external {
        assembly ("memory-safe") {
            mstore(0, shl(224, shr(224, calldataload(0))))
            return(0, 32)
        }
    }
}

contract TokenboundReclaimForkValidator {
    function validateTransfer(address, address, address, uint256) external pure {}
}

contract TokenboundV2ReclaimForkTest is Test {
    using VaultV2Views for NewTradeV2VaultV2;

    address private constant SEAPORT = 0x0000000000000068F116a894984e2DB1123eB395;
    address private constant REGISTRY = 0x000000006551c19487814612e58FE06813775758;
    address private constant ACCOUNT_PROXY = 0x55266d75D1a14E4572138116aF39863Ed6596E7F;
    address private constant IMPLEMENTATION = 0x41C8f39463A868d3A88af00cd0fe7102F30E44eC;
    address private constant SELLER = address(0xA11CE);
    MockERC20 private erc20;
    MockERC721 private controller;
    MockERC721 private extra721;
    MockERC1155 private erc1155;
    NewTradeBundle private receipt;
    NewTradeV2VaultV2 private vault;
    NewTradeEscrowV2 private escrow;

    /// @dev A seller who migrated a manifest out of a real Tokenbound V3 account must be able to
    ///      reclaim an expired bundle straight back into that same account, without the controlling
    ///      NFT ever landing inside the account it controls.
    function test_BaseCanonicalTokenbound_MigratedReclaimReturnsToSourceAccount() public {
        if (SEAPORT.code.length == 0 || REGISTRY.code.length == 0 || ACCOUNT_PROXY.code.length == 0) {
            vm.skip(true);
            return;
        }
        erc20 = new MockERC20("Bundle", "BND", 18);
        controller = new MockERC721();
        extra721 = new MockERC721();
        erc1155 = new MockERC1155();
        controller.mint(SELLER, 1);

        bytes32 sourceSalt = keccak256("canonical-reclaim-source");
        address source =
            IERC6551Registry(REGISTRY).createAccount(ACCOUNT_PROXY, sourceSalt, block.chainid, address(controller), 1);
        ITokenboundAccountProxy(source).initialize(IMPLEMENTATION);
        erc20.mint(source, 20 ether);
        extra721.mint(source, 7);
        erc1155.mint(source, 3, 4);
        _deployProtocol();
        escrow.setMigrationEnabled(true);

        ManifestEntry[] memory manifest = _manifest();
        vm.prank(SELLER);
        controller.approve(address(vault), 1);
        vm.prank(SELLER);
        uint64 deadline = uint64(block.timestamp + 1 days);
        uint256 bundleId =
            escrow.depositFromAccount(source, address(controller), 1, manifest, deadline, keccak256("migration"));

        // Custody is real: every manifest asset left the source account for the vault.
        assertEq(erc20.balanceOf(address(vault)), 20 ether);
        assertEq(extra721.ownerOf(7), address(vault));
        assertEq(erc1155.balanceOf(address(vault), 3), 4);
        assertEq(erc20.balanceOf(source), 0);

        // The bundle expires unsold, so the seller takes it back to where it came from.
        vm.warp(uint256(deadline) + 1);
        vm.prank(SELLER);
        escrow.reclaim(bundleId, source);

        // A1: every manifest asset is back inside the source account.
        assertEq(erc20.balanceOf(source), 20 ether);
        assertEq(extra721.ownerOf(7), source);
        assertEq(erc1155.balanceOf(source, 3), 4);
        assertEq(erc20.balanceOf(address(vault)), 0);
        assertEq(erc1155.balanceOf(address(vault), 3), 0);

        // A2: the controlling NFT went to the seller, not to the extras destination.
        assertEq(controller.ownerOf(1), SELLER);

        // A3: the source account is once again owned by the seller through that NFT.
        assertEq(IERC6551OwnerAccount(source).owner(), SELLER);
        assertEq(vault.accountOwner(source), SELLER);

        // A4: no ownership cycle -- the account bound to (controller, 1) does not hold token 1.
        assertTrue(controller.ownerOf(1) != source);

        // A5: the bundle is terminally Reclaimed and the wrapper is burnt.
        Bundle memory b = escrow.getBundle(bundleId);
        assertTrue(b.state == BundleState.Reclaimed);
        assertFalse(b.everIssued);
    }

    function _deployProtocol() private {
        address[] memory payments = new address[](1);
        payments[0] = address(0);
        address[] memory assets = new address[](4);
        assets[0] = address(erc20);
        assets[1] = address(controller);
        assets[2] = address(extra721);
        assets[3] = address(erc1155);
        AssetKind[] memory kinds = new AssetKind[](4);
        kinds[0] = AssetKind.ERC20;
        kinds[1] = AssetKind.ERC721;
        kinds[2] = AssetKind.ERC721;
        kinds[3] = AssetKind.ERC1155;
        AcceptanceMode[3] memory modes = [AcceptanceMode.Allowlist, AcceptanceMode.Allowlist, AcceptanceMode.Allowlist];
        address validator = address(new TokenboundReclaimForkValidator());
        address zone = address(new TokenboundReclaimForkZone());
        receipt = BundleDeploy.deploy(address(this), SEAPORT, validator, address(this));
        NewTradeV2Vault legacyVault = new NewTradeV2Vault(address(this), address(receipt), assets, kinds, modes);
        V2Initialization memory config = V2Initialization(
            address(this),
            SELLER,
            0,
            payments,
            assets,
            kinds,
            modes,
            REGISTRY,
            ACCOUNT_PROXY,
            IMPLEMENTATION,
            address(receipt),
            address(legacyVault),
            validator,
            zone,
            address(0)
        );
        NewTradeEscrowV2 logic = new NewTradeEscrowV2();
        escrow = NewTradeEscrowV2(
            payable(address(new ERC1967Proxy(address(logic), abi.encodeCall(NewTradeEscrowV2.initialize, (config)))))
        );
        receipt.bindController(address(escrow));
        legacyVault.bindController(address(escrow));
        vault = VaultV2Deploy.switchEscrowMirroring(escrow, address(receipt), assets, kinds, modes);
    }

    function _manifest() private view returns (ManifestEntry[] memory manifest) {
        manifest = new ManifestEntry[](3);
        manifest[0] = ManifestEntry(AssetKind.ERC20, address(erc20), 0, 20 ether);
        manifest[1] = ManifestEntry(AssetKind.ERC721, address(extra721), 7, 1);
        manifest[2] = ManifestEntry(AssetKind.ERC1155, address(erc1155), 3, 4);
    }
}
