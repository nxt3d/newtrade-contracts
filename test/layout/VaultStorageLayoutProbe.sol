// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {NewTradeV2VaultStorage} from "../../src/NewTradeV2VaultStorage.sol";

/// @notice Exists only so `forge inspect ... storageLayout` prints the vault's
/// namespaced struct. A library has no state variables, so the namespace does not
/// appear in any contract's layout; declaring the struct here exposes every nested
/// struct, mapping and array to `check_storage_layout.py`. Never deployed.
contract VaultStorageLayoutProbe {
    NewTradeV2VaultStorage.VaultStorage internal probe;
}
