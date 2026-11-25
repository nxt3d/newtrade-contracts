# NewTradeEscrowV2 — Base Mainnet Upgrade: option B (creator royalty credited in the ledger) (2026-09-27)

**Chain:** Base mainnet (8453)
**Signers:** `0xF8e03bd4436371E0e2F7C02E529b2172fe72b4EF` (deployer; escrow DEFAULT_ADMIN_ROLE + UPGRADER_ROLE), `0x9a704664009d615A90ddDf9345B6b8B2A214cFb2` (new Bundle collection owner)
**Status:** ✅ OpenSea creator earnings 0%, listings frozen, implementation deployed, proxy upgraded, listings reopened, verified on-chain

## Why

OpenSea keeps ONE creator-fee schedule per collection, but each bundle's royalty comes from its own
controlling NFT (any rate, any recipient). With the Bundle collection requiring 5% to `0xF8e0`, only
NFTs paying exactly 5% to `0xF8e0` could list on OpenSea. Option B (owner decision, 2026-09-26): the Bundle
collection's OpenSea creator earnings go to 0%, every order is just `[escrow item, OpenSea 1%]`, and at
the sale the escrow ledger credits the controlling NFT's ERC-2981 recipient its exact royalty. Claims
were made redeem-only earlier the same day (`base-mainnet-2026-09-27-bundle-non-transferable-upgrade.md`),
so the primary sale is the only sale.

## What changed in the escrow

- **Orders:** no royalty item. `_validateExactConsideration` requires `item0 >= royalty + fee` and, when
  royalty != 0, that no payout names the royalty recipient (no double payment). Other rules unchanged.
- **Snapshot at `list()`:** `_royaltySnapshots[bundleId]` stores the ERC-2981 recipient and amount
  (creator, gross = net = royalty; router/treasury/service fields zero); `CreatorRoyaltySnapshot` emitted
  when royalty != 0. A later royalty or fee change never alters a listing.
- **First exit:** seller credited `item0 − royalty − fee`; the royalty recipient credited its exact
  royalty (`CreatorRoyaltyCredited`); both via `_creditOwed`, so `totalOwed` covers creator credits.
  The protocol fee stays as surplus.
- **Withdrawals:** `withdraw(token)` for any credited account; new permissionless `withdrawFor(account,
  token)` pays only the credited account itself (for contract creators that cannot call `withdraw`).
- **Routing retired:** removed `setRoyaltyRouter`, `setRoyaltyServiceFeeBps`, `quoteRoyaltyService`,
  `royaltyRouter`, `royaltyServiceFeeBps`. Their storage slots are retained (dead). The receiver
  `0x9182E5b06Bf25A49c0e6Ed04d2A44146d25d4394` stays deployed, bound and dormant (never credited).
  `receiptRoyaltyInfo` no longer substitutes the router.
- Storage: all 27 sequential entries identical to `c4b5818`; no new storage. Runtime 23,415 bytes
  (1,161 under EIP-170, up from 43).

## Sequence (all Base mainnet)

| # | Step | Signer | Hash | Block |
|---|------|--------|------|-------|
| 1 | Bundle `transferOwnership(0x9a70…cFb2)` | `0xF8e0` | `0x41664aa5938ba16d1ee8f655bd4059a44544975d2e35960210fa1100f0553285` | 51874284 |
| 2 | Bundle `acceptOwnership()` | `0x9a70` | `0x82816e70f94b35198fc583bd484c1227965f7cc57a19869d9a80052333adc18f` | 51875059 |
| 3 | OpenSea Studio: NewTrade Bundle V2 creator earnings → Remove Enforcement → 0% (off-chain) | `0x9a70` | — | — |
| 4 | Freeze ETH `setPaymentTokenAllowed(0x0, false)` | `0xF8e0` | `0xb85b72632cf582f0973dd8a503a2c0c2716ea3a075b3e33aa6fce15479cdbe1d` | 51876427 |
| 5 | Freeze WETH `setPaymentTokenAllowed(0x4200…0006, false)` | `0xF8e0` | `0xd864bf578f505a588bc318ceee0f51767fa28343d097a6ba8a5b78d52b472d08` | 51876430 |
| 6 | Freeze USDC `setPaymentTokenAllowed(0x8335…2913, false)` | `0xF8e0` | `0x74a52bc142d7c2b2f1c0de9b47c615549f78f72512319922e0e82818ac4dea1d` | 51876433 |
| 7 | Deploy implementation | `0xF8e0` | `0x1abe2b96c47b3016965e4901bcf3b3e2827946ff3098a155ff98ead9fb49c931` | 51876560 |
| 8 | `pre && upgradeToAndCall(impl, 0x)` | `0xF8e0` | `0xcc91c1bb5b8357ccfcde161989f426fd4284f24d6e7d42a1009884be9723c752` | 51876643 |
| 9 | Unfreeze ETH | `0xF8e0` | `0x85d466971ac90955418b6f8c01d2cb55f24d3fc861c6973195221c57bc0d2530` | 51877223 |
| 10 | Unfreeze WETH | `0xF8e0` | `0x635ec3903e3d43ebd6d32697597aa2df820a940a7b5504066a494cc9421586a5` | 51877225 |
| 11 | Unfreeze USDC | `0xF8e0` | `0x6d8073c2570b80cc52e57e86343629acfd96c170b6827091ffbbfc66330dafc5` | 51877228 |

Gas: deploy 5,142,955; upgrade 40,053. All receipts `status 1`.
Why the freeze: review found a check/send race (a listing opened or filled between the pre-check and
the switch would be settled under the wrong rules: double royalty forward, lost royalty on rollback).
With every payment token disallowed, `list()` cannot open anything during the switch.

