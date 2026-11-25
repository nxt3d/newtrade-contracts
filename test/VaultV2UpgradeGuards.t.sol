// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {NewTradeV2VaultV2} from "../src/NewTradeV2VaultV2.sol";
import {NewTradeV2VaultStorage} from "../src/NewTradeV2VaultStorage.sol";
import {NewTradeEscrowV2} from "../src/NewTradeEscrowV2.sol";
import {AcceptanceMode, AssetKind, ManifestEntry, ReleaseMode} from "../src/NewTradeV2Types.sol";
import {MockERC20, MockERC721, MockERC1155} from "./mocks/TokenMocks.sol";
import {ToggleReleaseFailureERC20} from "./helpers/ERC6551Mocks.sol";
import {VaultV2Deploy, VaultV2Views} from "./helpers/VaultV2Deploy.sol";

contract GuardStub {}

contract WrongFamily {
    bytes32 public constant VAULT_FAMILY = keccak256("something.else");
}

/// The next vault implementation: same storage, one more function.
contract NewTradeV2VaultV2Next is NewTradeV2VaultV2 {
    function nextMarker() external pure returns (uint256) {
        return 2;
    }
}

/// During its release transfer this token tries to upgrade the vault. It holds the
/// upgrader role, so only the custody lock can be what refuses it.
contract UpgradingERC20 is ERC20 {
    NewTradeV2VaultV2 public vault;
    address public next;
    bytes public caught;
    bool public tried;

    constructor() ERC20("U", "U") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function arm(NewTradeV2VaultV2 vault_, address next_) external {
        vault = vault_;
        next = next_;
    }

    function upgradeNow(address target) external {
        vault.upgradeToAndCall(target, "");
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (address(vault) != address(0) && from == address(vault)) {
            tried = true;
            try vault.upgradeToAndCall(next, "") {
                caught = "";
            } catch (bytes memory reason) {
                caught = reason;
            }
        }
        super._update(from, to, amount);
    }
}

