// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

/// @notice Deploy-size gate. `forge test` does NOT enforce EIP-170, so a
/// suite can pass, and a fork upgrade can "succeed", with an implementation
/// Base would reject at CREATE. This test measures the runtime bytecode the
/// deployment will actually publish and fails while it is at or near the
/// limit, so the size regression is caught by the same command as every
/// other regression.
contract DeploySizeTest is Test {
    /// EIP-170 runtime code limit, enforced by Base.
    uint256 internal constant EIP170_LIMIT = 24_576;
    /// Headroom every deployable contract must keep so a small follow-up
    /// upgrade cannot silently become undeployable.
    uint256 internal constant REQUIRED_MARGIN = 500;

    /// The escrow's margin is 40 B, NOT 500: the fee-from-proceeds upgrade
    /// (escrow-fee-from-proceeds-sep25) was accepted at 43 B of headroom (size
    /// decision 2026-09-25). The follow-up that restores headroom is option B
    /// (order building in an external library) BEFORE the next escrow change.
    uint256 internal constant ESCROW_REQUIRED_MARGIN = 40;

    function test_escrowImplementationFitsWithMargin() public {
        uint256 size = vm.getDeployedCode("NewTradeEscrowV2.sol:NewTradeEscrowV2").length;
        assertLe(size, EIP170_LIMIT - ESCROW_REQUIRED_MARGIN, "NewTradeEscrowV2 runtime bytecode too close to EIP-170");
    }

    function test_escrowSeederFitsWithMargin() public {
        _assertFits("NewTradeEscrowV2Seeder.sol:NewTradeEscrowV2Seeder");
    }

    function test_bundleImplementationFitsWithMargin() public {
        _assertFits("NewTradeBundle.sol:NewTradeBundle");
    }

    function test_vaultFitsWithMargin() public {
        _assertFits("NewTradeV2Vault.sol:NewTradeV2Vault");
    }

    // partial-release-oct20: the upgradeable vault and its two linked libraries.
    function test_upgradeableVaultFitsWithMargin() public {
        uint256 size = vm.getDeployedCode("NewTradeV2VaultV2.sol:NewTradeV2VaultV2").length;
        assertLe(size, EIP170_LIMIT - REQUIRED_MARGIN, "NewTradeV2VaultV2 runtime bytecode too close to EIP-170");
    }

    function test_vaultAdmissionLibraryFitsWithMargin() public {
        _assertFits("VaultAdmission.sol:VaultAdmission");
    }

    function test_vaultCustodyInLibraryFitsWithMargin() public {
        _assertFits("VaultCustodyIn.sol:VaultCustodyIn");
    }

    function test_royaltyReceiverFitsWithMargin() public {
        _assertFits("NewTradeRoyaltyReceiver.sol:NewTradeRoyaltyReceiver");
    }

    /// `vm.getDeployedCode` returns the compiled runtime bytecode with
    /// immutable slots reserved, so its length is exactly what EIP-170 sees.
    function _assertFits(string memory artifact) private view {
        uint256 size = vm.getDeployedCode(artifact).length;
        assertLe(
            size, EIP170_LIMIT - REQUIRED_MARGIN, string.concat(artifact, " runtime bytecode too close to EIP-170")
        );
    }
}
