// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {DeployV2} from "./legacy/DeployV2.s.sol";
import {NewTradeEscrowV2} from "../src/NewTradeEscrowV2.sol";
import {NewTradeBundle} from "../src/NewTradeBundle.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {NewTradeV2Vault} from "./legacy/NewTradeV2Vault.sol";
import {AcceptanceMode, AssetKind} from "../src/NewTradeV2Types.sol";
import {MockERC721} from "./mocks/TokenMocks.sol";
import {SeaportV2Mock} from "./helpers/SeaportV2Mock.sol";
import {Mock6551Registry, Mock6551Implementation, MockTokenboundAccountProxy} from "./helpers/ERC6551Mocks.sol";

contract DeployV2RunTest is Test {
    address private constant SEAPORT = 0x0000000000000068F116a894984e2DB1123eB395;
    address private constant REGISTRY = 0x000000006551c19487814612e58FE06813775758;
    address private constant ACCOUNT_PROXY = 0x55266d75D1a14E4572138116aF39863Ed6596E7F;
    address private constant IMPLEMENTATION = 0x41C8f39463A868d3A88af00cd0fe7102F30E44eC;
    address private constant SIGNED_ZONE = 0x000056F7000000EcE9003ca63978907a00FFD100;
    address private constant VALIDATOR = 0xA000027A9B2802E1ddf7000061001e5c005A0000;
    /// Configurable, never hardcoded in the script; the candidate future owner.
    address private constant BUNDLE_OWNER = 0xc3F96C409d26272fDB592c0d04e1D771A7df032e;

    MockERC721 private controllerCollection;

    function setUp() public {
        vm.chainId(8453);
        vm.etch(SEAPORT, address(new SeaportV2Mock()).code);
        vm.etch(REGISTRY, address(new Mock6551Registry()).code);
        Mock6551Implementation logic = new Mock6551Implementation();
        vm.etch(IMPLEMENTATION, address(logic).code);
        vm.etch(ACCOUNT_PROXY, address(new MockTokenboundAccountProxy(address(logic))).code);
        vm.etch(SIGNED_ZONE, address(new SeaportV2Mock()).code);
        vm.etch(VALIDATOR, address(new SeaportV2Mock()).code);
        controllerCollection = new MockERC721();
        vm.setEnv("V2_ADMIN", vm.toString(address(0xA11CE)));
        vm.setEnv("V2_TREASURY", vm.toString(address(0xFEE)));
        vm.setEnv("V2_PROTOCOL_FEE_BPS", "250");
        vm.setEnv("V2_PAYMENT_TOKENS", "0x0000000000000000000000000000000000000000");
        vm.setEnv("V2_ASSET_TOKENS", vm.toString(address(controllerCollection)));
        vm.setEnv("V2_ASSET_KINDS", "1");
        vm.setEnv("V2_ASSET_ACCEPTANCE_MODES", "0,1,0");
        vm.setEnv("V2_BUNDLE_OWNER", vm.toString(BUNDLE_OWNER));
    }

    function test_RunUsesBroadcastAuthorityAndReadsBackPolicy() public {
        DeployV2 script = new DeployV2();
        vm.setEnv("V2_ASSET_ACCEPTANCE_MODES", "0,1");
        vm.expectRevert(DeployV2.InvalidConfiguration.selector);
        script.preflight();
        vm.setEnv("V2_ASSET_ACCEPTANCE_MODES", "0,1,3");
        vm.expectRevert(DeployV2.InvalidConfiguration.selector);
        script.preflight();
        vm.setEnv("V2_ASSET_ACCEPTANCE_MODES", "0,1,0");
        // The receipt owner is required: a zero value must not fall back to the broadcaster.
        vm.setEnv("V2_BUNDLE_OWNER", vm.toString(address(0)));
        vm.expectRevert(DeployV2.InvalidConfiguration.selector);
        script.preflight();
        vm.setEnv("V2_BUNDLE_OWNER", vm.toString(BUNDLE_OWNER));
        DeployV2.Deployed memory deployed = script.run();
        NewTradeEscrowV2 escrow = NewTradeEscrowV2(payable(deployed.proxy));
        NewTradeBundle receipt = NewTradeBundle(deployed.bundle);
        NewTradeV2Vault vault = NewTradeV2Vault(deployed.vault);
        assertEq(receipt.controller(), deployed.proxy);
        assertEq(vault.controller(), deployed.proxy);
        assertEq(escrow.receipt(), deployed.bundle);
        assertEq(escrow.vault(), deployed.vault);
        assertEq(uint8(vault.assetAcceptanceMode(AssetKind.ERC20)), uint8(AcceptanceMode.Disabled));
        assertEq(uint8(vault.assetAcceptanceMode(AssetKind.ERC721)), uint8(AcceptanceMode.Allowlist));
        assertEq(uint8(vault.assetAcceptanceMode(AssetKind.ERC1155)), uint8(AcceptanceMode.Disabled));
        assertTrue(vault.isAssetAllowlisted(address(controllerCollection), AssetKind.ERC721));
        assertTrue(escrow.isPaymentTokenAllowed(address(0)));
        // Ownership is discoverable and configured from the environment.
        assertEq(receipt.owner(), BUNDLE_OWNER);
        assertEq(receipt.getTransferValidator(), VALIDATOR);
        // The receipt is a UUPS proxy over a disabled-initializer implementation,
        // initialized in the same transaction that created it.
        bytes32 implSlot = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
        assertEq(address(uint160(uint256(vm.load(deployed.bundle, implSlot)))), deployed.bundleImplementation);
        // The broadcaster (foundry default sender here) is the bootstrap that bound the controller.
        assertEq(receipt.bootstrap(), 0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38);
        assertEq(receipt.bootstrap(), vault.bootstrap());
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        receipt.initialize(address(this), SEAPORT, VALIDATOR, address(this));
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        NewTradeBundle(deployed.bundleImplementation).initialize(address(this), SEAPORT, VALIDATOR, address(this));
        assertEq(NewTradeBundle(deployed.bundleImplementation).owner(), address(0));
        // Option B: no routed-royalty receiver is deployed; the router slot stays empty.
        assertEq(address(uint160(uint256(vm.load(deployed.proxy, bytes32(uint256(19)))))), address(0));
    }
}
