# NewTradeEscrowV2 — Base Mainnet Upgrade: protocol fee from proceeds (2026-09-26)

**Chain:** Base mainnet (8453)
**Signer:** `0xF8e03bd4436371E0e2F7C02E529b2172fe72b4EF` (deployer; DEFAULT_ADMIN_ROLE + UPGRADER_ROLE)
**Status:** ✅ seeder + implementation deployed, proxy upgraded and seeded in one transaction, verified on-chain

## Why

With the 5% protocol fee paid as a Seaport consideration item, OpenSea refused to ingest new
listings: bundle #3's merged 10% item to `0xF8e0` failed OpenSea's validation
("You have not provided all required creator fees"; the collection requires exactly 5% to `0xF8e0`),
and a distinct treasury would route the royalty to the (unclearable) royalty router, which OpenSea
also rejects. The fee now leaves the order entirely.

## What changed

- **Order shape:** a listing carries only `[escrow item, creator royalty, OpenSea fee]` (bundle #2's
  shape, which OpenSea ingests). No treasury/protocol-fee item.
- **Fee snapshot at `list()`:** the fee is frozen per bundle and emitted as
  `ProtocolFeeSnapshot(bundleId, token, amount)`; later fee changes never alter an existing listing.
- **At the first exit (sale):** the seller is credited `escrow item − frozen fee`; the fee stays in the escrow.
- **Owed ledger:** `totalOwed(token)` = sum of all sellers' `claimable`, maintained by a single private
  credit/debit path (source-guard tested).
- **`withdrawSurplus(token, to, amount)`** (DEFAULT_ADMIN_ROLE): withdraws at most `balance − totalOwed`
  (retained protocol fees and any stray funds). Reverts `InvalidState` if the amount exceeds the surplus,
  is zero, `to` is zero, or the ledger was never seeded.
- **Seeding:** a one-shot `NewTradeEscrowV2Seeder` (separate contract, because the escrow is 43 bytes
  under EIP-170) ran inside the upgrade transaction: it summed `claimable` for the supplied accounts per
  token, required `sum == balance` exactly, wrote `totalOwed`, then upgraded the proxy to the final implementation.
- **Existing listings:** bundle #3 (Listed, merged legacy item, no fee snapshot) is unchanged; its sale
  credits the full escrow item.
- Storage: the 25 existing slots are unchanged; `_protocolFeeAmount` (slot 21) and `_totalOwed`
  (slot 22) appended. Trust model: the admin/upgrader is fully trusted; checks target bugs and
  honest mistakes, not a malicious admin.

## Addresses

| Contract | Address |
|----------|---------|
| **Escrow (ERC1967 / UUPS proxy)** | `0xCc29F5c82C8b7c01Cac6036047E7413Df458f86d` |
| New implementation (NewTradeEscrowV2, fee from proceeds) | `0xf3D5816D4CB14Fa949e476499Cb8A126d37af437` |
| Seeder (NewTradeEscrowV2Seeder, one-shot, spent) | `0xBDA5EAC5dfB4C2Ec5275c11a50d75ca6be7FE6CB` |
| Previous implementation (rollback target) | `0x08306a31FC2Dd0a00bd8780961FcCb923E22c314` |

## Transactions

| Step | Hash | Block | Gas |
|------|------|-------|-----|
| Deploy seeder | `0x5d43a92a09aa18cb4ba96b650d9c7ce46a28a5a03f5ae6e33693f667461fef36` | 51823878 | 756,365 |
| Deploy implementation | `0xeaa99aa46f9835f091bcafee27b968eafb02ddafbb8997c18d578b34cfc1c256` | 51823881 | 5,384,743 |
| `upgradeToAndCall(seeder, seedAndUpgrade(final, [ETH, USDC], [0xF8e0, 0x9a70]))` | `0xa6935ca500f48dfa7deea11bb7a1e846eb513a08648d893193a4a9ed6e0b529b` | 51823918 | 106,811 |

All receipts `status 1`. The upgrade emitted `Upgraded(seeder)`, `TotalOwedSeeded(ETH, 9,409,400,000, 2)`,
`TotalOwedSeeded(USDC, 0, 2)`, `Upgraded(final)` and `Initialized(2)`.

## Source and build

- **Source:** `87cebf5` (pre-release development history; not included in this repository).
- **Build:** solc 0.8.28, `via_ir = true`, optimizer runs 1, evm `cancun`, default metadata.
- **Implementation:** 24,533 runtime bytes (43 under the 24,576 limit); masked runtime sha256
  (`__self` zeroed at 12045, 12586) `3f461aeb04dfcf7aed477e302fe01ebc1f913ccd02494a06ec763c156e339078`.
- **Seeder:** 3,132 runtime bytes; masked sha256 `1321494cadcd7ea91e02b137ea8f228b8c1cfbcf8a8fac06b877d969471aca84`.
- Both deployed contracts verified on chain (runtime hash, `proxiableUUID`, initializers disabled).

