# NewTradeBundle — Base Mainnet Upgrade: modular image (2026-09-25)

**Chain:** Base mainnet (8453)
**Signer:** `0xF8e03bd4436371E0e2F7C02E529b2172fe72b4EF` (deployer, Bundle owner)
**Status:** ✅ deployed + upgraded + renderer and external URL set + verified on-chain

## What changed

The Bundle NFT's `image` becomes modular, so a new picture never needs an upgrade.
The metadata JSON stays built on chain in `NewTradeBundle`; only the image URI comes
from a source the owner selects:

- `setImageRenderer(address)`: a separate stateless renderer contract whose
  `imageURI(bundleId, nft, nftId)` returns the image (first renderer:
  `0x4519D5429391aA6bBcBB33ad248470d5e45856c5`, the card with the stacked-layers bundle
  graphic; its source is not part of this repository).
- `setImageBaseURI(string)`: when set, `image = base + bundleId` and wins over the renderer.
- `setExternalBaseURI(string)`: when set, adds `"external_url": base + bundleId`
  right after `image`; the key is absent while unset.

Any URI scheme is accepted (`data:`, `https:`, `ipfs:`, `ar:`, ...). Every value is
JSON-safety-checked (printable ASCII, no `"` or `\`, length caps) when set and again
at render; a renderer that reverts, has no code, returns malformed or oversized
output, or burns gas (capped at 2,000,000) falls back to the built-in card. Every
setter emits its own event plus ERC-4906 `BatchMetadataUpdate(0, max)`, and
`supportsInterface(0x49064906)` is true. New state lives in an ERC-7201 namespace
(`newtrade.storage.NewTradeBundle.image`, slot
`0x92e9f748b197c8df37e6f357621b4b56a147841660aafbfb660fb6e6ea2d0d00`); sequential
slots 0-4 are unchanged. The upgrade alone changes no output.

## Addresses

| Contract | Address |
|----------|---------|
| **Bundle (ERC1967 / UUPS proxy)** | `0x59900b207ea703b0bbcf8fd84c5e11de46826185` |
| New implementation (NewTradeBundle) | `0x29DaD81D121CaB79343A191EeB071317858319d6` |
| Image renderer | `0x4519D5429391aA6bBcBB33ad248470d5e45856c5` |
| Previous implementation (rollback target) | `0x9Cc108E3FEa007715896d8c97fBC7c35EC430207` |
| Controller (EscrowV2) | `0xCc29F5c82C8b7c01Cac6036047E7413Df458f86d` |

## Transactions

| Step | Hash | Block | Gas |
|------|------|-------|-----|
| Deploy implementation | `0xf81f4c27c38e7075b5e272bad82dc7336bb92d09f490e4e7a62ffc28e60a9245` | 51798625 | 3,856,267 |
| Deploy renderer | `0x3d9b17e5161186dd026919e9ded9e0af7b430ec1f2da0402afe9d64b04ab2b81` | 51798628 | 809,120 |
| `upgradeToAndCall(impl, 0x)` | `0xd9ee6a3bf99fc3bee9f874094c8a66aec1ce4d037cd6257575c10aa970d17067` | 51798691 | 37,706 |
| `setImageRenderer(renderer)` | `0x4140547f392fac2aaab9b9191f80d9c03c886831989ba07a188c5e4b7a91b937` | 51798695 | 54,198 |
| `setExternalBaseURI("https://newtrade-app.vercel.app/claim/8453/")` | `0x1cb5b59e76c30c1ca3d4567952c0f13b26674731f0fe1a4189dae56dfbcf4edc` | 51798718 | 116,613 |
| `setImageRenderer(renderer)` again (no-op re-set, same address) | `0x93ae72a5b453d54dc59e018dd392378c09d53d2cbb28ec61f03c20c3d10df05c` | 51798731 | 34,298 |

All receipts `status 1`. The upgrade emitted `Upgraded(0x29Da…19d6)`; `setImageRenderer` emitted
`ImageRendererSet(0x0 → 0x4519…56c5)` and `BatchMetadataUpdate(0, 2^256-1)`; `setExternalBaseURI`
emitted `ExternalBaseURISet` and `BatchMetadataUpdate(0, 2^256-1)`. The repeated `setImageRenderer` at block 51798731 set the same
renderer (`ImageRendererSet(0x4519…56c5 → 0x4519…56c5)`): no state change, one more ERC-4906 refresh.

## Source and build

- **Source commit:** `8fd3437` (pre-release development history; not included in this repository)
- **Build:** solc 0.8.28, `via_ir = true`, optimizer runs 1, evm `cancun`
- **Implementation:** 17,465 runtime bytes; on-chain runtime == build artifact after masking the
  2 UUPS `__self` immutables (holding `0x29Da…19d6`); masked sha256 `0ab1372d…9b97d1`
- **Renderer:** 3,495 runtime bytes; on-chain runtime == build artifact exactly (no immutables)

## Verification

Before signing:
- ERC-7201 slot constant recomputed independently: matches.
- `forge test` at `8fd3437`: 331 passed, 0 failed (12 skipped: fork-only).
- Fork suites at latest Base: `BundleImageModularUpgradeForkTest` 8/8, `BundleCardUpgradeForkTest` 5/5.
- Live: `upgradeToAndCall(0x29Da…19d6, 0x)` simulated from the deployer: succeeds.
- Local anvil fork of Base with the DEPLOYED implementation and renderer, as the deployer:
  upgrade → `tokenURI(3)` byte-identical; `setImageRenderer` → only `image` changes;
  `setExternalBaseURI` → `external_url` = `https://newtrade-app.vercel.app/claim/8453/3`
  after `image`; `supportsInterface(0x49064906)` = true.

After the upgrade (live, Base):
- ERC-1967 implementation slot = `0x29DaD81D121CaB79343A191EeB071317858319d6`
- Immediately after the upgrade (before any setter): `imageRenderer()` = 0, `tokenURI(3)` unchanged
- `imageRenderer()` = `0x4519D5429391aA6bBcBB33ad248470d5e45856c5`; `imageBaseURI()` = `""`;
  `externalBaseURI()` = `https://newtrade-app.vercel.app/claim/8453/`
- `tokenURI(3)` keys: `name, description, image, external_url, attributes, properties`; the image is the
  stacked-layers card; `external_url` = `https://newtrade-app.vercel.app/claim/8453/3`
- Unchanged: `owner()` = `0xF8e0…b4EF`; `controller()` = `0xCc29…f86d`; `ownerOf(3)` = escrow;
  `royaltyInfo(3, 1e18)` = (`0xF8e0…b4EF`, 5e16); `getTransferValidator()` = `0xA000027A9B2802E1ddf7000061001e5c005A0000`
- `supportsInterface(0x49064906)` (ERC-4906) = true

## Rollback

Each step is reversible by the owner, restoring today's JSON (fork-tested):

```bash
cast send 0x59900b207ea703b0bbcf8fd84c5e11de46826185 "setExternalBaseURI(string)" "" --rpc-url https://mainnet.base.org --account <owner-keystore>
cast send 0x59900b207ea703b0bbcf8fd84c5e11de46826185 "setImageRenderer(address)" 0x0000000000000000000000000000000000000000 --rpc-url https://mainnet.base.org --account <owner-keystore>
cast send 0x59900b207ea703b0bbcf8fd84c5e11de46826185 "upgradeToAndCall(address,bytes)" 0x9Cc108E3FEa007715896d8c97fBC7c35EC430207 0x --rpc-url https://mainnet.base.org --account <owner-keystore>
```

## Future image changes (no upgrade)

- New picture: deploy another `INewTradeBundleImage` renderer, then `setImageRenderer(newRenderer)`.
- Hosted image: `setImageBaseURI("https://…/")` (or `ipfs://…/`); `""` returns to the renderer.

## Machine-readable

```json
{
  "chainId": 8453,
  "network": "base-mainnet",
  "upgradedAt": "2026-09-25",
  "contract": "NewTradeBundle",
  "proxy": "0x59900b207ea703b0bbcf8fd84c5e11de46826185",
  "implementation": "0x29DaD81D121CaB79343A191EeB071317858319d6",
  "previousImplementation": "0x9Cc108E3FEa007715896d8c97fBC7c35EC430207",
  "imageRenderer": "0x4519D5429391aA6bBcBB33ad248470d5e45856c5",
  "imageBaseURI": "",
  "externalBaseURI": "https://newtrade-app.vercel.app/claim/8453/",
  "owner": "0xF8e03bd4436371E0e2F7C02E529b2172fe72b4EF",
  "sourceCommit": "8fd3437",
  "imageStorageSlot": "0x92e9f748b197c8df37e6f357621b4b56a147841660aafbfb660fb6e6ea2d0d00",
  "transactions": {
    "deployImplementation": "0xf81f4c27c38e7075b5e272bad82dc7336bb92d09f490e4e7a62ffc28e60a9245",
    "deployRenderer": "0x3d9b17e5161186dd026919e9ded9e0af7b430ec1f2da0402afe9d64b04ab2b81",
    "upgradeToAndCall": "0xd9ee6a3bf99fc3bee9f874094c8a66aec1ce4d037cd6257575c10aa970d17067",
    "setImageRenderer": "0x4140547f392fac2aaab9b9191f80d9c03c886831989ba07a188c5e4b7a91b937",
    "setExternalBaseURI": "0x1cb5b59e76c30c1ca3d4567952c0f13b26674731f0fe1a4189dae56dfbcf4edc"
  },
  "blocks": {
    "deployImplementation": 51798625,
    "deployRenderer": 51798628,
    "upgradeToAndCall": 51798691,
    "setImageRenderer": 51798695,
    "setExternalBaseURI": 51798718
  }
}
```
