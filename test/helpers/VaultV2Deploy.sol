// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {NewTradeV2VaultV2} from "../../src/NewTradeV2VaultV2.sol";
import {NewTradeEscrowV2} from "../../src/NewTradeEscrowV2.sol";
import {AcceptanceMode, AssetKind} from "../../src/NewTradeV2Types.sol";
import {NewTradeV2VaultStorage} from "../../src/NewTradeV2VaultStorage.sol";
import {IERC6551Account, IERC6551OwnerAccount} from "../../src/interfaces/IERC6551.sol";
import {Vm} from "forge-std/Vm.sol";

/// @notice Test helper for the upgradeable per-entry vault (partial-release-oct20).
/// The vault implementation calls VaultAdmission and VaultCustodyIn as EXTERNAL
/// library functions; forge deploys and links both libraries when it deploys the
/// implementation here, so every vault built by this helper runs the same linked
/// code as production (BUILD-PLAN section 1).
library VaultV2Deploy {
    /// A fresh vault proxy bound to `controller` and `receipt` (both must have code),
    /// initialized in the proxy's constructor: no window without a controller.
    function deployProxy(address controller, address receipt, AcceptanceMode[3] memory modes)
        internal
        returns (NewTradeV2VaultV2 vault)
    {
        NewTradeV2VaultV2 impl = new NewTradeV2VaultV2();
        vault = NewTradeV2VaultV2(
            address(
                new ERC1967Proxy(
                    address(impl), abi.encodeCall(NewTradeV2VaultV2.initialize, (controller, receipt, modes))
                )
            )
        );
    }

    /// The production switch (D1): a vault proxy for an EXISTING escrow proxy, then
    /// `initializeVault` on the escrow. The caller must hold the escrow's
    /// UPGRADER_ROLE. Acceptance modes start Disabled as in the deployment sequence;
    /// the caller sets them through the escrow afterwards.
    function switchEscrow(NewTradeEscrowV2 escrow, address receipt) internal returns (NewTradeV2VaultV2 vault) {
        AcceptanceMode[3] memory disabled;
        vault = deployProxy(address(escrow), receipt, disabled);
        escrow.initializeVault(address(vault));
    }

    /// The switch, then the previous vault's admission policy replayed through the
    /// escrow's admin setters (the test contract must hold DEFAULT_ADMIN_ROLE).
    /// Used by the fixtures that were written against the constructor-built vault.
    function switchEscrowMirroring(
        NewTradeEscrowV2 escrow,
        address receipt,
        address[] memory tokens,
        AssetKind[] memory kinds,
        AcceptanceMode[3] memory modes
    ) internal returns (NewTradeV2VaultV2 vault) {
        vault = switchEscrow(escrow, receipt);
        for (uint256 i; i < 3; ++i) {
            if (modes[i] != AcceptanceMode.Disabled) escrow.setAssetAcceptanceMode(AssetKind(i), modes[i]);
        }
        for (uint256 i; i < tokens.length; ++i) {
            escrow.setAssetKind(tokens[i], kinds[i], true);
        }
    }
}

/// @notice Reads the tests used from the constructor-built vault, answered from the
/// upgradeable vault. The new vault dropped these getters for size (BUILD-PLAN 1);
/// `liability` carries the same values, and `custodyAssetKind` is read from the
/// pinned ERC-7201 slot (the layout is gated in VaultV2StorageLayout.t.sol).
/// `using VaultV2Views for NewTradeV2VaultV2` keeps the old call sites unchanged.
library VaultV2Views {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    /// Field index of `custodyKindPlusOne` in NewTradeV2VaultStorage.VaultStorage.
    uint256 internal constant SLOT_CUSTODY_KIND = 12;

    function erc20Liability(NewTradeV2VaultV2 v, address token) internal view returns (uint256 a) {
        (a,,,) = v.liability(token, 0);
    }

    function erc1155Liability(NewTradeV2VaultV2 v, address token, uint256 id) internal view returns (uint256 a) {
        (, a,,) = v.liability(token, id);
    }

    function erc721Reserved(NewTradeV2VaultV2 v, address token, uint256 id) internal view returns (bool r) {
        (,, r,) = v.liability(token, id);
    }

    function assetLiabilityUnits(NewTradeV2VaultV2 v, address token) internal view returns (uint256 u) {
        (,,, u) = v.liability(token, 0);
    }

    function custodyAssetKind(NewTradeV2VaultV2 v, address token)
        internal
        view
        returns (AssetKind kind, bool configured)
    {
        bytes32 base = bytes32(uint256(NewTradeV2VaultStorage.VAULT_STORAGE_LOCATION) + SLOT_CUSTODY_KIND);
        uint8 value = uint8(uint256(vm.load(address(v), keccak256(abi.encode(token, base)))));
        if (value == 0) return (AssetKind.ERC20, false);
        return (AssetKind(value - 1), true);
    }

    /// The old vault forwarded this read to the account; the account is asked directly.
    function accountOwner(NewTradeV2VaultV2, address account) internal view returns (address) {
        return IERC6551OwnerAccount(account).owner();
    }

    function accountValidSigner(NewTradeV2VaultV2, address account, address signer) internal view returns (bool) {
        return IERC6551Account(account).isValidSigner(signer, "") == bytes4(0x523e3260);
    }
}