Also: the new Bundle implementation `0x9182dC376e13d4d26612cDA495C41906592d8ab3` was verified on BaseScan
(`forge verify-contract`, Pass - Verified) so the proxy's Write tab works for the owner.

## Addresses

| Contract | Address |
|----------|---------|
| **Escrow (ERC1967 / UUPS proxy)** | `0xCc29F5c82C8b7c01Cac6036047E7413Df458f86d` |
| New implementation (option B) | `0x0c2e731755A069423CDD779CFDEc6146B2D9ba8a` |
| Previous implementation (rollback target) | `0xf3D5816D4CB14Fa949e476499Cb8A126d37af437` |
| Bundle collection (owner now `0x9a70…cFb2`) | `0x59900b207ea703b0bbcf8fd84c5e11de46826185` |
| Royalty receiver (dormant) | `0x9182E5b06Bf25A49c0e6Ed04d2A44146d25d4394` |

## Source and build

- **Reviewed source:** `380de42` (pre-release development history; not included in this repository); independent contract and package review passed.
- **Deployed from:** `88dfa82` = `380de42` merged into main (which carries the Bundle
  non-transferable change). `NewTradeEscrowV2.sol` imports `NewTradeBundle.sol`, so the Solidity
  metadata (CBOR) trailer differs from the reviewed build; the executable code is byte-identical:
  rebuilt `380de42` and `88dfa82` differ only in the final 51-byte metadata trailer (code without
  metadata equal).
- **On chain:** runtime 23,415 bytes, byte-equal to the `88dfa82` build after masking the UUPS `__self`
  immutables (holding `0x0c2e…ba8a`); masked sha256 `e55715acc30ff753f16afecf4176d239c9d743ac6ff4992950c5e2380c2897ad`
  (the reviewed package hash `4d731708…` is the same code with a different trailer). Initializers disabled
  (initialized version = max), `proxiableUUID` = the ERC-1967 slot.

## Verification

Before signing: `forge test` on the merged tree 626 passed / 0 failed; `EscrowOptionBUpgradeForkTest`
12/12 on Base (upgrade from `0xf3D5`, bundle #3 unchanged, 2.5% → `0xc3F9` proof sale with a real Seaport
fill crediting creator 0.025P and seller 0.915P, `withdrawFor`, rollback guard); fresh OpenSea fee record
`[{bps:100, 0x0000a26b…a719, required}]` only (the 5% → `0xF8e0` entry gone; collection page no longer
shows "5% CREATOR FEE"); `frozen` OK; `pre` OK (proxy on `0xf3D5`, Listed #3 has no routed snapshot,
totalOwed ETH 107,309,400,000 / USDC 0); upgrade simulated from `0xF8e0`: `0x`.

After (live): proxy on `0x0c2e…ba8a`; `getOrder(3)` byte-identical; routing views revert; totalOwed ETH
107,309,400,000 (unchanged) and USDC 0; DEFAULT_ADMIN_ROLE still `0xF8e0`; `unfrozen` OK (ETH, WETH, USDC
allowed).

## Rollback (only with the freeze)

Rolling back while a B listing is open loses that listing's creator royalty (the old code credits it to
the seller). Freeze (steps 4–6), confirm no B listing is open, then `cast send <proxy>
"upgradeToAndCall(address,bytes)" 0xf3D5816D4CB14Fa949e476499Cb8A126d37af437 0x …` from the upgrader,
then unfreeze.

## Machine-readable

```json
{
  "chainId": 8453,
  "network": "base-mainnet",
  "upgradedAt": "2026-09-27",
  "contract": "NewTradeEscrowV2",
  "proxy": "0xCc29F5c82C8b7c01Cac6036047E7413Df458f86d",
  "implementation": "0x0c2e731755A069423CDD779CFDEc6146B2D9ba8a",
  "previousImplementation": "0xf3D5816D4CB14Fa949e476499Cb8A126d37af437",
  "reviewedSourceCommit": "380de42",
  "deployedFromCommit": "88dfa82",
  "runtimeSha256Masked": "e55715acc30ff753f16afecf4176d239c9d743ac6ff4992950c5e2380c2897ad",
  "bundleOwner": "0x9a704664009d615A90ddDf9345B6b8B2A214cFb2",
  "openseaCreatorEarnings": "0%",
  "transactions": {
    "bundleTransferOwnership": "0x41664aa5938ba16d1ee8f655bd4059a44544975d2e35960210fa1100f0553285",
    "bundleAcceptOwnership": "0x82816e70f94b35198fc583bd484c1227965f7cc57a19869d9a80052333adc18f",
    "freezeETH": "0xb85b72632cf582f0973dd8a503a2c0c2716ea3a075b3e33aa6fce15479cdbe1d",
    "freezeWETH": "0xd864bf578f505a588bc318ceee0f51767fa28343d097a6ba8a5b78d52b472d08",
    "freezeUSDC": "0x74a52bc142d7c2b2f1c0de9b47c615549f78f72512319922e0e82818ac4dea1d",
    "deployImplementation": "0x1abe2b96c47b3016965e4901bcf3b3e2827946ff3098a155ff98ead9fb49c931",
    "upgradeToAndCall": "0xcc91c1bb5b8357ccfcde161989f426fd4284f24d6e7d42a1009884be9723c752",
    "unfreezeETH": "0x85d466971ac90955418b6f8c01d2cb55f24d3fc861c6973195221c57bc0d2530",
    "unfreezeWETH": "0x635ec3903e3d43ebd6d32697597aa2df820a940a7b5504066a494cc9421586a5",
    "unfreezeUSDC": "0x6d8073c2570b80cc52e57e86343629acfd96c170b6827091ffbbfc66330dafc5"
  }
}
```
