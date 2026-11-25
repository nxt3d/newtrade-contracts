// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {NewTradeBundle} from "../src/NewTradeBundle.sol";
import {BundleDeploy} from "./helpers/BundleDeploy.sol";
import {CardTestKit} from "./helpers/BundleCardHelpers.sol";
import {CardController, CardValidator} from "./BundleCard.t.sol";

/*
  op2-review-bundle-image-modular-sep25: an INDEPENDENT set of hostile inputs,
  written without op's renderers. The property: `tokenURI` never reverts and never
  emits broken JSON, whatever the renderer does and whatever sits in the base
  URLs - and the defaults are today's JSON exactly.
*/

/// Answers exactly `raw` as return data (any bytes, any shape).
contract Op2Raw {
    bytes internal raw;
    constructor(bytes memory raw_) { raw = raw_; }
    fallback() external {
        bytes memory r = raw;
        assembly { return(add(r, 32), mload(r)) }
    }
}

/// A well-formed ABI string answer.
contract Op2Answer {
    string internal answer;
    constructor(string memory a) { answer = a; }
    function imageURI(uint256, address, uint256) external view returns (string memory) { return answer; }
}

/// Burns every unit of gas it is given.
contract Op2Burner {
    function imageURI(uint256, address, uint256) external view returns (string memory) {
        while (true) { if (gasleft() == 0) break; }
        return "never";
    }
}

/// Reverts with a large reason (returndata the caller must not copy blindly).
contract Op2BigRevert {
    function imageURI(uint256, address, uint256) external pure returns (string memory) {
        assembly { revert(0, 100000) }
    }
}

