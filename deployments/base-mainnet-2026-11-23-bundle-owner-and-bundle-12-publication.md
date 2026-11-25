# NewTradeBundle ownership back to 0x9a70, and bundle #12 published to OpenSea — Base Mainnet (2026-11-23)

**Chain:** Base mainnet (8453)
**Signers:**
- `0xF8e03bd4436371E0e2F7C02E529b2172fe72b4EF` (Bundle owner before the move: `transferOwnership`).
- `0x9a704664009d615A90ddDf9345B6b8B2A214cFb2` (owner: approval, deposit and listing of bundle #12, then `acceptOwnership`).

**Status:** ✅ Done.
- The Bundle collection is owned by `0x9a70…cFb2`.
- OpenSea requires only its 1% marketplace fee on `newtrade-bundle-v2`.
- Bundle #12 is listed on chain, Seaport-validated and unfilled. OpenSea reports its order ACTIVE.

No contract was deployed or upgraded.

## Why

Bundle #12 is controlled by NewTrade Beta NFT v2 #1 and holds 0.00001 USDC. It was listed on chain and validated in Seaport.

**The rejected post.** With the owner's approval, the operator posted the order to OpenSea's listing API, because the owner decided listings must reach OpenSea through the API right away. OpenSea answered HTTP 400 "Validation error: You have not provided all required creator fees". The `newtrade-bundle-v2` collection again required 1% to OpenSea **and 5% to `0xF8e0`**. At 15:01 UTC the same day it had required 1% only, and bundle #11 was ingested then. The same reset happened on 2026-11-22 (F-01 live report).

**Why the creator fee breaks these orders.** Under escrow option B, an order carries only `[escrow item, OpenSea 1%]`, and the escrow credits the controlling NFT's ERC-2981 creator royalty in its ledger at the sale. An order cannot also carry a direct 5% creator payout. So an OpenSea creator-fee requirement rejects every escrow order.

**The recovery (the owner's approval):**
1. Bundle ownership moved back from `0xF8e0` to the owner's `0x9a70` (two-step Ownable).
2. The owner set the collection's OpenSea creator earnings to 0% from `0x9a70` in OpenSea Studio.
3. Once OpenSea's API showed the 1% marketplace fee only (16:52 EST, 21:52 UTC), the operator posted #12 again. The answer was HTTP 200 ACTIVE.

**Root cause.** Still open (operator report). The on-chain inputs OpenSea reads for creator attribution did not change between the 1%-only and 5% observations. Those inputs are the ERC-173 owner `0xF8e0`, the royalty recipient `0xF8e0` and the Royalty Registry lookup. OpenSea publishes no change history, so the trigger is not identified.

## On-chain transactions vs off-chain actions

Only the transactions below are on Base. The fee changes and the API posts are OpenSea-side actions. They have no transaction hash and cannot be verified on chain; they are recorded here from the operator's reports and OpenSea API reads.

| Kind | Action | Who | When (UTC) | Evidence |
|---|---|---|---|---|
| on-chain | Approve, deposit and list bundle #12 (transactions 1–3) | `0x9a70` | 21:28:40–21:29:34 | Base receipts |
| off-chain | POST of #12's order to OpenSea → HTTP 400 "You have not provided all required creator fees" | operator | after 21:29:34 (exact time not recorded) | operator report; OpenSea GET by hash returned 400 "Order not found" at 21:35:50 (independent readback) |
| off-chain | OpenSea collection fees: 1% OpenSea + 5% `0xF8e0`, both required | OpenSea | read at 21:35:50 | independent readback |
| on-chain | Bundle `transferOwnership(0x9a70…cFb2)` (transaction 4) | `0xF8e0` | 21:45:56 | Base receipt |
| on-chain | Bundle `acceptOwnership()` (transaction 5) | `0x9a70` | 21:48:23 | Base receipt |
| off-chain | OpenSea Studio: creator earnings 0% | The owner, from `0x9a70` | after 21:48:23 (inferred: Studio edits need the owner wallet) | operator report |
| off-chain | OpenSea API shows the 1% marketplace fee only | OpenSea | 21:52 (16:52 EST) | operator report; reread 21:55:25 (independent readback) and 21:57:17 (this report) |
| off-chain | POST of #12's order to OpenSea → HTTP 200 ACTIVE; the app's readback active | operator | after 21:52 | operator report; GET by hash ACTIVE at 21:55:25 and 21:57:17 |

## Sequence (all Base mainnet; every hash and block re-read from chain for this report)

| # | Step | Signer | Hash | Block | Gas used | Fee (wei) |
|---|------|--------|------|------:|---------:|----------:|
| 1 | Beta NFT v2 `approve(D4 vault 0xe3a9…9C53, 1)` | `0x9a70` (nonce 248) | `0x224376f4e7e7ec08792ab7891ba868cde83456de81ee9eaacad7249b8c44f2d8` | 61394725 | 48,340 | 518,678,720,624 |
| 2 | Escrow `depositFromAccount(0x5935…7e1b, 0x6E68…E409, 1, [USDC 10], 1796678893, manifest)`: bundle #12 (receipt #12), Beta v2 #1 and 10 USDC units into custody | `0x9a70` (nonce 249) | `0xf60e0a4a3d8c2d1812a773cdf627a91d4a42ac733dd1edf8f23a4c83c82c1b15` | 61394853 | 709,699 | 7,382,481,941,045 |
| 3 | Escrow `list(12, ETH, 100000000, 1796678893, 500, [escrow 99,000,000; OpenSea 1,000,000])` → order `0xec6083c4…6d88` | `0x9a70` (nonce 250) | `0xdfe9792f4c3684f0ce206e8c39f427d6949329678af6c71d8e60b8b7d97bd84d` | 61394994 | 617,302 | 21,648,196,579,310 |
| 4 | Bundle `transferOwnership(0x9a704664009d615A90ddDf9345B6b8B2A214cFb2)` | `0xF8e0` (nonce 306) | `0x61d9944a45896b66e69c26a1e04b0fc84ff95e1a9f2bd417d402f6f35b2a7225` | 61399902 | 53,269 | 320,773,403,154 |
| 5 | Bundle `acceptOwnership()` | `0x9a70` (nonce 251) | `0xb27e8bf223c31ea0571b6fc6de809d9458ef1b04ac17664be82f3559f2d4d53c` | 61400639 | 33,557 | 729,198,664,720 |

Timing (block timestamps):

| step | time | block |
|---|---|---:|
| approve | 2026-11-23T21:28:40Z | 61394725 |
| deposit | 2026-11-23T21:29:06Z | 61394853 |
| list | 2026-11-23T21:29:34Z | 61394994 |
| transferOwnership | 2026-11-23T21:45:56Z | 61399902 |
| acceptOwnership | 2026-11-23T21:48:23Z | 61400639 |

**Completeness.** These are the only transactions from either signer in the range. The deployer's nonce went from 306 to 307, extending the ledger's audited range (176–305) by one transaction. `0x9a70`'s nonce went from 248 to 252. Each nonce was located by bisection and its receipt read by hash.

## Bundle #12 order

| Field | Value (from the `list` calldata, BundleListed and SaleConsideration events) |
|---|---|
| Order hash | `0xec6083c43224f739fd56b02ba3f92619b7832eec3b6d03a39eca05f52e5f6d88` (Seaport OrderValidated in transaction 3) |
| Controller | NewTrade Beta NFT v2 `0x6E68Ac288b74c0B30d9B3bE944c6ff708D12E409` #1, account `0x59352B831a46139257CbcF9CFa74AFe64ce37e1b` |
| Manifest | 10 units of USDC `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` (0.00001 USDC) |
| Payment token, price | ETH, 100,000,000 wei |
| Consideration | escrow `0xCc29…f86d` 99,000,000; OpenSea fee `0x0000a26b00c1F0DF003000390027140000fAa719` 1,000,000 (1%) |
| Creator royalty snapshot | 5,000,000 wei (5%) to `0xF8e0…b4EF` (the Beta v2 collection's ERC-2981), credited in the escrow ledger at a sale |
| Protocol fee snapshot | 5,000,000 wei (500 bps) |
| Custody deadline | 1796678893 (2026-12-07T21:28:13Z) |

## Verification (read-only)

**Base, block 61403135 (2026-11-23T21:56:42Z):**
- Bundle `owner()` = `0x9a704664009d615A90ddDf9345B6b8B2A214cFb2`, and `pendingOwner()` = `0x0`.
- Bundle `imageBaseURI()` is unchanged: `https://newtrade-app.vercel.app/api/v2/bundle-art/`.
- Bundle `ownerOf(12)` and `ownerOf(11)` = escrow `0xCc29…f86d` (listed, unsold).
- Beta v2 `ownerOf(1)` = D4 vault `0xe3a9…9C53`. The account `0x5935…7e1b` holds 0 USDC, because its 10 units are in custody.
- Seaport `getOrderStatus` for #12 `0xec6083c4…6d88` and for #11 `0x2da85280…33d9`: validated, not cancelled, filled 0/0.
- Bundle `royaltyInfo(12, 100000000)` = (`0xF8e0…b4EF`, 5,000,000). `royaltyInfo(11, 1000000)` = (`0xF8e0…b4EF`, 50,000). The on-chain royalty is unchanged by the recovery. Only OpenSea's off-chain enforcement changed.

**OpenSea API, GET only, 2026-11-23T21:57:17Z:**
- `GET /api/v2/collections/newtrade-bundle-v2`: fees `[{fee: 1, recipient: 0x0000a26b…a719, required: true}]`, with no creator fee.
- `GET /api/v2/orders/chain/base/protocol/0x0000…b395/0xec6083c4…6d88`: 200, ACTIVE, price 100,000,000.
- `GET /api/v2/listings/collection/newtrade-bundle-v2/nfts/12/best`: the same order, ACTIVE.
- Bundle #11's order `0x2da85280…33d9` reads ACTIVE on both endpoints.

## Reversibility

- **Ownership:** reversible with the same two-step Ownable. The current owner `0x9a70` calls `transferOwnership(new)` and the new owner calls `acceptOwnership()`. No funds or listings depend on the owner. The escrow, vault and royalty paths do not read it.
- **OpenSea creator earnings:** reversible only off-chain, by the collection owner in OpenSea Studio. It has reset twice without any on-chain change. If it reappears, OpenSea will again reject new escrow orders with "required creator fees", while orders already ingested stay ACTIVE. The permanent fix is still open (item 59 (1)).
- **The #12 listing:** the seller can reclaim bundle #12 from the escrow, and after the 2026-12-07 deadline the reclaim path returns Beta v2 #1 and the USDC. The OpenSea post itself has no on-chain effect: the order's on-chain validation alone makes it fillable on Seaport.

## Sources

- **Base mainnet receipts and state reads** (public RPC) for every hash, block and value above.
- **The OpenSea API** (GET only, the app's key read in-process).
- **Operator reports** of the 400 and 200 POSTs, the owner\'s Studio change and the 16:52 EST fee observation.
- **Independent OpenSea readbacks:** 21:35:50 UTC: fees 1% + 5%, #12 GET 400; 21:55:25 UTC: owner `0x9a70`, fees 1% only, #12 ACTIVE.

## Machine-readable

```json
{
  "chainId": 8453,
  "network": "base-mainnet",
  "kind": "admin-and-listing-publication",
  "recordedAt": "2026-11-23",
  "bundleCollection": "0x59900b207ea703B0bBcF8fD84C5E11dE46826185",
  "bundleOwner": { "from": "0xF8e03bd4436371E0e2F7C02E529b2172fe72b4EF", "to": "0x9a704664009d615A90ddDf9345B6b8B2A214cFb2" },
  "escrowProxy": "0xCc29F5c82C8b7c01Cac6036047E7413Df458f86d",
  "vaultProxy": "0xe3a95e47B8ECC9F8E42a7BDE58dde2FBCbc69C53",
  "bundleId": 12,
  "controller": { "collection": "0x6E68Ac288b74c0B30d9B3bE944c6ff708D12E409", "tokenId": 1, "account": "0x59352B831a46139257CbcF9CFa74AFe64ce37e1b" },
  "manifest": [{ "token": "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913", "amount": "10", "display": "0.00001 USDC" }],
  "order": {
    "hash": "0xec6083c43224f739fd56b02ba3f92619b7832eec3b6d03a39eca05f52e5f6d88",
    "paymentToken": "0x0000000000000000000000000000000000000000",
    "priceWei": "100000000",
    "escrowWei": "99000000",
    "openseaFeeWei": "1000000",
    "creatorRoyaltySnapshotWei": "5000000",
    "protocolFeeSnapshotWei": "5000000",
    "custodyDeadline": 1796678893
  },
  "transactions": {
    "approveVault": "0x224376f4e7e7ec08792ab7891ba868cde83456de81ee9eaacad7249b8c44f2d8",
    "depositFromAccount": "0xf60e0a4a3d8c2d1812a773cdf627a91d4a42ac733dd1edf8f23a4c83c82c1b15",
    "list": "0xdfe9792f4c3684f0ce206e8c39f427d6949329678af6c71d8e60b8b7d97bd84d",
    "bundleTransferOwnership": "0x61d9944a45896b66e69c26a1e04b0fc84ff95e1a9f2bd417d402f6f35b2a7225",
    "bundleAcceptOwnership": "0xb27e8bf223c31ea0571b6fc6de809d9458ef1b04ac17664be82f3559f2d4d53c"
  },
  "blocks": {
    "approveVault": 61394725,
    "depositFromAccount": 61394853,
    "list": 61394994,
    "bundleTransferOwnership": 61399902,
    "bundleAcceptOwnership": 61400639
  },
  "offchain": {
    "firstPost": { "result": "HTTP 400", "error": "Validation error: You have not provided all required creator fees.", "collectionFees": ["1% OpenSea (required)", "5% 0xF8e03bd4436371E0e2F7C02E529b2172fe72b4EF (required)"], "source": "operator report; independent readback 2026-11-23T21:35:50Z" },
    "creatorEarningsSetToZero": { "by": "0x9a704664009d615A90ddDf9345B6b8B2A214cFb2", "via": "OpenSea Studio", "source": "operator report" },
    "marketplaceFeeOnlyObservedAt": "2026-11-23T21:52:00Z",
    "secondPost": { "result": "HTTP 200 ACTIVE", "source": "operator report" },
    "readback": { "at": "2026-11-23T21:57:17Z", "collectionFees": [{ "fee": 1, "recipient": "0x0000a26b00c1f0df003000390027140000faa719", "required": true }], "order12": "ACTIVE", "order11": "ACTIVE" }
  },
  "verifiedStateBlock": 61403135,
  "rootCause": "open (operator report)"
}
```