/// @notice Upgrade guards and custody preservation of the vault (design 2A.3, test
/// plan 11). The test contract is the controller and answers `hasRole`.
contract VaultV2UpgradeGuardsTest is Test {
    using VaultV2Views for NewTradeV2VaultV2;

    bytes32 constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    uint256 constant NFT_BIT = 1 << 32;

    mapping(address => bool) upgrader;
    NewTradeV2VaultV2 vault;
    address receipt;
    MockERC20 erc20;
    ToggleReleaseFailureERC20 toggle;
    MockERC721 control;
    MockERC1155 erc1155;
    address seller = makeAddr("seller");
    address admin = makeAddr("admin");
    address stranger = makeAddr("stranger");
    address extrasTo = makeAddr("extrasTo");

    function hasRole(bytes32 role, address who) external view returns (bool) {
        return role == UPGRADER_ROLE && upgrader[who];
    }

    function setUp() public {
        upgrader[admin] = true;
        receipt = address(new GuardStub());
        AcceptanceMode[3] memory wild = [AcceptanceMode.Wildcard, AcceptanceMode.Wildcard, AcceptanceMode.Wildcard];
        vault = VaultV2Deploy.deployProxy(address(this), receipt, wild);
        erc20 = new MockERC20("G", "G", 18);
        toggle = new ToggleReleaseFailureERC20();
        control = new MockERC721();
        erc1155 = new MockERC1155();
        erc20.mint(seller, 1000);
        toggle.mint(seller, 1000);
        erc1155.mint(seller, 3, 100);
        vm.startPrank(seller);
        erc20.approve(address(vault), type(uint256).max);
        toggle.approve(address(vault), type(uint256).max);
        control.setApprovalForAll(address(vault), true);
        erc1155.setApprovalForAll(address(vault), true);
        vm.stopPrank();
    }

    function _next() internal returns (address) {
        return address(new NewTradeV2VaultV2Next());
    }

    function _entries(address t20, uint256 amount) internal view returns (ManifestEntry[] memory es) {
        es = new ManifestEntry[](2);
        es[0] = ManifestEntry(AssetKind.ERC20, t20, 0, amount);
        es[1] = ManifestEntry(AssetKind.ERC1155, address(erc1155), 3, 4);
    }

    function _deposit(uint256 id, address t20, uint256 amount) internal {
        control.mint(seller, id);
        vault.deposit(id, seller, address(control), id, _entries(t20, amount));
    }

    // ------------------------------------------------------------ initialization

    function test_InitializeCannotBeRepeated() public {
        AcceptanceMode[3] memory disabled;
        vm.prank(stranger);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        vault.initialize(stranger, stranger, disabled);
        assertEq(vault.controller(), address(this));
    }

    function test_ImplementationCannotBeInitialized() public {
        AcceptanceMode[3] memory disabled;
        NewTradeV2VaultV2 impl = NewTradeV2VaultV2(vault.implementation());
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(address(this), receipt, disabled);
    }

    function test_InitializeRefusesAddressesWithoutCode() public {
        AcceptanceMode[3] memory disabled;
        address impl = address(new NewTradeV2VaultV2());
        vm.expectRevert(NewTradeV2VaultV2.ZeroAddress.selector);
        new ERC1967Proxy(impl, abi.encodeCall(NewTradeV2VaultV2.initialize, (address(0x1234), receipt, disabled)));
        vm.expectRevert(NewTradeV2VaultV2.ZeroAddress.selector);
        new ERC1967Proxy(impl, abi.encodeCall(NewTradeV2VaultV2.initialize, (address(this), address(0x1234), disabled)));
    }

    function test_ControllerHasNoSetter() public {
        for (uint256 i; i < 3; ++i) {
            bytes4 sel = [
                bytes4(keccak256("bindController(address)")),
                bytes4(keccak256("setController(address)")),
                bytes4(keccak256("setReceipt(address)"))
            ][i];
            (bool ok,) = address(vault).call(abi.encodeWithSelector(sel, stranger));
            assertFalse(ok);
        }
        assertEq(vault.controller(), address(this));
        assertEq(vault.receipt(), receipt);
    }

    function test_ImplementationViewMatchesTheSlot() public {
        address impl = address(uint160(uint256(vm.load(address(vault), IMPL_SLOT))));
        assertEq(vault.implementation(), impl);
        address next = _next();
        vm.prank(admin);
        vault.upgradeToAndCall(next, "");
        assertEq(vault.implementation(), next);
    }

    // ------------------------------------------------------------ who and what

    function test_NonUpgraderCannotUpgrade() public {
        address next = _next();
        vm.prank(stranger);
        vm.expectRevert(NewTradeV2VaultV2.UpgradeRefused.selector);
        vault.upgradeToAndCall(next, "");
    }

    function test_FamilyCheckRefusesEverythingButAVault() public {
        address[4] memory bad = [
            address(new NewTradeEscrowV2()),
            deployCode("NewTradeEscrowV2Seeder.sol:NewTradeEscrowV2Seeder"),
            address(new WrongFamily()),
            address(new GuardStub())
        ];
        for (uint256 i; i < bad.length; ++i) {
            vm.prank(admin);
            vm.expectRevert(NewTradeV2VaultV2.UpgradeRefused.selector);
            vault.upgradeToAndCall(bad[i], "");
        }
        vm.prank(admin);
        vm.expectRevert(NewTradeV2VaultV2.UpgradeRefused.selector);
        vault.upgradeToAndCall(stranger, "");
    }

    function test_LockIsOneWayAndRoleGated() public {
        vm.prank(stranger);
        vm.expectRevert(NewTradeV2VaultV2.UpgradeRefused.selector);
        vault.lockUpgrades();
        vm.prank(admin);
        vault.lockUpgrades();
        vm.prank(admin);
        vm.expectRevert(NewTradeV2VaultV2.UpgradeRefused.selector);
        vault.lockUpgrades();
        address next = _next();
        vm.prank(admin);
        vm.expectRevert(NewTradeV2VaultV2.UpgradeRefused.selector);
        vault.upgradeToAndCall(next, "");
    }

    function test_UpgradeRefusedWhileCustodyLockIsHeld() public {
        UpgradingERC20 token = new UpgradingERC20();
        token.mint(seller, 100);
        vm.prank(seller);
        token.approve(address(vault), type(uint256).max);
        upgrader[address(token)] = true;
        ManifestEntry[] memory es = new ManifestEntry[](1);
        es[0] = ManifestEntry(AssetKind.ERC20, address(token), 0, 100);
        control.mint(seller, 9);
        vault.deposit(9, seller, address(control), 9, es);
        address before = vault.implementation();
        token.arm(vault, _next());
        vault.beginRelease(9, ReleaseMode.Reclaim, extrasTo, seller);
        assertTrue(token.tried());
        assertEq(token.caught(), abi.encodeWithSelector(NewTradeV2VaultV2.UpgradeRefused.selector));
        assertEq(vault.implementation(), before);
        // The same token, outside the lock, may upgrade: the refusal above was the lock.
        address next = _next();
        token.upgradeNow(next);
        assertEq(vault.implementation(), next);
    }

    function test_AttemptIsOnlyForTheVaultDuringABatch() public {
        _deposit(1, address(erc20), 10);
        vm.prank(stranger);
        vm.expectRevert(NewTradeV2VaultV2.ControllerOnly.selector);
        vault.attempt(1, 0);
        vm.prank(address(vault));
        vm.expectRevert(NewTradeV2VaultV2.ControllerOnly.selector);
        vault.attempt(1, 0);
    }

    // ------------------------------------------------------------ custody preserved

    function _digest(uint256 id) internal view returns (bytes32) {
        (NewTradeV2VaultStorage.Custody memory c, NewTradeV2VaultStorage.ReleaseRecord memory r, uint256 held) =
            vault.bundleStatus(id);
        return keccak256(abi.encode(c, r, held, vault.getManifest(id)));
    }

    function test_UpgradeWithCustodyInPlacePreservesEverythingAndExitsComplete() public {
        // #1 deposited, untouched. #2 release begun, ERC-20 held.
        _deposit(1, address(erc20), 10);
        _deposit(2, address(toggle), 20);
        toggle.setFailRelease(true);
        vault.beginRelease(2, ReleaseMode.Reclaim, extrasTo, seller);
        (,, uint256 held) = vault.bundleStatus(2);
        assertEq(held, 1, "only the toggled ERC-20 is held");

        bytes32 d1 = _digest(1);
        bytes32 d2 = _digest(2);
        uint256 revision = vault.assetPolicyRevision();
        uint256 l20 = vault.erc20Liability(address(erc20));
        uint256 lToggle = vault.erc20Liability(address(toggle));
        uint256 l1155 = vault.erc1155Liability(address(erc1155), 3);

        address next = _next();
        vm.prank(admin);
        vault.upgradeToAndCall(next, "");
        assertEq(NewTradeV2VaultV2Next(address(vault)).nextMarker(), 2);

        assertEq(_digest(1), d1, "bundle 1");
        assertEq(_digest(2), d2, "bundle 2");
        assertEq(vault.controller(), address(this));
        assertEq(vault.receipt(), receipt);
        assertEq(vault.assetPolicyRevision(), revision);
        assertEq(uint8(vault.assetAcceptanceMode(AssetKind.ERC20)), uint8(AcceptanceMode.Wildcard));
        assertEq(vault.erc20Liability(address(erc20)), l20);
        assertEq(vault.erc20Liability(address(toggle)), lToggle);
        assertEq(vault.erc1155Liability(address(erc1155), 3), l1155);

        // Exits complete through the new implementation.
        toggle.setFailRelease(false);
        assertTrue(vault.releaseRemaining(2, 1, stranger, ""));
        assertEq(toggle.balanceOf(extrasTo), 20);
        assertTrue(vault.beginRelease(1, ReleaseMode.Reclaim, extrasTo, seller));
        assertEq(erc20.balanceOf(extrasTo), 10);
        assertEq(control.ownerOf(1), seller);
        assertEq(erc1155.balanceOf(extrasTo, 3), 8);
        assertEq(vault.erc1155Liability(address(erc1155), 3), 0);
    }
}