## Verification

Before signing:
- `forge test` at `87cebf5`: 519 passed, 0 failed.
- Fork suites at pinned blocks: `EscrowFeeFromProceedsUpgradeFork` 9/9 (upgrade + seed as the live
  upgrader, both sellers withdraw exactly, omitted-account plant reverts, bare-upgrade latch, stray send
  is admin-only surplus, bundle #3 unchanged with a full-item credit on a real fill, fresh listing + real
  Seaport fill crediting 0.89P and leaving 0.05P as surplus, rollback); independent review fork suite 6/6.
- Clean build in the repo: both masked hashes match the package.
- Live pre-flight (block 51,821,734 and again after the deploys): proxy on `0x0830…c314`;
  ETH balance 9,409,400,000 = claimable(0xF8e0) 9,400,000,000 + claimable(0x9a70) 9,400,000; USDC 0.
- Upgrade simulated from `0xF8e0`: `0x`.

After the upgrade (live, Base):
- ERC-1967 implementation slot = `0xf3D5816D4CB14Fa949e476499Cb8A126d37af437`; initialized version 2 (seeded).
- `totalOwed(ETH)` 9,409,400,000 = claimable sum = balance, surplus 0; `totalOwed(USDC)` 0.
- `getOrder(3)` byte-identical to the pre-upgrade snapshot.
- DEFAULT_ADMIN_ROLE still `0xF8e0`; `claimable(0x9a70, ETH)` still 9,400,000.

## Collecting the protocol fee

```bash
# surplus = balance - totalOwed (ETH shown)
echo $(( $(cast balance 0xCc29F5c82C8b7c01Cac6036047E7413Df458f86d --rpc-url https://mainnet.base.org) - $(cast call 0xCc29F5c82C8b7c01Cac6036047E7413Df458f86d 'totalOwed(address)(uint256)' 0x0000000000000000000000000000000000000000 --rpc-url https://mainnet.base.org | cut -d' ' -f1) ))
cast send 0xCc29F5c82C8b7c01Cac6036047E7413Df458f86d "withdrawSurplus(address,address,uint256)" 0x0000000000000000000000000000000000000000 <TO> <AMOUNT> --rpc-url https://mainnet.base.org --account <owner-keystore>
```

## Rollback

```bash
cast send 0xCc29F5c82C8b7c01Cac6036047E7413Df458f86d "upgradeToAndCall(address,bytes)" 0x08306a31FC2Dd0a00bd8780961FcCb923E22c314 0x --rpc-url https://mainnet.base.org --account <owner-keystore>
```

Sellers' `claimable` stays intact and withdrawable (fork-tested). **One-way for the ledger:** after a
rollback the old code does not maintain `totalOwed` and `reinitializer(2)` is spent; do NOT re-apply
this upgrade with a bare `upgradeToAndCall(final, 0x)`. Moving forward again needs a new seeder at
`reinitializer(3)` (new build and review).

## Machine-readable

```json
{
  "chainId": 8453,
  "network": "base-mainnet",
  "upgradedAt": "2026-09-26",
  "contract": "NewTradeEscrowV2",
  "proxy": "0xCc29F5c82C8b7c01Cac6036047E7413Df458f86d",
  "implementation": "0xf3D5816D4CB14Fa949e476499Cb8A126d37af437",
  "seeder": "0xBDA5EAC5dfB4C2Ec5275c11a50d75ca6be7FE6CB",
  "previousImplementation": "0x08306a31FC2Dd0a00bd8780961FcCb923E22c314",
  "admin": "0xF8e03bd4436371E0e2F7C02E529b2172fe72b4EF",
  "protocolFeeBps": 500,
  "sourceCommit": "87cebf5",
  "contractSourceCommit": "c4b5818",
  "runtimeSha256Masked": {
    "implementation": "3f461aeb04dfcf7aed477e302fe01ebc1f913ccd02494a06ec763c156e339078",
    "seeder": "1321494cadcd7ea91e02b137ea8f228b8c1cfbcf8a8fac06b877d969471aca84"
  },
  "seed": { "ETH": "9409400000", "USDC": "0", "accounts": ["0xF8e03bd4436371E0e2F7C02E529b2172fe72b4EF", "0x9a704664009d615A90ddDf9345B6b8B2A214cFb2"] },
  "transactions": {
    "deploySeeder": "0x5d43a92a09aa18cb4ba96b650d9c7ce46a28a5a03f5ae6e33693f667461fef36",
    "deployImplementation": "0xeaa99aa46f9835f091bcafee27b968eafb02ddafbb8997c18d578b34cfc1c256",
    "upgradeToAndCall": "0xa6935ca500f48dfa7deea11bb7a1e846eb513a08648d893193a4a9ed6e0b529b"
  },
  "blocks": { "deploySeeder": 51823878, "deployImplementation": 51823881, "upgradeToAndCall": 51823918 }
}
```
