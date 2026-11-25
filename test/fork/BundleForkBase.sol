// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {NewTradeBundle} from "../../src/NewTradeBundle.sol";
import {ICreatorToken} from "../../src/interfaces/ICreatorToken.sol";
import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import {CardTestKit} from "../helpers/BundleCardHelpers.sol";

/// The live Base Bundle NFT as the fork suites see it: its addresses, the
/// pre-image fixture, the owner read live, the 19 observed facts and the 4
/// transfer/mint/burn probes. Every derived test returns early without a fork
/// (the proxy has no code), so a run WITHOUT a URL proves nothing.
abstract contract BundleForkBase is Test {
    address constant PROXY = 0x59900b207ea703B0bBcF8fD84C5E11dE46826185;
    /// The owner since the accept tx 0xd7fc5c99…0536 (block 51,776,515). Asserted against the live `owner()`.
    address constant EXPECTED_OWNER = 0xF8e03bd4436371E0e2F7C02E529b2172fe72b4EF;
    address constant PREVIOUS_OWNER = 0xc3F96C409d26272fDB592c0d04e1D771A7df032e;
    address constant ESCROW = 0xCc29F5c82C8b7c01Cac6036047E7413Df458f86d;
    /// The card implementation, live since upgrade tx 0x11b21767…d4ae (block 51,785,015), source b2d15e2.
    address constant CARD_IMPLEMENTATION = 0x9Cc108E3FEa007715896d8c97fBC7c35EC430207;
    uint256 constant UPGRADE_BLOCK = 51_785_015;
    /// The implementation before the upgrade: the rollback target.
    address constant PREVIOUS_IMPLEMENTATION = 0x19BE700bf6744253A36FB14E7d8d6a55b8B0b40F;
    /// The MODULAR image implementation, live since upgrade tx 0xd9ee6a3b…7067
    /// (block 51,798,691), source 4fb124c (bundle-image-modular-upgrade-sep25).
    address constant MODULAR_IMPLEMENTATION = 0x29DaD81D121CaB79343A191EeB071317858319d6;
    uint256 constant MODULAR_UPGRADE_BLOCK = 51_798_691;
    /// the renderer 0x4519…56c5, installed by setImageRenderer tx 0x4140547f…b937 (block 51,798,695).
    address constant IMAGE_RENDERER_V1 = 0x4519D5429391aA6bBcBB33ad248470d5e45856c5;
    /// The NON-TRANSFERABLE implementation (bundle-non-transferable-sep26), live since
    /// upgradeToAndCall at block 51,863,513 (deployed at 51,863,175); masked runtime sha256
    /// 5267ae0c…7581 per deployments/base-mainnet-2026-09-27-bundle-non-transferable-upgrade.md.
    address constant NON_TRANSFERABLE_IMPLEMENTATION = 0x9182dC376e13d4d26612cDA495C41906592d8ab3;
    uint256 constant NON_TRANSFERABLE_UPGRADE_BLOCK = 51_863_513;
    /// bundle-fork-repin-sep27: the blocks the HISTORICAL suites are pinned at (their RUN lines).
    /// BundleCardUpgradeFork and BundleImageModularUpgradeFork: the card world.
    uint256 constant CARD_SUITES_BLOCK = 51_785_106;
    /// BundleImageModularLiveFork and its Op2 companion: the modular world.
    uint256 constant MODULAR_LIVE_SUITES_BLOCK = 51_798_787;
    bytes32 constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    uint256 constant BUNDLE = 3;

    /// The OLD JSON: `tokenURI(3)` as read from Base at block 51,774,972 (before the
    /// upgrade), base64-decoded. The live JSON is this plus one `"image":"…",` segment.
    uint256 constant FIXTURE_BLOCK = 51_774_972;
    string constant FIXTURE_JSON =
        '{"name":"NewTrade Bundle #3","description":"NewTrade Bundle NFT: a transferable claim on a vault-held asset bundle. This Bundle NFT is not the underlying collection NFT.","attributes":[{"trait_type":"Asset Type","value":"NewTrade Bundle NFT"},{"trait_type":"Bundle ID","value":"3"},{"trait_type":"Original NFT Contract","value":"0xf4fd1a2ea84a16be24848aa6f4242e9caab18953"},{"trait_type":"Original NFT Token ID","value":"104"},{"trait_type":"Manifest Hash","value":"0xbdd635db3c38b33ba593a6c357dd902125c8c579fb970f5845636bda8d5f9d6a"}],"properties":{"schema":"newtrade.bundle.v2","chain_id":"8453","bundle_id":"3","original_nft_contract":"0xf4fd1a2ea84a16be24848aa6f4242e9caab18953","original_nft_token_id":"104","original_asset":"eip155:8453/erc721:0xf4fd1a2ea84a16be24848aa6f4242e9caab18953/104","bundle_asset":"eip155:8453/erc721:0x59900b207ea703b0bbcf8fd84c5e11de46826185/3","manifest_hash":"0xbdd635db3c38b33ba593a6c357dd902125c8c579fb970f5845636bda8d5f9d6a"}}';

    /// The deployable build: `out/NewTradeBundle.sol/NewTradeBundle.json`, what
    /// `forge build` produces and the user deploys. NOT `new NewTradeBundle()`: the
    /// copy compiled into a test contract is a different bytecode (13,969 B runtime,
    /// measured), so it would prove nothing about 0x9Cc1….
    string constant ARTIFACT = "NewTradeBundle.sol:NewTradeBundle";

    bool forked;
    NewTradeBundle bundle = NewTradeBundle(PROXY);

    function setUp() public {
        forked = PROXY.code.length > 0 && ESCROW.code.length > 0;
    }

    /// HISTORICAL-suite gate (bundle-fork-repin-sep27). Without a fork: false, and the test
    /// returns early as before. At any block other than `pinned`: the test is SKIPPED with
    /// the reason - it never runs against a world it does not describe, and never passes
    /// silently there. At `pinned`: true, and the test runs.
    function _atPinnedBlock(uint256 pinned) internal returns (bool) {
        if (!forked) return false;
        if (block.number != pinned) {
            vm.skip(
                true,
                string.concat(
                    "HISTORICAL suite pinned at block ", vm.toString(pinned), "; this fork is at block ",
                    vm.toString(block.number), " - run it with --fork-block-number ", vm.toString(pinned)
                )
            );
            return false;
        }
        return true;
    }

    struct Observed {
        address owner;
        address pendingOwner;
        address ownerOf3;
        address controller;
        address bootstrap;
        address seaport;
        address validator;
        bytes4 validationSelector;
        bool validationIsView;
        address royaltyTo;
        uint256 royaltyAmount;
        bool[8] interfaces;
        string name;
        string symbol;
        uint256 escrowBalance;
        bool firstExitNotified3;
        bytes32[5] slots;
        bytes32[4] namespaced;
    }

    function _observe() internal view returns (Observed memory o) {
        o.owner = bundle.owner();
        o.pendingOwner = bundle.pendingOwner();
        o.ownerOf3 = bundle.ownerOf(BUNDLE);
        o.controller = bundle.controller();
        o.bootstrap = bundle.bootstrap();
        o.seaport = bundle.seaport();
        o.validator = bundle.getTransferValidator();
        (o.validationSelector, o.validationIsView) = bundle.getTransferValidationFunction();
        (o.royaltyTo, o.royaltyAmount) = bundle.royaltyInfo(BUNDLE, 1 ether);
        bytes4[8] memory ids = [
            type(IERC2981).interfaceId, type(ICreatorToken).interfaceId, bytes4(0x7f5828d0), bytes4(0x80ac58cd),
            bytes4(0x5b5e139f), bytes4(0x01ffc9a7), bytes4(0xffffffff), bytes4(0x12345678)
        ];
        for (uint256 i; i < 8; ++i) o.interfaces[i] = bundle.supportsInterface(ids[i]);
        o.name = bundle.name();
        o.symbol = bundle.symbol();
        o.escrowBalance = bundle.balanceOf(ESCROW);
        o.firstExitNotified3 = bundle.firstExitNotified(BUNDLE);
        for (uint256 i; i < 5; ++i) o.slots[i] = vm.load(PROXY, bytes32(i));
        // The OpenZeppelin ERC-7201 namespaces: Initializable, Ownable, Ownable2Step, ERC721 (name slot).
        o.namespaced = [
            vm.load(PROXY, 0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00),
            vm.load(PROXY, 0x9016d09d72d40fdae2fd8ceac6b6234c7706214fd39c1cd1e609a0528c199300),
            vm.load(PROXY, 0x237e158222e3e6968b72b9db0d8043aacf074ad9f650f0d1606b4d82ee432c00),
            vm.load(PROXY, 0x80bb2b638cc20bc4d0a60d66940f3ab4a00c1d7b313497ca82fb0b4ab0079300)
        ];
    }

    /// The upgrader: `owner()` READ LIVE at the fork block, which must be the deployer.
    function _liveOwner() internal view returns (address owner) {
        owner = bundle.owner();
        assertEq(owner, EXPECTED_OWNER, "the proxy owner at the fork block is the deployer 0xF8e0");
    }

    function _implementation() internal view returns (address) {
        return address(uint160(uint256(vm.load(PROXY, IMPLEMENTATION_SLOT))));
    }

    /// A call's outcome (success + return/revert data), rolled back: state is untouched.
    function _probe(address caller, bytes memory data) internal returns (bool ok, bytes memory ret) {
        uint256 snap = vm.snapshotState();
        vm.prank(caller);
        (ok, ret) = PROXY.call(data);
        vm.revertToState(snap);
    }

    function _probes() internal returns (bytes32[4] memory outcomes) {
        address stranger = address(0x5713);
        bytes[4] memory calls = [
            // a stranger moving the escrow's token: not approved
            abi.encodeCall(bundle.transferFrom, (ESCROW, stranger, BUNDLE)),
            // the escrow (controller) moving its own token: validator + first-exit path
            abi.encodeCall(bundle.transferFrom, (ESCROW, stranger, BUNDLE)),
            // a stranger minting / burning: controller only
            abi.encodeCall(bundle.controllerMint, (999_999)),
            abi.encodeCall(bundle.controllerBurn, (BUNDLE))
        ];
        address[4] memory callers = [stranger, ESCROW, stranger, stranger];
        for (uint256 i; i < 4; ++i) {
            (bool ok, bytes memory ret) = _probe(callers[i], calls[i]);
            outcomes[i] = keccak256(abi.encode(ok, ret));
        }
    }

    /// bundle-non-transferable-sep26: `json` (a decoded tokenURI) with EXACTLY
    /// the two insertions this repo's source now makes - the sentence at the end
    /// of the description (right before `","image":"`) and the Transferable
    /// attribute at the end of `attributes` (right before `],"properties"`).
    /// The sentence is anchored on the description's last words, so the JSON
    /// may carry an image key or not.
    function _withNonTransferable(bytes memory json) internal pure returns (bytes memory) {
        json = _replaceOnce(json, "NewTrade Bundle NFT: a transferable claim on", "NewTrade Bundle NFT: a redeem-only claim on");
        json = _insertBefore(json, '","', " This claim can only be redeemed by its holder; it cannot be transferred or resold.", "not the underlying collection NFT.");
        return _insertBefore(json, '],"properties"', ',{"trait_type":"Transferable","value":"No (redeem only)"}', "");
    }

    /// `json` with its ONLY occurrence of `from` replaced by `to` (reverts unless exactly one).
    function _replaceOnce(bytes memory json, bytes memory from, bytes memory to) internal pure returns (bytes memory) {
        int256 at = CardTestKit.indexOf(json, from, 0);
        require(at >= 0, "FROM");
        uint256 cut = uint256(at);
        require(CardTestKit.indexOf(json, from, cut + 1) == -1, "FROM TWICE");
        return abi.encodePacked(CardTestKit.slice(json, 0, cut), to, CardTestKit.slice(json, cut + from.length, json.length));
    }

    /// `insert` right before the first `marker` at or after the end of `after_` (or from the start when `after_` is empty).
    function _insertBefore(bytes memory json, bytes memory marker, bytes memory insert, bytes memory after_) internal pure returns (bytes memory) {
        uint256 from;
        if (after_.length != 0) {
            int256 a = CardTestKit.indexOf(json, after_, 0);
            require(a >= 0, "ANCHOR");
            from = uint256(a) + after_.length;
        }
        int256 at = CardTestKit.indexOf(json, marker, from);
        require(at >= 0, "MARKER");
        uint256 cut = uint256(at);
        return abi.encodePacked(CardTestKit.slice(json, 0, cut), insert, CardTestKit.slice(json, cut, json.length));
    }
}
