# NewTradeEscrowV2 — Base mainnet F-01 partial-release upgrade (2026-11-22 UTC)

**Chain** Base mainnet (8453)

**Signer** `0xF8e03bd4436371E0e2F7C02E529b2172fe72b4EF`

**Status** Live. The production app passed its activation check at 01:01 UTC on November 22 (20:01 EST on November 21).

## What changed

F-01 adds partial release so a failing asset transfer can be retried. The existing escrow proxy switched to a new escrow implementation and vault in one transaction at block 60593018. Listings were frozen and the old vault closed to new deposits before the switch. The executor then opened deposits on the new vault and restored ETH, WETH and USDC listings.

## Addresses

| Contract | Address |
|---|---|
| Escrow proxy (UUPS) | `0xCc29F5c82C8b7c01Cac6036047E7413Df458f86d` |
| Bundle collection | `0x59900b207ea703B0bBcF8fD84C5E11dE46826185` |
| VaultAdmission library (D1) | `0xcbb51e4Cc6166bfa58B3E23AeC9beA0AcCE94a46` |
| VaultCustodyIn library (D2) | `0x150eaeFfa8134D731B364F67f040cf1661210B64` |
| Vault implementation (D3) | `0xb88Ad8ea5FEDCc13923a56aF510443C938F3f34D` |
| Vault proxy (D4) | `0xe3a95e47B8ECC9F8E42a7BDE58dde2FBCbc69C53` |
| Escrow implementation (D5) | `0xC5D933629A13F2BCb382320b73f7349109748071` |
| Previous vault | `0xF39e70134782D7b27d4DBA01a0b98B1D69E49B12` |
| Previous escrow implementation | `0x0c2e731755A069423CDD779CFDEc6146B2D9ba8a` |

## Sequence on Base mainnet

| Nonce | Step | Operation | Block | Transaction |
|---:|---|---|---:|---|
| 276 | D1 | deploy library VaultAdmission | 60592064 | `0xa4989c16c04e088e32a2d2f94acb6651319f47458705f44c354cef5d9d6d7ef2` |
| 277 | D2 | deploy library VaultCustodyIn | 60592104 | `0xf077718744433ee74ec5a0cca9df307864f0a14c09769d8c98a660ef0b56eae1` |
| 278 | D3 | deploy NewTradeV2VaultV2 implementation (linked to D1 and D2) | 60592146 | `0xc93c075a1fb4cff46a74b85ccc056dfa7767598688604b805b3adc5beed36bdd` |
| 279 | D4 | deploy the vault ERC1967Proxy(D3, initialize(escrow proxy, Bundle, [Disabled,Disabled,Disabled])) | 60592189 | `0xf19a2fe8105186a2045fd45afdd8eb2c33bb760b44b77605596ed1d8567f9173` |
| 280 | D5 | deploy NewTradeEscrowV2 implementation | 60592243 | `0x1cb7048df02ee599a330134bec3e615ddcdcc5849c17762a177ab4df1d2a5fcd` |
| 281 | F1 | freeze listings: setPaymentTokenAllowed(ETH, false) | 60592335 | `0x142dd65d1ba9ab45eefb0cb8722cd5e419e16b9062d17d548613ad5c0f6ddafe` |
| 282 | F2 | freeze listings: setPaymentTokenAllowed(WETH, false) | 60592390 | `0x0f753d54bcec7f5d6fb42496f9e08ce46ef50f9945581d5ede932b0478866d2b` |
| 283 | F3 | freeze listings: setPaymentTokenAllowed(USDC, false) | 60592441 | `0xd9c85f38b8b52e1d60bdfbbf572e1c529469f631209770ce1cd20604146e2afd` |
| 284 | C1 | close deposits on the OLD vault: setAssetAcceptanceMode(ERC20, Disabled) | 60592501 | `0xd2b404dc7d66ba26c7ed830cb8d3d887459e638a0f2c1e605b9df30aa9952832` |
| 285 | C2 | close deposits on the OLD vault: setAssetAcceptanceMode(ERC721, Disabled) | 60592553 | `0x0c644764aa73077ce0f0a4de4a159e7bbbb2bb1acf4d5114876aeb8c501f71a5` |
| 286 | C3 | close deposits on the OLD vault: setAssetAcceptanceMode(ERC1155, Disabled) | 60592604 | `0x0c4c9cba27c163f0534f50bcabea318bc084d2e65d8096aaef8a0095c5b7a423` |
| 287 | S | THE SWITCH: upgradeToAndCall(D5, initializeVault(D4)) | 60593018 | `0xa885a146373bb58945973d05ea0b5ae70935e83c4677b52b4999e2e09b4dba09` |
| 288 | A1 | activate: setAssetAcceptanceMode(ERC20, Wildcard) | 60593220 | `0xb04d22ad0e3209e4b2294c0b260ad5fc66a94d258f8ed20521fd989bafd6fd52` |
| 289 | A2 | activate: setAssetAcceptanceMode(ERC721, Wildcard) | 60593271 | `0xdf328d82fcae8f5d9b3f1fd89ae0da2e77a58b2f93ce0b5b0d796bb17e15f444` |
| 290 | A3 | activate: setAssetAcceptanceMode(ERC1155, Wildcard) | 60593322 | `0x649534c8a5a075717187c18d9ddfae011860d2751858afe0ae7bace00a0c8f43` |
| 291 | A4 | activate: setMigrationEnabled(true) | 60593373 | `0x3e366e0afda3bd815f1fa6dcd84896913979c9c0750c29caa72737a808ea3600` |
| 292 | U1 | unfreeze listings: setPaymentTokenAllowed(ETH, true) | 60593439 | `0xf95cc7f8b711e2dfecb24c62c662799bcb6fd4f8e464c6fc508cdf2fc8453e6e` |
| 293 | U2 | unfreeze listings: setPaymentTokenAllowed(WETH, true) | 60593491 | `0xc9d6a832cc3e580d2f382b58003428d80cfa085f914a566af4b0e85ab13bdd4f` |
| 294 | U3 | unfreeze listings: setPaymentTokenAllowed(USDC, true) | 60593542 | `0x9f6b6625de49cb542c26c8b9474699ee7b00a6907d65a9119750741d1fd8ef78` |

