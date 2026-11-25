# NewTradeBundle — Base Mainnet Upgrade: on-chain image (2026-09-25)

**Chain:** Base mainnet (8453)
**Signer:** `0xF8e03bd4436371E0e2F7C02E529b2172fe72b4EF` (deployer, now Bundle owner)
**Status:** ✅ implementation deployed + proxy upgraded + verified on-chain

## What changed

`NewTradeBundle.tokenURI` now includes `"image"`, an on-chain SVG card
(`src/NewTradeBundleCard.sol`) with static facts only: `NewTrade Bundle #<id>`,
`Original NFT #<tokenId>` and the short checksummed original-collection address.
It is ONE new key after `description`; every other byte of the JSON is unchanged.
No storage added, initializer and `_authorizeUpgrade` untouched. Before this,
bundle NFTs had no `image` field and OpenSea showed none.

## Addresses

| Contract | Address |
|----------|---------|
| **Bundle (ERC1967 / UUPS proxy)** | `0x59900b207ea703b0bbcf8fd84c5e11de46826185` |
| New implementation (NewTradeBundle) | `0x9Cc108E3FEa007715896d8c97fBC7c35EC430207` |
| Previous implementation (rollback target) | `0x19BE700bf6744253A36FB14E7d8d6a55b8B0b40F` |
| Controller (EscrowV2) | `0xCc29F5c82C8b7c01Cac6036047E7413Df458f86d` |

Basescan: https://basescan.org/address/0x59900b207ea703b0bbcf8fd84c5e11de46826185

## Transactions

| Step | Signer | Hash | Block | Gas |
|------|--------|------|-------|-----|
| Ownership: `transferOwnership(deployer)` | `0xc3F9…032e` | `0xe29124c85836fdc2e10709873dfd9da51f018b00eba64f0b60f7b808359e0887` | 51776510 | — |
| Ownership: `acceptOwnership()` | `0xF8e0…b4EF` | `0xd7fc5c999886cfc7575d85b9f5a044243a865f51c70a6fdecefba67063b40536` | 51776515 | 33,469 |
| Deploy implementation | `0xF8e0…b4EF` | `0xc362866465ec57185c3122cf40b530ed5703ecf8de28732f354411edef25d231` | 51779734 | 3,132,557 |
| `upgradeToAndCall(newImpl, 0x)` | `0xF8e0…b4EF` | `0x11b21767bb711f9f0a11f627a73289ef475c1111fdf898dbff186cb9679ed4ae` | 51785015 | 37,684 |

All receipts `status 1`. The upgrade emitted `Upgraded(0x9Cc1…0207)`; the accept
emitted `OwnershipTransferred(0xc3F9…032e → 0xF8e0…b4EF)`.

**Ownership note:** the Bundle proxy was deployed with owner `V2_BUNDLE_OWNER =
0xc3F96C409d26272fDB592c0d04e1D771A7df032e` (an EOA). It was moved to the deployer
(Ownable2Step) so the deployer key can sign upgrades. The deployer now holds both
the escrow admin role and the Bundle owner (upgrade + OpenSea collection owner).

## Source and build

- **Source commit:** `b2d15e2` (pre-release development history; not included in this repository)
- **Build:** solc 0.8.28, `via_ir = true`, optimizer runs 1, evm `cancun` (foundry.toml)
- **Runtime size:** 14,119 bytes
- **Deployed runtime codehash:** `0x28a08d6e66c7b300f66a835455e7f1a6a6ca505ec89ed8395b9726901f7e25d2`
- **Bytecode check:** on-chain runtime == local `out/NewTradeBundle.sol/NewTradeBundle.json`
  `deployedBytecode`, byte-for-byte, after masking the 2 immutable references
  (UUPS `__self`, which on chain holds `0x9Cc1…0207`, the implementation itself).

## Verification