contract BundleImageOp2ReviewTest is Test {
    NewTradeBundle bundle;
    CardController controller;
    address constant NFT = 0xf4fd1a2Ea84a16Be24848Aa6f4242E9CAab18953;
    bytes32 constant MANIFEST = 0xbdd635db3c38b33ba593a6c357dd902125c8c579fb970f5845636bda8d5f9d6a;
    bytes32 constant LOC = 0x92e9f748b197c8df37e6f357621b4b56a147841660aafbfb660fb6e6ea2d0d00;
    bytes defaultJson;

    event BatchMetadataUpdate(uint256 _fromTokenId, uint256 _toTokenId);

    function setUp() public {
        controller = new CardController();
        // This test contract is the bootstrap AND the owner (the fourth argument).
        bundle = BundleDeploy.deploy(address(this), address(0x5EA), address(new CardValidator()), address(this));
        bundle.bindController(address(controller));
        controller.set(3, NFT, 104, MANIFEST);
        controller.mint(bundle, 3);
        defaultJson = CardTestKit.jsonOf(bundle.tokenURI(3));
    }

    /// tokenURI under a bounded gas budget: it must SUCCEED, and return the JSON.
    function _uri(uint256 gasBudget) internal view returns (bytes memory json) {
        (bool ok, bytes memory ret) = address(bundle).staticcall{gas: gasBudget}(abi.encodeCall(bundle.tokenURI, (3)));
        assertTrue(ok, "tokenURI must never revert");
        json = CardTestKit.jsonOf(abi.decode(ret, (string)));
    }

    function _withRenderer(address r) internal returns (bytes memory) {
        bundle.setImageRenderer(r);
        return _uri(30_000_000);
    }

    // ---------------------------------------------------------------- defaults

    function test_Defaults_NoExternalUrlKey_NoImageBase_NoRenderer() public view {
        assertEq(bundle.imageRenderer(), address(0));
        assertEq(bytes(bundle.imageBaseURI()).length, 0);
        assertEq(bytes(bundle.externalBaseURI()).length, 0);
        assertFalse(CardTestKit.contains(defaultJson, bytes('"external_url"')), "the key is ABSENT while unset");
    }

    // ------------------------------------------- hostile renderers: fall back

    function test_HostileRenderers_AllFallBackToTheDefaultJsonExactly() public {
        bytes[] memory raws = new bytes[](9);
        raws[0] = "";                                                     // empty return data
        raws[1] = abi.encode(uint256(32));                                 // offset only
        raws[2] = abi.encode(uint256(64), uint256(1), bytes32("x"));       // wrong offset
        raws[3] = abi.encode(uint256(32), uint256(1_000_000));             // length beyond the data
        raws[4] = abi.encode("");                                          // empty string
        raws[5] = abi.encode('ipfs://a/"},"x":"');                        // quote injection
        raws[6] = abi.encode("ipfs://a/\\u0000");                           // backslash
        raws[7] = abi.encode(string(abi.encodePacked("ipfs://a/", bytes1(0x0a)))); // control byte
        raws[8] = abi.encode(string(abi.encodePacked("ipfs://a/", bytes1(0xff)))); // non-ASCII
        for (uint256 i; i < raws.length; ++i) {
            assertEq(_withRenderer(address(new Op2Raw(raws[i]))), defaultJson, string.concat("raw case ", vm.toString(i)));
        }
        assertEq(_withRenderer(address(new Op2Answer(string(abi.encodePacked("ipfs://a/", bytes1(0x7f)))))), defaultJson, "DEL");
        assertEq(_withRenderer(address(new Op2Answer(string(new bytes(16_385))))), defaultJson, "16 KB + 1 (NULs)");
        assertEq(_withRenderer(address(new Op2BigRevert())), defaultJson, "revert with 100 KB of data");
        assertEq(_withRenderer(address(0xdead)), defaultJson, "EOA renderer");
        assertEq(_withRenderer(address(0x04)), defaultJson, "identity precompile echoes the calldata");
    }

    function test_AnySchemeIsServed_IpfsArDataHttpsSchemeless() public {
        string[5] memory ok = ["ipfs://bafy/3.svg", "ar://tx/3", "data:image/png;base64,AAAA", "https://x.example/3", "just-a-name"];
        for (uint256 i; i < ok.length; ++i) {
            bytes memory json = _withRenderer(address(new Op2Answer(ok[i])));
            assertTrue(CardTestKit.contains(json, abi.encodePacked('"image":"', ok[i], '",')), ok[i]);
        }
    }

    // ---------------------------------------------------------------- gas cap

    function test_GasBurningRenderer_CannotBreakTokenUri_UnderATenMillionBudget() public {
        bundle.setImageRenderer(address(new Op2Burner()));
        // IMAGE_GAS caps the renderer at 2M; the rest of tokenURI still has room.
        assertEq(_uri(10_000_000), defaultJson);
    }

    // --------------------------------------- base URLs: set time and render time

    function test_BaseUrls_SetTimeRefusesInjection_AnySchemeAccepted() public {
        bytes[5] memory bad = [bytes('https://a/"'), bytes("https://a/\\"), abi.encodePacked("ipfs://a/", bytes1(0x09)), abi.encodePacked("ar://a/", bytes1(0x80)), new bytes(257)];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(NewTradeBundle.InvalidBaseURI.selector);
            bundle.setImageBaseURI(string(bad[i]));
            vm.expectRevert(NewTradeBundle.InvalidBaseURI.selector);
            bundle.setExternalBaseURI(string(bad[i]));
        }
        bundle.setImageBaseURI("ipfs://cid/");
        bundle.setExternalBaseURI("ar://tx/");
        bytes memory json = _uri(30_000_000);
        assertTrue(CardTestKit.contains(json, bytes('"image":"ipfs://cid/3","external_url":"ar://tx/3",')));
    }

    /// A value that got into storage WITHOUT the setter (a future bug, a storage
    /// collision) is still refused at render time: the image falls back, the key is omitted.
    function test_RenderTimeRecheck_HostileStoredBases_FallBackAndOmit() public {
        // Short strings live in the slot itself: data left-aligned, length*2 in the low byte.
        bytes32 hostile = bytes32(abi.encodePacked("x://a/", bytes1(0x22), bytes1(0x0a))) | bytes32(uint256(8 * 2));
        vm.store(address(bundle), bytes32(uint256(LOC) + 1), hostile); // imageBaseURI
        vm.store(address(bundle), bytes32(uint256(LOC) + 2), hostile); // externalBaseURI
        assertEq(bytes(bundle.imageBaseURI()).length, 8, "the hostile value is really stored");
        assertEq(_uri(30_000_000), defaultJson, "card image, no external_url key");
    }

    // ---------------------------------------------------------------- ERC-4906

    function test_Erc4906_EverySetterAnnounces_OnlyTheOwnerSets() public {
        assertTrue(bundle.supportsInterface(0x49064906));
        vm.expectEmit(address(bundle));
        emit BatchMetadataUpdate(0, type(uint256).max);
        bundle.setImageRenderer(address(0x1234));
        vm.expectEmit(address(bundle));
        emit BatchMetadataUpdate(0, type(uint256).max);
        bundle.setImageBaseURI("ipfs://x/");
        vm.expectEmit(address(bundle));
        emit BatchMetadataUpdate(0, type(uint256).max);
        bundle.setExternalBaseURI("ar://y/");

        address stranger = address(0x5713);
        vm.startPrank(stranger);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, stranger));
        bundle.setImageRenderer(address(0));
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, stranger));
        bundle.setImageBaseURI("");
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, stranger));
        bundle.setExternalBaseURI("");
        vm.stopPrank();
    }
}