## Source and production app

- Contracts package commit `5b6fb0f63e32e047c22bea3fa540bcac89aa33a5`. Last production contract source change `cfabc7681aa9f226a4a3120020c7a0f3c475f202`. Since merge `242c0aa`, `main` holds this source. Built from `main` with the release link flags, both libraries and the vault implementation match their live runtimes exactly; the escrow implementation matches in every executable byte, and only its metadata hash differs, because it imports the since-edited `NewTradeBundle.sol` (table and flags in the [Bundle zero-royalty report](base-mainnet-2026-11-24-bundle-zero-royalty-upgrade.md#source-on-main-item-79-recorded-november-24)). Executor package SHA-256 `f9bf179accb3bb4eba08534aefb2703527dd6fc7c085b2e8eea9fe7aa3716ede`.
- Inert app commit `a0b317c8a9f18038f33512544963982d29fa0d06` reached production before D1. The served build refused vault reads while the activation pin was unset.
- Activation commit `8706fe7b6e24bbd0aac1934d14c094b850a38cd1` pinned D4 and the mined block of S. The executor checked the production alias, the served resolver and the served Base RPC route.

## Verification and outstanding custody

All 19 receipts succeeded. The executor recorded the following Base reads:

| Block | Observation |
|---:|---|
| 60593071 | The escrow implementation slot held D5, vault storage slot 6 held D4, and initializer version was 3. Compared with the pre-switch ready snapshot, ledger totals, balance, counter, bundle/order/payout records and sequential slots 0–63 outside slot 6 matched. |
| 60593421 | D4 accepted ERC-20, ERC-721 and ERC-1155 in Wildcard mode and enabled migration for account deposits. |
| 60593590 | ETH, WETH and USDC were allowed. Confirmed and pending signer nonces were both 295. |

Team-owned bundle #3 has an expired order. Its controlling NFT and manifest assets remain in the previous vault. Recovery requires a separate upgrade. Restoring the previous escrow implementation alone would leave the vault pointer at D4 and initializer version 3 consumed.

## Machine-readable

```json
{
  "chainId": 8453,
  "network": "base-mainnet",
  "completedAt": "2026-11-22T01:01:00Z",
  "escrowProxy": "0xCc29F5c82C8b7c01Cac6036047E7413Df458f86d",
  "bundleCollection": "0x59900b207ea703B0bBcF8fD84C5E11dE46826185",
  "vaultAdmission": "0xcbb51e4Cc6166bfa58B3E23AeC9beA0AcCE94a46",
  "vaultCustodyIn": "0x150eaeFfa8134D731B364F67f040cf1661210B64",
  "vaultImplementation": "0xb88Ad8ea5FEDCc13923a56aF510443C938F3f34D",
  "vaultProxy": "0xe3a95e47B8ECC9F8E42a7BDE58dde2FBCbc69C53",
  "escrowImplementation": "0xC5D933629A13F2BCb382320b73f7349109748071",
  "previousVault": "0xF39e70134782D7b27d4DBA01a0b98B1D69E49B12",
  "previousImplementation": "0x0c2e731755A069423CDD779CFDEc6146B2D9ba8a",
  "contractsCommit": "5b6fb0f63e32e047c22bea3fa540bcac89aa33a5",
  "contractsSourceLastChangedAt": "cfabc7681aa9f226a4a3120020c7a0f3c475f202",
  "executorPackageSha256": "f9bf179accb3bb4eba08534aefb2703527dd6fc7c085b2e8eea9fe7aa3716ede",
  "inertAppCommit": "a0b317c8a9f18038f33512544963982d29fa0d06",
  "activeAppCommit": "8706fe7b6e24bbd0aac1934d14c094b850a38cd1",
  "switchBlock": 60593018,
  "switchTransaction": "0xa885a146373bb58945973d05ea0b5ae70935e83c4677b52b4999e2e09b4dba09"
}
```