Before signing:
- `forge test` on `b2d15e2`: 281 passed, 0 failed (12 skipped: fork-only).
- Fork suite `BundleCardUpgradeForkTest` at block 51774972 (owner still `0xc3F9…`): 4/4 pass —
  image is the only added key, owner/wiring/royalty/interfaces/validator/storage/transfer
  outcomes identical, only the owner can upgrade, rollback restores the old JSON exactly.
- Same suite at latest with the owner set to the deployer: upgrade + rollback + fixture pass;
  `test_OnlyTheOwnerCanUpgrade` fails only because it asserts the deployer is NOT owner,
  which the ownership move made untrue (test to be updated; not a contract issue).
- Local anvil fork of Base: impersonated the deployer, upgraded the live proxy to the
  DEPLOYED implementation `0x9Cc1…0207`, `tokenURI(3)` == old JSON + `image` only.

After the upgrade (live, Base):
- ERC-1967 implementation slot = `0x9Cc108E3FEa007715896d8c97fBC7c35EC430207`
- `owner()` = `0xF8e0…b4EF`; `controller()` = `0xCc29…f86d`; `name()` / `symbol()` = `NewTrade Bundle V2` / `NTB2`
- `ownerOf(3)` = escrow; `royaltyInfo(3, 1e18)` = (`0xF8e0…b4EF`, 5e16); `getTransferValidator()` = `0xA000027A9B2802E1ddf7000061001e5c005A0000`
- `tokenURI(3)` keys: `name, description, image, attributes, properties`; image is `data:image/svg+xml;base64,…`
- Bundle #2 was burned on redemption, so `tokenURI(2)` reverts as before (no image to show).

## Rollback

From the Bundle owner:

```bash
cast send 0x59900b207ea703b0bbcf8fd84c5e11de46826185 "upgradeToAndCall(address,bytes)" 0x19BE700bf6744253A36FB14E7d8d6a55b8B0b40F 0x --rpc-url https://mainnet.base.org --account <owner-keystore>
```

Restores the previous metadata exactly (fork-tested).

## Follow-ups

- OpenSea: "Refresh metadata" on live bundles (e.g. #3) to pick up the image.
- `test/fork/BundleCardUpgradeFork.t.sol` pins `OWNER = 0xc3F9…`; update for the deployer.
- Later (optional): an app-rendered image showing the original NFT's picture.

## Machine-readable

```json
{
  "chainId": 8453,
  "network": "base-mainnet",
  "upgradedAt": "2026-09-25",
  "contract": "NewTradeBundle",
  "proxy": "0x59900b207ea703b0bbcf8fd84c5e11de46826185",
  "implementation": "0x9Cc108E3FEa007715896d8c97fBC7c35EC430207",
  "previousImplementation": "0x19BE700bf6744253A36FB14E7d8d6a55b8B0b40F",
  "owner": "0xF8e03bd4436371E0e2F7C02E529b2172fe72b4EF",
  "previousOwner": "0xc3F96C409d26272fDB592c0d04e1D771A7df032e",
  "controller": "0xCc29F5c82C8b7c01Cac6036047E7413Df458f86d",
  "sourceCommit": "b2d15e2",
  "runtimeCodehash": "0x28a08d6e66c7b300f66a835455e7f1a6a6ca505ec89ed8395b9726901f7e25d2",
  "transactions": {
    "transferOwnership": "0xe29124c85836fdc2e10709873dfd9da51f018b00eba64f0b60f7b808359e0887",
    "acceptOwnership": "0xd7fc5c999886cfc7575d85b9f5a044243a865f51c70a6fdecefba67063b40536",
    "deployImplementation": "0xc362866465ec57185c3122cf40b530ed5703ecf8de28732f354411edef25d231",
    "upgradeToAndCall": "0x11b21767bb711f9f0a11f627a73289ef475c1111fdf898dbff186cb9679ed4ae"
  },
  "blocks": {
    "transferOwnership": 51776510,
    "acceptOwnership": 51776515,
    "deployImplementation": 51779734,
    "upgradeToAndCall": 51785015
  }
}
```
