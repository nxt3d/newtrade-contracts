// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {NewTradeEscrowV2} from "../../src/NewTradeEscrowV2.sol";
import {NewTradeBundle} from "../../src/NewTradeBundle.sol";
import {NewTradeV2Vault} from "./NewTradeV2Vault.sol";
import {AcceptanceMode, AssetKind, V2Initialization} from "../../src/NewTradeV2Types.sol";

/// @notice V2 deploy helper. No sibling-repository writes and no automatic
/// broadcast: operational and upgrader addresses are explicit parameters.
contract DeployV2 is Script {
    address constant SEAPORT = 0x0000000000000068F116a894984e2DB1123eB395;
    /// @dev ERC-6551's canonical singleton registry, deployed at the same address on Base.
    address constant ERC6551_REGISTRY = 0x000000006551c19487814612e58FE06813775758;
    /// @dev Tokenbound's Base account proxy passed to the ERC-6551 registry.
    address constant TOKENBOUND_ACCOUNT_PROXY = 0x55266d75D1a14E4572138116aF39863Ed6596E7F;
    /// @dev Tokenbound's Base account logic used to initialize each new proxy.
    address constant TOKENBOUND_ACCOUNT_IMPLEMENTATION = 0x41C8f39463A868d3A88af00cd0fe7102F30E44eC;
    /// @dev OpenSea's Base/mainnet-compatible ERC-721C SignedZone.
    address constant OPENSEA_SIGNED_ZONE = 0x000056F7000000EcE9003ca63978907a00FFD100;
    /// @dev OpenSea's recommended registry for creator-fee enforcement.
    address constant OPENSEA_STRICT_TRANSFER_VALIDATOR = 0xA000027A9B2802E1ddf7000061001e5c005A0000;

    error WrongChain();
    error InvalidConfiguration();
    /// @dev A deployed implementation is over the EIP-170 runtime limit. The
    /// simulator does not enforce the limit, so this makes the dry run fail
    /// closed instead of predicting addresses Base would never create.
    error CodeTooLarge();
    uint256 constant EIP170_LIMIT = 24_576;

    /// `bundle` is the NewTradeBundle collection proxy. The escrow still exposes
    /// it as `receipt()` / `V2Initialization.receipt` - compatibility aliases
    /// kept because the deployed 0x3FF1...175f collection and the app's pinned
    /// escrow ABI call those selectors.
    struct Deployed {
        address proxy;
        address implementation;
        address bundle;
        address vault;
        address bundleImplementation;
    }

    /// @notice Simulates the Base deployment input without broadcasting.
    /// Run with: forge script test/legacy/DeployV2.s.sol:DeployV2 --sig "preflight()" --rpc-url <base-rpc>
    function preflight() external view returns (V2Initialization memory config) {
        config = _environmentConfiguration();
        _validateConfiguration(config);
        _bundleOwnerFromEnvironment();
    }

    /// @notice Discoverable ERC-173 owner of the Bundle collection. Read from
    /// the environment on purpose: never hardcoded, and required (no default) so
    /// a deployment cannot silently fall back to the broadcaster.
    function _bundleOwnerFromEnvironment() private view returns (address owner_) {
        owner_ = vm.envAddress("V2_BUNDLE_OWNER");
        if (owner_ == address(0)) revert InvalidConfiguration();
    }

    /// @notice Uses explicit input for tests and controlled automation. This
    /// function never starts a broadcast by itself.
    function deploy(V2Initialization calldata input, address bundleOwner) external returns (Deployed memory d) {
        V2Initialization memory config = input;
        return _deploy(config, address(this), bundleOwner);
    }

    /// @notice Broadcast entry point. Foundry simulates unless the caller adds
    /// `--broadcast`; it reads only documented V2_* environment configuration.
    function run() external returns (Deployed memory d) {
        V2Initialization memory config = _environmentConfiguration();
        _validateConfiguration(config);
        address bundleOwner = _bundleOwnerFromEnvironment();
        vm.startBroadcast();
        (, address broadcaster,) = vm.readCallers();
        d = _deploy(config, broadcaster, bundleOwner);
        vm.stopBroadcast();
    }

    function _deploy(V2Initialization memory config, address bootstrap, address bundleOwner)
        private
        returns (Deployed memory d)
    {
        _validateConfiguration(config);
        if (bootstrap == address(0) || bundleOwner == address(0)) revert InvalidConfiguration();
        // The Bundle collection is a UUPS proxy like the escrow. Creation and
        // initialization are one transaction, so nobody can front-run the
        // initializer; the implementation's own initializers are disabled.
        NewTradeBundle bundleImplementation = new NewTradeBundle();
        NewTradeBundle bundle_ = NewTradeBundle(
            address(
                new ERC1967Proxy(
                    address(bundleImplementation),
                    abi.encodeCall(
                        NewTradeBundle.initialize, (bootstrap, SEAPORT, config.transferValidator, bundleOwner)
                    )
                )
            )
        );
        NewTradeV2Vault vault_ = new NewTradeV2Vault(
            bootstrap, address(bundle_), config.assetTokens, config.assetKinds, config.assetAcceptanceModes
        );
        // No routed-royalty receiver: routing is retired (option B,
        // escrow-option-b-sep26); the creator royalty is credited in the escrow.
        config.receipt = address(bundle_); // escrow-side compatibility alias for the bundle collection
        config.vault = address(vault_);
        NewTradeEscrowV2 implementation = new NewTradeEscrowV2();
        ERC1967Proxy proxy =
            new ERC1967Proxy(address(implementation), abi.encodeCall(NewTradeEscrowV2.initialize, (config)));
        bundle_.bindController(address(proxy));
        vault_.bindController(address(proxy));
        d = Deployed(
            address(proxy),
            address(implementation),
            address(bundle_),
            address(vault_),
            address(bundleImplementation)
        );
        _verifyDeployment(config, d, bundleOwner);
    }

    function _environmentConfiguration() private view returns (V2Initialization memory c) {
        uint256 feeBps = vm.envUint("V2_PROTOCOL_FEE_BPS");
        if (feeBps > 1_000) revert InvalidConfiguration();
        uint256[] memory rawKinds = vm.envUint("V2_ASSET_KINDS", ",");
        address[] memory assets = vm.envAddress("V2_ASSET_TOKENS", ",");
        if (assets.length != rawKinds.length) revert InvalidConfiguration();
        AssetKind[] memory kinds = new AssetKind[](rawKinds.length);
        for (uint256 i; i < rawKinds.length; ++i) {
            if (rawKinds[i] > uint8(AssetKind.ERC1155)) revert InvalidConfiguration();
            kinds[i] = AssetKind(rawKinds[i]);
        }
        uint256[] memory rawModes = vm.envUint("V2_ASSET_ACCEPTANCE_MODES", ",");
        if (rawModes.length != 3) revert InvalidConfiguration();
        AcceptanceMode[3] memory modes;
        for (uint256 i; i < 3; ++i) {
            if (rawModes[i] > uint8(AcceptanceMode.Wildcard)) revert InvalidConfiguration();
            modes[i] = AcceptanceMode(rawModes[i]);
        }
        c = V2Initialization({
            admin: vm.envAddress("V2_ADMIN"),
            treasury: vm.envAddress("V2_TREASURY"),
            protocolFeeBps: uint96(feeBps),
            paymentTokens: vm.envAddress("V2_PAYMENT_TOKENS", ","),
            assetTokens: assets,
            assetKinds: kinds,
            assetAcceptanceModes: modes,
            accountRegistry: vm.envOr("V2_ACCOUNT_REGISTRY", ERC6551_REGISTRY),
            accountProxy: vm.envOr("V2_ACCOUNT_PROXY", TOKENBOUND_ACCOUNT_PROXY),
            accountImplementation: vm.envOr("V2_ACCOUNT_IMPLEMENTATION", TOKENBOUND_ACCOUNT_IMPLEMENTATION),
            receipt: address(0),
            vault: address(0),
            transferValidator: vm.envOr("V2_TRANSFER_VALIDATOR", OPENSEA_STRICT_TRANSFER_VALIDATOR),
            seaportZone: vm.envOr("V2_SEAPORT_ZONE", OPENSEA_SIGNED_ZONE),
            royaltyRouter: address(0)
        });
    }

    function _validateConfiguration(V2Initialization memory c) private view {
        if (
            block.chainid != 8453 || SEAPORT.code.length == 0 || c.admin == address(0) || c.treasury == address(0)
                || c.protocolFeeBps > 1_000 || c.paymentTokens.length == 0 || c.assetTokens.length != c.assetKinds.length
                || c.accountRegistry.code.length == 0 || c.accountProxy.code.length == 0
                || c.accountImplementation.code.length == 0 || c.transferValidator.code.length == 0
                || c.seaportZone != OPENSEA_SIGNED_ZONE || c.seaportZone.code.length == 0
        ) revert InvalidConfiguration();
        for (uint256 i; i < c.assetTokens.length; ++i) {
            if (c.assetTokens[i] == address(0) || c.assetTokens[i].code.length == 0) revert InvalidConfiguration();
            for (uint256 j; j < i; ++j) {
                if (c.assetTokens[j] == c.assetTokens[i]) revert InvalidConfiguration();
            }
        }
    }

    function _verifyDeployment(V2Initialization memory c, Deployed memory d, address bundleOwner) private view {
        NewTradeEscrowV2 escrow = NewTradeEscrowV2(payable(d.proxy));
        NewTradeBundle bundle_ = NewTradeBundle(d.bundle);
        NewTradeV2Vault vault_ = NewTradeV2Vault(d.vault);
        if (
            d.implementation.code.length > EIP170_LIMIT || d.bundleImplementation.code.length > EIP170_LIMIT
                || d.vault.code.length > EIP170_LIMIT
        ) revert CodeTooLarge();
        if (
            escrow.receipt() != d.bundle || escrow.vault() != d.vault || bundle_.controller() != d.proxy
                || vault_.controller() != d.proxy || vault_.assetPolicyRevision() == 0
                || bundle_.owner() != bundleOwner || bundle_.getTransferValidator() != c.transferValidator
                || bundle_.bootstrap() != vault_.bootstrap()
                || _implementationOf(d.bundle) != d.bundleImplementation
                || _implementationOf(d.proxy) != d.implementation
        ) revert InvalidConfiguration();
        for (uint256 i; i < 3; ++i) {
            AssetKind kind = AssetKind(i);
            if (vault_.assetAcceptanceMode(kind) != c.assetAcceptanceModes[i]) revert InvalidConfiguration();
        }
        for (uint256 i; i < c.assetTokens.length; ++i) {
            if (!vault_.isAssetAllowlisted(c.assetTokens[i], c.assetKinds[i])) revert InvalidConfiguration();
        }
        for (uint256 i; i < c.paymentTokens.length; ++i) {
            if (!escrow.isPaymentTokenAllowed(c.paymentTokens[i])) revert InvalidConfiguration();
        }
    }

    /// ERC-1967 implementation slot, read directly so the check does not
    /// depend on the proxy answering for itself.
    function _implementationOf(address proxy) private view returns (address) {
        bytes32 slot = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
        return address(uint160(uint256(vm.load(proxy, slot))));
    }
}
