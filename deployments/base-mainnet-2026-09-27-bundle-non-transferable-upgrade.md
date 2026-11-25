# NewTradeBundle — Base Mainnet Upgrade: claims non-transferable after the first sale (2026-09-27)

**Chain:** Base mainnet (8453)
**Signer:** `0xF8e03bd4436371E0e2F7C02E529b2172fe72b4EF` (deployer, Bundle owner)
**Status:** ✅ implementation deployed + proxy upgraded + verified on-chain

## Why

Owner decision (2026-09-26): a Bundle claim NFT can only be redeemed by its buyer, never
resold or sent. This closes the creator-fee gap on secondary resales (the planned escrow option B
sets OpenSea's collection creator earnings to 0% and pays each controlling NFT's royalty through the
escrow ledger on the primary sale, which is then the only sale).

## What changed

- `_update`: mint and burn stay controller-only (the escrow). The ONLY holder-to-holder move allowed
  is the first exit, the escrow giving the claim to its buyer in the Seaport fill
  (`previous == controller`), still authorized by the ERC-721C validator and still notifying the escrow
  once. Every other transfer (holder, approved operator, second marketplace fill, send to another
  wallet) reverts `NonTransferable()` before the validator is consulted.
- `tokenURI`: description now says "a redeem-only claim … This claim can only be redeemed by its
  holder; it cannot be transferred or resold."; new attribute `{"trait_type":"Transferable","value":"No (redeem only)"}`.
- No storage change (layout identical), no other behaviour change. Redemption (`redeemToFreshAccount`
  → `controllerBurn`) and reclaim of unsold bundles are unaffected.

## Addresses

| Contract | Address |
|----------|---------|
| **Bundle (ERC1967 / UUPS proxy)** | `0x59900b207ea703b0bbcf8fd84c5e11de46826185` |
| New implementation (NewTradeBundle, non-transferable) | `0x9182dC376e13d4d26612cDA495C41906592d8ab3` |
| Previous implementation (rollback target) | `0x29DaD81D121CaB79343A191EeB071317858319d6` |

Note: the new implementation's address shares the `0x9182` prefix with the unrelated royalty receiver
`0x9182E5b06Bf25A49c0e6Ed04d2A44146d25d4394`; they are different contracts.

## Transactions

| Step | Hash | Block | Gas |
|------|------|-------|-----|
| Deploy implementation | `0xdd86016daa16c555d2fa6f83f94120fd789c4a2ed6bc6fbc33c0dcc626363875` | 51863175 | 3,801,120 |
| `upgradeToAndCall(impl, 0x)` | `0x195fbc0ba81ba7b68e3533719df73186acf16010a964df3cfa964fdcd41c979a` | 51863513 | 37,764 |

Both receipts `status 1`; the upgrade emitted `Upgraded(0x9182dC37…8ab3)`.

## Source and build

- **Source:** `dcb925d` (pre-release development history; not included in this repository).
- **Build:** solc 0.8.28, `via_ir = true`, optimizer runs 1, evm `cancun`, default metadata.
- **Implementation:** 17,210 runtime bytes (margin 7,366); masked runtime sha256 (`__self` zeroed at
  6765, 6913) `5267ae0cbc9e641a922549f6b240fc1dbd32cf6faf8588962342b59a9eb97581`; verified on chain
  (hash match, no owner, initializers disabled).

## Verification

Before signing: read the 22-line source diff; clean build hash matches the package;
`forge test` 558 passed / 0 failed; `BundleNonTransferableUpgradeForkTest` on Base 8/8; pre-flight
(proxy on `0x29Da…19d6`, owner `0xF8e0`); upgrade simulated from `0xF8e0`: `0x`.

After the upgrade (live): proxy runs `0x9182dC37…8ab3`; `tokenURI(3)` = the old JSON plus exactly the
sentence and the Transferable attribute with "a transferable claim" → "a redeem-only claim" (valid
JSON); `supportsInterface` unchanged for 0x01ffc9a7, 0x80ac58cd, 0x5b5e139f, 0x2a55205a, 0xad0d7f6c,
0x49064906; owner `0xF8e0`, controller `0xCc29…f86d`, image renderer `0x4519…56c5`, external base URL
and transfer validator `0xA000…0000` unchanged. No Issued claim exists on chain today (every sold
bundle is redeemed; #3 is Listed in escrow), so `NonTransferable` is proven by the Base fork tests
(block 51,839,800, bundle #4's holder), not by a live call.

## Rollback

```bash
cast send 0x59900b207ea703b0bbcf8fd84c5e11de46826185 "upgradeToAndCall(address,bytes)" 0x29DaD81D121CaB79343A191EeB071317858319d6 0x --rpc-url https://mainnet.base.org --account <owner-keystore>
```

Restores transferability and the previous metadata (fork-tested); no storage to undo.

## Machine-readable

```json
{
  "chainId": 8453,
  "network": "base-mainnet",
  "upgradedAt": "2026-09-27",
  "contract": "NewTradeBundle",
  "proxy": "0x59900b207ea703b0bbcf8fd84c5e11de46826185",
  "implementation": "0x9182dC376e13d4d26612cDA495C41906592d8ab3",
  "previousImplementation": "0x29DaD81D121CaB79343A191EeB071317858319d6",
  "owner": "0xF8e03bd4436371E0e2F7C02E529b2172fe72b4EF",
  "sourceCommit": "dcb925d",
  "runtimeSha256Masked": "5267ae0cbc9e641a922549f6b240fc1dbd32cf6faf8588962342b59a9eb97581",
  "transactions": {
    "deployImplementation": "0xdd86016daa16c555d2fa6f83f94120fd789c4a2ed6bc6fbc33c0dcc626363875",
    "upgradeToAndCall": "0x195fbc0ba81ba7b68e3533719df73186acf16010a964df3cfa964fdcd41c979a"
  },
  "blocks": { "deployImplementation": 51863175, "upgradeToAndCall": 51863513 }
}
```
