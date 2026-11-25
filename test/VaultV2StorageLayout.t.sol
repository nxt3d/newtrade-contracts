// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {NewTradeV2VaultV2} from "../src/NewTradeV2VaultV2.sol";
import {NewTradeV2VaultStorage} from "../src/NewTradeV2VaultStorage.sol";
import {AcceptanceMode, AssetKind, BundleState, ManifestEntry, ReleaseMode} from "../src/NewTradeV2Types.sol";
import {MockERC20, MockERC721, MockERC1155} from "./mocks/TokenMocks.sol";
import {VaultV2Deploy} from "./helpers/VaultV2Deploy.sol";

contract LayoutCodeStub {}

/// @notice Pins the vault's ERC-7201 namespace by READING IT BACK: real state is
/// written through the proxy and every field is loaded from its expected slot, so a
/// reorder or retype in NewTradeV2VaultStorage fails here under `forge test`.
/// test/layout/check_storage_layout.py is the complementary type-level gate (it also
/// covers `Expected`, which is only populated inside a transfer callback).
contract VaultV2StorageLayoutTest is Test {
    bytes32 constant BASE = NewTradeV2VaultStorage.VAULT_STORAGE_LOCATION;

    NewTradeV2VaultV2 vault;
    address receipt;
    MockERC20 erc20;
    MockERC721 control;
    MockERC721 extra721;
    MockERC1155 erc1155;
    address seller = makeAddr("seller");
    address extrasTo = makeAddr("extrasTo");
    address nftTo = makeAddr("nftTo");

    function setUp() public {
        receipt = address(new LayoutCodeStub());
        AcceptanceMode[3] memory modes = [AcceptanceMode.Wildcard, AcceptanceMode.Allowlist, AcceptanceMode.Wildcard];
        vault = VaultV2Deploy.deployProxy(address(this), receipt, modes);
        erc20 = new MockERC20("L", "L", 18);
        control = new MockERC721();
        extra721 = new MockERC721();
        erc1155 = new MockERC1155();
        vault.setAssetKind(address(control), AssetKind.ERC721, true);
        vault.setAssetKind(address(extra721), AssetKind.ERC721, true);
        control.mint(seller, 1);
        extra721.mint(seller, 7);
        erc20.mint(seller, 50);
        erc1155.mint(seller, 3, 9);
        vm.startPrank(seller);
        control.setApprovalForAll(address(vault), true);
        extra721.setApprovalForAll(address(vault), true);
        erc20.approve(address(vault), type(uint256).max);
        erc1155.setApprovalForAll(address(vault), true);
        vm.stopPrank();
    }

    function _slot(uint256 i) internal pure returns (bytes32) {
        return bytes32(uint256(BASE) + i);
    }

    function _load(bytes32 s) internal view returns (uint256) {
        return uint256(vm.load(address(vault), s));
    }

    function _map(bytes32 key, bytes32 slot) internal pure returns (bytes32) {
        return keccak256(abi.encode(key, slot));
    }

    function _addr(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }

    function test_NamespaceConstantIsTheErc7201Formula() public pure {
        bytes32 h = keccak256(abi.encode(uint256(keccak256("newtrade.storage.V2Vault")) - 1)) & ~bytes32(uint256(0xff));
        assertEq(BASE, h);
    }

    function test_EnumNumbersAreFrozen() public pure {
        assertEq(uint8(BundleState.Issued), 3);
        assertEq(uint8(BundleState.Redeemed), 4);
        assertEq(uint8(BundleState.Reclaimed), 5);
        assertEq(uint8(BundleState.Redeeming), 6);
        assertEq(uint8(BundleState.Reclaiming), 7);
        assertEq(uint8(ReleaseMode.Redeem), 0);
        assertEq(uint8(ReleaseMode.Reclaim), 1);
        assertEq(uint8(AssetKind.ERC20), 0);
        assertEq(uint8(AssetKind.ERC721), 1);
        assertEq(uint8(AssetKind.ERC1155), 2);
    }

    function test_EveryFieldIsWhereTheLayoutSays() public {
        assertEq(_load(_slot(0)), uint160(address(this)), "controller");
        assertEq(_load(_slot(1)), uint160(receipt), "receipt, flags clear");
        assertEq(_load(_slot(2)), uint256(2) | (uint256(1) << 8) | (uint256(2) << 16), "acceptance modes, packed");
        assertEq(_load(_slot(3)), 3, "policy revision: 1 + two allowlist writes");
        assertEq(_load(_map(_addr(address(control)), _slot(11))), 2, "allowlist: ERC721 + 1");

        ManifestEntry[] memory es = new ManifestEntry[](3);
        es[0] = ManifestEntry(AssetKind.ERC20, address(erc20), 0, 20);
        es[1] = ManifestEntry(AssetKind.ERC721, address(extra721), 7, 1);
        es[2] = ManifestEntry(AssetKind.ERC1155, address(erc1155), 3, 4);
        vault.deposit(42, seller, address(control), 1, es);

        bytes32 arr = _map(bytes32(uint256(42)), _slot(4));
        assertEq(_load(arr), 3, "manifest length");
        uint256 first = uint256(keccak256(abi.encode(arr)));
        // ManifestEntry is FROZEN at three slots: kind and token packed, tokenId, amount.
        assertEq(
            _load(bytes32(first + 3)), uint256(1) | (uint256(uint160(address(extra721))) << 8), "entry 1 kind+token"
        );
        assertEq(_load(bytes32(first + 4)), 7, "entry 1 tokenId");
        assertEq(_load(bytes32(first + 5)), 1, "entry 1 amount");
        assertEq(_load(bytes32(first + 8)), 4, "entry 2 amount");

        bytes32 c = _map(bytes32(uint256(42)), _slot(5));
        assertEq(_load(c), uint160(address(control)), "custody.nft");
        assertEq(_load(bytes32(uint256(c) + 1)), 1, "custody.nftId");
        assertEq(_load(bytes32(uint256(c) + 2)), 1, "custody.exists");

        assertEq(_load(_map(_addr(address(erc20)), _slot(7))), 20, "erc20Liability");
        bytes32 inner1155 = _map(_addr(address(erc1155)), _slot(8));
        assertEq(_load(_map(bytes32(uint256(3)), inner1155)), 4, "erc1155Liability");
        bytes32 inner721 = _map(_addr(address(extra721)), _slot(9));
        assertEq(_load(_map(bytes32(uint256(7)), inner721)), 1, "erc721Reserved");
        assertEq(_load(_map(_addr(address(erc20)), _slot(10))), 20, "assetLiabilityUnits");
        assertEq(_load(_map(_addr(address(erc1155)), _slot(12))), 3, "custodyKindPlusOne: ERC1155 + 1");

        vault.beginRelease(42, ReleaseMode.Reclaim, extrasTo, nftTo);
        bytes32 r = _map(bytes32(uint256(42)), _slot(6));
        assertEq(
            _load(r),
            uint256(1) | (uint256(0) << 8) | (uint256(1) << 16) | (uint256(uint160(extrasTo)) << 24),
            "record: initialized, redirected, mode, extrasTo"
        );
        uint256 mask = (uint256(1) << 32) | 7;
        assertEq(_load(bytes32(uint256(r) + 1)), uint256(uint160(nftTo)) | (mask << 160), "record: nftTo, releasedMask");
    }

    function test_MigrationNoncesAndFlagsSlots() public {
        vault.setMigrationEnabled(true);
        assertEq(_load(_slot(1)), uint160(receipt) | (uint256(1) << 168), "migrationEnabled at offset 21");
    }
}
