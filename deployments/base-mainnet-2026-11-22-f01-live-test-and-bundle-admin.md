# F-01 Base live test (one command) and Bundle admin — Base Mainnet (2026-11-22)

**Chain:** Base mainnet (8453)
**Signers:** `0xF8e03bd4436371E0e2F7C02E529b2172fe72b4EF` (deployer: funding, Bundle `acceptOwnership` and `setImageBaseURI`), `0x9a704664009d615A90ddDf9345B6b8B2A214cFb2` (Bundle owner before: `transferOwnership`), and three runner-generated test wallets (SELLER `0x57Ae6566f142646Ab5000c46186D5d6f2b0728bC`, BUYER `0xe8b0A080c5a897B2594FB939C7749b93c9017799`, HELPER `0x1F23a8aDeba9F113816cBc547508ad2805331D34`)
**Status:** ✅ PHASE 1 OK and PHASE 2 OK. Two OpenSea fills, 50 runner transactions plus 3 Bundle admin transactions, every receipt `status 1`, test wallets swept to 0 wei. The seller deployed four test contracts. The production escrow and Bundle implementations stayed at their F-01 versions.

## Why

This was the end-to-end live exercise of the F-01 partial-release contracts on production. The upgrade itself is recorded in
`base-mainnet-2026-11-22-f01-partial-release-upgrade.md`. The owner approved one live run. The run deposited four bundles,
listed two through the escrow, bought both through OpenSea's own `fulfillment_data`, then went through every exit:
- a clean redeem and a partial redeem;
- a full reclaim and a partial reclaim;
- the seller redirect;
- helper completion;
- withdrawal of the seller's proceeds;
- a sweep of every test wallet back to the deployer.

In the same window the operator returned the Bundle collection's ownership to the deployer and pointed its image base URI at the app's bundle-art route.

## What happened

- **Runner:** package `7e19e66701992687c7391b6946ac56ba5780c2db`, Node v22.23.4. Contracts pinned at `c575b727823e23a2dc83a53e7829ba5eb944f4e0`.
  - It was confirmed under binding `ca56d106aaec…`, and later re-bound (typed confirmation) to `77653bc7942b` after the verifier fix (runner `5faf8cae234a` → `ccac31d71dc0`, verifier `7fad6faf50d9` → `10f2618d6b74`).
  - The funder, the sweep destination, the 35 recorded transactions, the 8 completed steps, the wallets, the book and the bundle ids were all kept unchanged across the re-bind.
- **Bundles:** W R C F = **7 8 9 10**, 30 seller-phase transactions, including four actual bundle deposits. Book `0xf1d5faDB136aD21d9dcf58614993a6D2b1C6b5A4`.
- **Listings:** #8, order `0x112cc45a3e4824bc5153280051fda50b35b0d6b6580e94e4ef6922bf63fe34f7`; #10, order `0xaf6371f37d47a74ffa301fd0f7fecba93f44fd72872234d48643d8e059c1e38e`. Each was 1,000,000 wei (escrow 990,000 + OpenSea 10,000), counter 0.
- **OpenSea (off-chain):**
  - OpenSea refused both orders for about 45 minutes because the collection's OpenSea settings again required a 5% creator fee to `0xF8e0`.
  - the owner set creator earnings back to 0% (about 12:28 EST).
  - With the owner's approval both on-chain orders were POSTed with the operator listing script (sha `334c6a21`): `200 ACTIVE`.
  - These posts have no transaction hash.
- **First resume:** stopped before sending anything. The verifier refused OpenSea's 0x-hex `salt`. It was fixed in verifier `10f2618d6b74` (`967d89f`, packaged by op `7e19e66`).
- **Bundle admin (operator, between the fills):**
  - `transferOwnership(0xF8e0)` by `0x9a70`;
  - `acceptOwnership()` by `0xF8e0`;
  - `setImageBaseURI("https://newtrade-app.vercel.app/api/v2/bundle-art/")` (previous value: empty string).

## Sequence (all Base mainnet; every hash and block re-read from chain for this report)

Runner journal (50 transactions; `~/.newtrade-f01-base-one-ok/state/summary.json`, re-verified receipt by receipt):

| # | Runner step | Signer (nonce) | Operation | Block | Transaction |
|---:|---|---|---|---:|---|
| 1 | fund-SELLER | deployer (295) | ETH transfer | 60865356 | `0x9283f4b407f65bc7c9358c8024beefd3fdedd1e739025088270deebffc2877d3` |
| 2 | fund-BUYER | deployer (296) | ETH transfer | 60865368 | `0xce8baad2ab81cad52452cd443d183f36fdc198afdd63dfe9a6be9c463473671e` |
| 3 | fund-HELPER | deployer (297) | ETH transfer | 60865379 | `0xb415b49ca9532b173a165f4181a3312e1bf684e24594f800ab8284e2a1f24aee` |
| 4 | sellerDeposits | SELLER (0) | CREATE test contract `0xf1d5fadb136ad21d9dcf58614993a6d2b1c6b5a4` | 60865419 | `0x7e297b1d615b8ef4b61d4a65dad5e50470afffd9336cfb3727112de15f242111` |
| 5 | sellerDeposits | SELLER (1) | CREATE test contract `0xdb01af27aaa03a2559c343e29a921f4758295884` | 60865421 | `0xaeef74a7413d1c35793c8370310f65b7ce3b998000c161d1fa6bb55d5c9afdd5` |
| 6 | sellerDeposits | SELLER (2) | CREATE test contract `0xe43ad1a460aa47819c17f003fbc60772387cf3c0` | 60865424 | `0x9dee0da602a715d494c3db13ae1b8c517073d5b0250a8f698de3bb37b9e5478f` |
| 7 | sellerDeposits | SELLER (3) | CREATE test contract `0x2e9e80c591661ff57c1d399ad4c910eed2f2fe55` | 60865426 | `0x3dcd682fe2d2b221a0088e2199bd1610c337eb72c43612fb3bdbbddf9031eb38` |
| 8 | sellerDeposits | SELLER (4) | test token mint | 60865429 | `0x5e1d759467993dc94ebc0f637f9eb9225906ffccd729b49718ce0b1027cf1156` |
| 9 | sellerDeposits | SELLER (5) | test token mint | 60865433 | `0xe94f3dac49a3609fcab67bf0098a8506865fc6a36329613861ad7497b4ce0384` |
| 10 | sellerDeposits | SELLER (6) | test token approve | 60865435 | `0x648fb1e7ac5bae3441fe5a911037314cdd620bfef8ec547cb393d153c31d1786` |
| 11 | sellerDeposits | SELLER (7) | test token approve | 60865437 | `0xe3bea2e40f5dc1a415d2ffe5f142bf5c479760b0341a086563e240da41c4e730` |
| 12 | sellerDeposits | SELLER (8) | escrow deposit: BundleDeposited #7 | 60865439 | `0x4312e1b8be76566a448141aac0ab9ba8b6c631ec01a2e3ef9fdd9a5a40875162` |
| 13 | sellerDeposits | SELLER (9) | test token mint | 60865441 | `0xfbe44174660dbc415188980a5ce36b2085f98883d1918a94fd39a76ca79f14fa` |
| 14 | sellerDeposits | SELLER (10) | ERC-6551 createAccount | 60865443 | `0x7df85799ff266c88cccc833406ecfa30d6a14b9ee69c25bf1c4e250fb916e387` |
| 15 | sellerDeposits | SELLER (11) | account initialize | 60865445 | `0xfe9bdeeca3b2b911d9fefd81bece6573883db49f4e6184c5503ea5b50b998d56` |
| 16 | sellerDeposits | SELLER (12) | test token mint | 60865447 | `0x8f14445d311d590b4948ba3da276d058e5a46cc1637e7699f90a713b0186edd2` |
| 17 | sellerDeposits | SELLER (13) | test token mint | 60865449 | `0x0f9f6413c4ff0d1db9f4ad3b4d5e16b9f4763344b911c9adc62ce39617a013c5` |
| 18 | sellerDeposits | SELLER (14) | test token approve | 60865451 | `0x67bd27160f9d0d8137129d55deb588e3973c03f2ce540d6543d9163e1e25a5a6` |
| 19 | sellerDeposits | SELLER (15) | escrow depositFromAccount: BundleDeposited #8 BundleMigrated #8 | 60865453 | `0x3d6670836621a8cd9c5b0ca3b228339d99916b28772f50296c219a9df3b351a6` |
| 20 | sellerDeposits | SELLER (16) | test token mint | 60865455 | `0x0f193e3c63b8d61199d741d2e525208de29c70b167810eaec26342d2d3d5a332` |
| 21 | sellerDeposits | SELLER (17) | ERC-6551 createAccount | 60865457 | `0xf464561787fd9d0fc7efe5be5e4596e65a34230b867d950cbe677cfb135949f6` |
| 22 | sellerDeposits | SELLER (18) | account initialize | 60865459 | `0x3870f6d34e3c8054858c8e3ec9630e09f0299c0db29ceb7d67c9f06c849bf542` |
| 23 | sellerDeposits | SELLER (19) | test token mint | 60865461 | `0xf18fc88a1344fe05fc0532677d98eb69e9561a4e72ae3afc6996e5a62862857a` |
| 24 | sellerDeposits | SELLER (20) | test token mint | 60865463 | `0x1d4e519e6560fdc525adb8be05f33df633937bb032f501b2238ed6b8edb2ced3` |
| 25 | sellerDeposits | SELLER (21) | test token approve | 60865465 | `0x7955bb71d371100a63a3c4260297cfac4b794b29fccf6365a3c0f6f70c596b09` |
| 26 | sellerDeposits | SELLER (22) | escrow depositFromAccount: BundleDeposited #9 BundleMigrated #9 | 60865467 | `0x6195ca44ced7caf26d97cc456fb3307a5a6dd64a6805eb92bfefd71ad5964734` |
| 27 | sellerDeposits | SELLER (23) | test token mint | 60865469 | `0xcda5cce1877000fca1227c05ead891806be79b279008ea2ee8948f534ca6a348` |
| 28 | sellerDeposits | SELLER (24) | ERC-6551 createAccount | 60865471 | `0xac723261f5132b1e096c95432aa5096a90103856971d978e7efb192d9a2b2d8a` |
| 29 | sellerDeposits | SELLER (25) | account initialize | 60865473 | `0x91ea0955a32b0df92e6a35495fc2897bfb7645faa9f0dc193f3227d307d340fa` |
| 30 | sellerDeposits | SELLER (26) | test token mint | 60865475 | `0x26bb417de2f616f5b75bde593cddd6ef2f7934b9d11fd44bdd25425da8fb2414` |
| 31 | sellerDeposits | SELLER (27) | test token approve | 60865477 | `0xbe21a046a526931be1238e74a1425c5d5ed5a0a7f4fd1c65379c04f1382d96f5` |
| 32 | sellerDeposits | SELLER (28) | escrow depositFromAccount: BundleDeposited #10 BundleMigrated #10 | 60865479 | `0xf4a182ae28ce754eb55142be64b563a6f958143bce8e181e01123948a048046b` |
| 33 | sellerDeposits | SELLER (29) | test book call | 60865481 | `0x89f6917cef8415062e8e406a6d2980278bc3e5f4fb6fbf5ff9fde7ad01e49b73` |
| 34 | sellerList | SELLER (30) | escrow list: BundleListed #8 | 60865584 | `0xe4dc5731df50f8fc4f39e9d5fc91dcb63bd10abfbe609215f93fbc6c7f2b24bd` |
| 35 | sellerList | SELLER (31) | escrow list: BundleListed #10 | 60865586 | `0xe0d5bc8e387b61505eb75b6018f34106ca1e1b10d1568a1190dfdbe6f50d1db7` |
| 36 | fillR | BUYER (0) | Seaport fulfillAdvancedOrder: BundleIssued #8 ProceedsCredited #8 | 60903914 | `0xd6aeee42861780e2dbeb7d4a33580632f747f7caed87723564919bc266ae408b` |
| 37 | fillF | BUYER (1) | Seaport fulfillAdvancedOrder: BundleIssued #10 ProceedsCredited #10 | 60903931 | `0x93f06f3f378b0dddaa07bcf6cf4ea9613acf84e4fbe0dd2a2ec10caa49d2cafb` |
| 38 | buyerRedeemClean | BUYER (2) | escrow redeemToFreshAccount: BundleRedeemed #10 | 60903957 | `0xbd6e1c3b529bf2311e347ce9ea1056896cc445c28ee95ae9aedc310bf48557bc` |
| 39 | refuseOn | SELLER (32) | test token refusal toggle | 60903969 | `0xb13cc38772103f0ad66d19db375dbb073ee210380ca952a7f891cd87cb844572` |
| 40 | buyerRedeemPartial | BUYER (3) | escrow redeemToFreshAccount: BundleRedeemed #8 | 60903990 | `0x627bcddbde06696916a3410089d0240e076b2e38db036bc18544f3156075abf9` |
| 41 | sellerReclaimFull | SELLER (33) | escrow reclaim: BundleReclaimed #7 | 60904012 | `0x1d3a0505e7301c7758be1843243582dc3f6820dbe3f2ca157c3479c02075b6a3` |
| 42 | sellerReclaimPartial | SELLER (34) | escrow reclaim: BundleReclaimed #9 | 60904031 | `0xa4b457fd00ce0b22716193e9403a0a3552b650d3ba62ce35118518d9f4141c30` |
| 43 | sellerRedirect | SELLER (35) | escrow withdrawRemaining(9, 0) to the redirect | 60904046 | `0x638cacad6313408350f187c3a13658804d3a679c8c8b7c94c73561a1a5ab4f48` |
| 44 | refuseOff | SELLER (36) | test token refusal toggle | 60904082 | `0x0c098d2c24590cf3c4cdbe59875c814f747c98ca4bdd2fa142de9fc5a1f11cf9` |
| 45 | helperWithdraws | HELPER (0) | escrow withdrawRemaining(8, 1) | 60904101 | `0x1ccac34c99443cfd359623843c5aedea189abe46d7fbb15231964c62b9d3b4ea` |
| 46 | helperWithdraws | HELPER (1) | escrow withdrawRemaining(9, 1) | 60904110 | `0x686fcce86022f60b6c56a4b28d2349a0cc298127e120b5323d3d7188ddf661ea` |
| 47 | sellerWithdrawProceeds | SELLER (37) | escrow withdraw (seller proceeds):  | 60904126 | `0x5d3f0016b7d2c23a868ed61252674ea35c630eb5158e8ca5431fab2a105093ba` |
| 48 | sweep-SELLER | SELLER (38) | ETH transfer | 60904158 | `0xeabaf5aa7bf96146728cf53db7471623c4214103b0fd9bf6460c83d2b6ffefaf` |
| 49 | sweep-BUYER | BUYER (4) | ETH transfer | 60904171 | `0x84804f4cd2a738f8a607127d719087f412ed40f0e5af1113c9e834ea33ae25a6` |
| 50 | sweep-HELPER | HELPER (2) | ETH transfer | 60904184 | `0xb6a3c0359968c704d5058e2455a29ec7431330b268fe2bf566b80278441ae05e` |

Runner fees, summed from the receipts (gasUsed × effectiveGasPrice + l1Fee): **61,590,087,840,312 wei**. That equals the runner journal exactly.

Bundle collection admin (outside the runner journal):

| # | Step | Signer | Hash | Block | Fee (wei) |
|---|------|--------|------|------:|----------:|
| A1 | Bundle `transferOwnership(0xF8e0…b4EF)` | `0x9a70` | `0x861d127ffadbc09de54f69f94d5f5e14e4bdea95fb4f31451f7ed77418e52f8e` | 60898844 | 431,925,874,151 |
| A2 | Bundle `acceptOwnership()` (`OwnershipTransferred 0x9a70 → 0xF8e0`) | `0xF8e0` | `0xffcfd28cce290ea4ae70e639512f8cc6be7779d2d309b1e907c9248a9234f226` | 60899220 | 202,554,775,394 |
| A3 | Bundle `setImageBaseURI` (`ImageBaseURISet("" → ".../api/v2/bundle-art/")`) | `0xF8e0` | `0xd9b338292be9d6422f4eb156fd610119a2c1f5e7feef76da4070e99d006e7bd3` | 60899227 | 712,459,056,894 |

Timing (block timestamps):
- funding at 2026-11-22T16:04:06Z (block 60865356);
- A1 to A3 between 17:55:44Z and 17:57:01Z;
- last sweep at 18:13:32Z (block 60904184).

## Money

| Item | Wei |
|---|---:|
| Funded to test wallets | 7,000,000,000,000,000 |
| Swept back to the deployer | 6,938,791,716,333,565 |
| Seller proceeds withdrawn | 1,880,000 |
| Marketplace (2 fills × 1,000,000) | 2,000,000 |
| Runner transaction fees | 61,590,087,840,312 |
| Deployer balance delta (opening 9,461,588,473,505,408 → closing 9,399,083,371,712,808) | 62,505,101,792,600 |
| Unexplained in the runner summary = A2 + A3 deployer fees | 915,013,832,288 |
| **Unexplained after the admin transactions** | **0** |

A1 was paid by `0x9a70` (431,925,874,151 wei), not by the deployer.
- **Deployer nonces:** A2 = 298 and A3 = 299, consistent with an independent reconciliation (nonce 298 just after funding, 300 at the final sweep).
- **Test wallets now:** SELLER, BUYER and HELPER read **0 wei** on chain.

## Addresses

| Contract | Address |
|----------|---------|
| **Escrow (ERC1967 / UUPS proxy)** | `0xCc29F5c82C8b7c01Cac6036047E7413Df458f86d` |
| Bundle collection (owner now `0xF8e0…b4EF`) | `0x59900b207ea703b0bbcf8fd84c5e11de46826185` |
| Book | `0xf1d5faDB136aD21d9dcf58614993a6D2b1C6b5A4` |
| Seaport 1.6 | `0x0000000000000068F116a894984e2DB1123eB395` |

## Source and build

- **Runner package:** `7e19e66701992687c7391b6946ac56ba5780c2db`, launcher `f3a74a089491`. Runner and verifier changed as above under the typed re-bind.
- **Verifier fix:** `967d89f` (uint from JSON integer, decimal string or 0x-hex).
- **Contracts exercised:** as deployed by the F-01 partial-release upgrade (see that report). The seller also deployed the four fixtures below.

## Verification

- **Each of the 53 transactions above:** I re-read `eth_getTransactionReceipt` from public Base RPC. All have status 1, the recorded block equals the chain block, and the senders are as listed.
- **Fees:** recomputed from the receipts. They match the runner journal and an independent reconciliation.
- **Current state (read-only, 2026-11-23):**
  - Bundle `owner()` = `0xF8e0…b4EF`, `pendingOwner()` = `0x0`;
  - `imageBaseURI()` = `https://newtrade-app.vercel.app/api/v2/bundle-art/`;
  - all three test wallets 0 wei.
- **Runner's own checks:** OrderFulfilled for both orders (fulfillment_data verified offline, 36 checks each, and simulated); state post-checks at PHASE 1 (W reclaimed in full, F redeemed clean, R Redeeming and C Reclaiming with exactly token B held, C redirected) and PHASE 2 (all four bundles closed; token B went to the buyer's account and to the redirect, not to the helper).

## Rollback

The fixture deployments, completed fills, exits and sweeps are permanent. Only the owner and image settings have administrative reversal paths.
- **Ownership:** to move the Bundle collection back to another owner, `transferOwnership` + `acceptOwnership` (two-step).
- **Image base URI:** restore the prior empty value or another accepted URI with `setImageBaseURI` by the owner. The previous value was the empty string.

## Test contracts created during seller setup

| Contract | Address | Receipt block |
|---|---|---:|
| F01TestBook | `0xf1d5fadb136ad21d9dcf58614993a6d2b1c6b5a4` | 60865419 |
| RoyaltyTestNFT | `0xdb01af27aaa03a2559c343e29a921f4758295884` | 60865421 |
| F01TestToken | `0xe43ad1a460aa47819c17f003fbc60772387cf3c0` | 60865424 |
| F01TestToken | `0x2e9e80c591661ff57c1d399ad4c910eed2f2fe55` | 60865426 |

## Machine-readable

```json
{
  "chainId": 8453,
  "network": "base-mainnet",
  "date": "2026-11-22",
  "kind": "live-test+admin",
  "runnerPackage": "7e19e66701992687c7391b6946ac56ba5780c2db",
  "pinnedContractsCommit": "c575b727823e23a2dc83a53e7829ba5eb944f4e0",
  "binding": {
    "initial": "ca56d106aaec454cce44ea1fed7f89a69a13544ecd829c80d546063e582abddf",
    "reboundTo": "77653bc7942b"
  },
  "escrow": "0xCc29F5c82C8b7c01Cac6036047E7413Df458f86d",
  "bundleCollection": "0x59900b207ea703b0bbcf8fd84c5e11de46826185",
  "book": "0xf1d5faDB136aD21d9dcf58614993a6D2b1C6b5A4",
  "seaport": "0x0000000000000068F116a894984e2DB1123eB395",
  "bundles": {
    "W": 7,
    "R": 8,
    "C": 9,
    "F": 10
  },
  "orders": {
    "8": "0x112cc45a3e4824bc5153280051fda50b35b0d6b6580e94e4ef6922bf63fe34f7",
    "10": "0xaf6371f37d47a74ffa301fd0f7fecba93f44fd72872234d48643d8e059c1e38e"
  },
  "testWallets": {
    "seller": "0x57Ae6566f142646Ab5000c46186D5d6f2b0728bC",
    "buyer": "0xe8b0A080c5a897B2594FB939C7749b93c9017799",
    "helper": "0x1F23a8aDeba9F113816cBc547508ad2805331D34"
  },
  "testWalletsFinalWei": {
    "seller": "0",
    "buyer": "0",
    "helper": "0"
  },
  "runnerFeesWei": "61590087840312",
  "sellerProceedsWithdrawnWei": "1880000",
  "sweptBackWei": "6938791716333565",
  "deployerDeltaWei": "62505101792600",
  "bundleAdmin": {
    "transferOwnership": {
      "from": "0x9a704664009d615A90ddDf9345B6b8B2A214cFb2",
      "hash": "0x861d127ffadbc09de54f69f94d5f5e14e4bdea95fb4f31451f7ed77418e52f8e",
      "block": 60898844
    },
    "acceptOwnership": {
      "from": "0xF8e03bd4436371E0e2F7C02E529b2172fe72b4EF",
      "hash": "0xffcfd28cce290ea4ae70e639512f8cc6be7779d2d309b1e907c9248a9234f226",
      "block": 60899220,
      "feeWei": "202554775394"
    },
    "setImageBaseURI": {
      "from": "0xF8e03bd4436371E0e2F7C02E529b2172fe72b4EF",
      "hash": "0xd9b338292be9d6422f4eb156fd610119a2c1f5e7feef76da4070e99d006e7bd3",
      "block": 60899227,
      "feeWei": "712459056894",
      "previous": "",
      "new": "https://newtrade-app.vercel.app/api/v2/bundle-art/"
    }
  },
  "bundleOwnerAfter": "0xF8e03bd4436371E0e2F7C02E529b2172fe72b4EF",
  "transactions": [
    {
      "step": "fund-SELLER",
      "role": "FUNDER",
      "hash": "0x9283f4b407f65bc7c9358c8024beefd3fdedd1e739025088270deebffc2877d3",
      "block": 60865356,
      "sender": "0xf8e03bd4436371e0e2f7c02e529b2172fe72b4ef",
      "status": 1
    },
    {
      "step": "fund-BUYER",
      "role": "FUNDER",
      "hash": "0xce8baad2ab81cad52452cd443d183f36fdc198afdd63dfe9a6be9c463473671e",
      "block": 60865368,
      "sender": "0xf8e03bd4436371e0e2f7c02e529b2172fe72b4ef",
      "status": 1
    },
    {
      "step": "fund-HELPER",
      "role": "FUNDER",
      "hash": "0xb415b49ca9532b173a165f4181a3312e1bf684e24594f800ab8284e2a1f24aee",
      "block": 60865379,
      "sender": "0xf8e03bd4436371e0e2f7c02e529b2172fe72b4ef",
      "status": 1
    },
    {
      "step": "sellerDeposits",
      "role": "SELLER",
      "hash": "0x7e297b1d615b8ef4b61d4a65dad5e50470afffd9336cfb3727112de15f242111",
      "block": 60865419,
      "sender": "0x57ae6566f142646ab5000c46186d5d6f2b0728bc",
      "status": 1
    },
    {
      "step": "sellerDeposits",
      "role": "SELLER",
      "hash": "0xaeef74a7413d1c35793c8370310f65b7ce3b998000c161d1fa6bb55d5c9afdd5",
      "block": 60865421,
      "sender": "0x57ae6566f142646ab5000c46186d5d6f2b0728bc",
      "status": 1
    },
    {
      "step": "sellerDeposits",
      "role": "SELLER",
      "hash": "0x9dee0da602a715d494c3db13ae1b8c517073d5b0250a8f698de3bb37b9e5478f",
      "block": 60865424,
      "sender": "0x57ae6566f142646ab5000c46186d5d6f2b0728bc",
      "status": 1
    },
    {
      "step": "sellerDeposits",
      "role": "SELLER",
      "hash": "0x3dcd682fe2d2b221a0088e2199bd1610c337eb72c43612fb3bdbbddf9031eb38",
      "block": 60865426,
      "sender": "0x57ae6566f142646ab5000c46186d5d6f2b0728bc",
      "status": 1
    },
    {
      "step": "sellerDeposits",
      "role": "SELLER",
      "hash": "0x5e1d759467993dc94ebc0f637f9eb9225906ffccd729b49718ce0b1027cf1156",
      "block": 60865429,
      "sender": "0x57ae6566f142646ab5000c46186d5d6f2b0728bc",
      "status": 1
    },
    {
      "step": "sellerDeposits",
      "role": "SELLER",
      "hash": "0xe94f3dac49a3609fcab67bf0098a8506865fc6a36329613861ad7497b4ce0384",
      "block": 60865433,
      "sender": "0x57ae6566f142646ab5000c46186d5d6f2b0728bc",
      "status": 1
    },
    {
      "step": "sellerDeposits",
      "role": "SELLER",
      "hash": "0x648fb1e7ac5bae3441fe5a911037314cdd620bfef8ec547cb393d153c31d1786",
      "block": 60865435,
      "sender": "0x57ae6566f142646ab5000c46186d5d6f2b0728bc",
      "status": 1
    },
    {
      "step": "sellerDeposits",
      "role": "SELLER",
      "hash": "0xe3bea2e40f5dc1a415d2ffe5f142bf5c479760b0341a086563e240da41c4e730",
      "block": 60865437,
      "sender": "0x57ae6566f142646ab5000c46186d5d6f2b0728bc",
      "status": 1
    },
    {
      "step": "sellerDeposits",
      "role": "SELLER",
      "hash": "0x4312e1b8be76566a448141aac0ab9ba8b6c631ec01a2e3ef9fdd9a5a40875162",
      "block": 60865439,
      "sender": "0x57ae6566f142646ab5000c46186d5d6f2b0728bc",
      "status": 1
    },
    {
      "step": "sellerDeposits",
      "role": "SELLER",
      "hash": "0xfbe44174660dbc415188980a5ce36b2085f98883d1918a94fd39a76ca79f14fa",
      "block": 60865441,
      "sender": "0x57ae6566f142646ab5000c46186d5d6f2b0728bc",
      "status": 1
    },
    {
      "step": "sellerDeposits",
      "role": "SELLER",
      "hash": "0x7df85799ff266c88cccc833406ecfa30d6a14b9ee69c25bf1c4e250fb916e387",
      "block": 60865443,
      "sender": "0x57ae6566f142646ab5000c46186d5d6f2b0728bc",
      "status": 1
    },
    {
      "step": "sellerDeposits",
      "role": "SELLER",
      "hash": "0xfe9bdeeca3b2b911d9fefd81bece6573883db49f4e6184c5503ea5b50b998d56",
      "block": 60865445,
      "sender": "0x57ae6566f142646ab5000c46186d5d6f2b0728bc",
      "status": 1
    },
    {
      "step": "sellerDeposits",
      "role": "SELLER",
      "hash": "0x8f14445d311d590b4948ba3da276d058e5a46cc1637e7699f90a713b0186edd2",
      "block": 60865447,
      "sender": "0x57ae6566f142646ab5000c46186d5d6f2b0728bc",
      "status": 1
    },
    {
      "step": "sellerDeposits",
      "role": "SELLER",
      "hash": "0x0f9f6413c4ff0d1db9f4ad3b4d5e16b9f4763344b911c9adc62ce39617a013c5",
      "block": 60865449,
      "sender": "0x57ae6566f142646ab5000c46186d5d6f2b0728bc",
      "status": 1
    },
    {
      "step": "sellerDeposits",
      "role": "SELLER",
      "hash": "0x67bd27160f9d0d8137129d55deb588e3973c03f2ce540d6543d9163e1e25a5a6",
      "block": 60865451,
      "sender": "0x57ae6566f142646ab5000c46186d5d6f2b0728bc",
      "status": 1
    },
    {
      "step": "sellerDeposits",
      "role": "SELLER",
      "hash": "0x3d6670836621a8cd9c5b0ca3b228339d99916b28772f50296c219a9df3b351a6",
      "block": 60865453,
      "sender": "0x57ae6566f142646ab5000c46186d5d6f2b0728bc",
      "status": 1
    },
    {
      "step": "sellerDeposits",
      "role": "SELLER",
      "hash": "0x0f193e3c63b8d61199d741d2e525208de29c70b167810eaec26342d2d3d5a332",
      "block": 60865455,
      "sender": "0x57ae6566f142646ab5000c46186d5d6f2b0728bc",
      "status": 1
    },
    {
      "step": "sellerDeposits",
      "role": "SELLER",
      "hash": "0xf464561787fd9d0fc7efe5be5e4596e65a34230b867d950cbe677cfb135949f6",
      "block": 60865457,
      "sender": "0x57ae6566f142646ab5000c46186d5d6f2b0728bc",
      "status": 1
    },
    {
      "step": "sellerDeposits",
      "role": "SELLER",
      "hash": "0x3870f6d34e3c8054858c8e3ec9630e09f0299c0db29ceb7d67c9f06c849bf542",
      "block": 60865459,
      "sender": "0x57ae6566f142646ab5000c46186d5d6f2b0728bc",
      "status": 1
    },
    {
      "step": "sellerDeposits",
      "role": "SELLER",
      "hash": "0xf18fc88a1344fe05fc0532677d98eb69e9561a4e72ae3afc6996e5a62862857a",
      "block": 60865461,
      "sender": "0x57ae6566f142646ab5000c46186d5d6f2b0728bc",
      "status": 1
    },
    {
      "step": "sellerDeposits",
      "role": "SELLER",
      "hash": "0x1d4e519e6560fdc525adb8be05f33df633937bb032f501b2238ed6b8edb2ced3",
      "block": 60865463,
      "sender": "0x57ae6566f142646ab5000c46186d5d6f2b0728bc",
      "status": 1
    },
    {
      "step": "sellerDeposits",
      "role": "SELLER",
      "hash": "0x7955bb71d371100a63a3c4260297cfac4b794b29fccf6365a3c0f6f70c596b09",
      "block": 60865465,
      "sender": "0x57ae6566f142646ab5000c46186d5d6f2b0728bc",
      "status": 1
    },
    {
      "step": "sellerDeposits",
      "role": "SELLER",
      "hash": "0x6195ca44ced7caf26d97cc456fb3307a5a6dd64a6805eb92bfefd71ad5964734",
      "block": 60865467,
      "sender": "0x57ae6566f142646ab5000c46186d5d6f2b0728bc",
      "status": 1
    },
    {
      "step": "sellerDeposits",
      "role": "SELLER",
      "hash": "0xcda5cce1877000fca1227c05ead891806be79b279008ea2ee8948f534ca6a348",
      "block": 60865469,
      "sender": "0x57ae6566f142646ab5000c46186d5d6f2b0728bc",
      "status": 1
    },
    {
      "step": "sellerDeposits",
      "role": "SELLER",
      "hash": "0xac723261f5132b1e096c95432aa5096a90103856971d978e7efb192d9a2b2d8a",
      "block": 60865471,
      "sender": "0x57ae6566f142646ab5000c46186d5d6f2b0728bc",
      "status": 1
    },
    {
      "step": "sellerDeposits",
      "role": "SELLER",
      "hash": "0x91ea0955a32b0df92e6a35495fc2897bfb7645faa9f0dc193f3227d307d340fa",
      "block": 60865473,
      "sender": "0x57ae6566f142646ab5000c46186d5d6f2b0728bc",
      "status": 1
    },
    {
      "step": "sellerDeposits",
      "role": "SELLER",
      "hash": "0x26bb417de2f616f5b75bde593cddd6ef2f7934b9d11fd44bdd25425da8fb2414",
      "block": 60865475,
      "sender": "0x57ae6566f142646ab5000c46186d5d6f2b0728bc",
      "status": 1
    },
    {
      "step": "sellerDeposits",
      "role": "SELLER",
      "hash": "0xbe21a046a526931be1238e74a1425c5d5ed5a0a7f4fd1c65379c04f1382d96f5",
      "block": 60865477,
      "sender": "0x57ae6566f142646ab5000c46186d5d6f2b0728bc",
      "status": 1
    },
    {
      "step": "sellerDeposits",
      "role": "SELLER",
      "hash": "0xf4a182ae28ce754eb55142be64b563a6f958143bce8e181e01123948a048046b",
      "block": 60865479,
      "sender": "0x57ae6566f142646ab5000c46186d5d6f2b0728bc",
      "status": 1
    },
    {
      "step": "sellerDeposits",
      "role": "SELLER",
      "hash": "0x89f6917cef8415062e8e406a6d2980278bc3e5f4fb6fbf5ff9fde7ad01e49b73",
      "block": 60865481,
      "sender": "0x57ae6566f142646ab5000c46186d5d6f2b0728bc",
      "status": 1
    },
    {
      "step": "sellerList",
      "role": "SELLER",
      "hash": "0xe4dc5731df50f8fc4f39e9d5fc91dcb63bd10abfbe609215f93fbc6c7f2b24bd",
      "block": 60865584,
      "sender": "0x57ae6566f142646ab5000c46186d5d6f2b0728bc",
      "status": 1
    },
    {
      "step": "sellerList",
      "role": "SELLER",
      "hash": "0xe0d5bc8e387b61505eb75b6018f34106ca1e1b10d1568a1190dfdbe6f50d1db7",
      "block": 60865586,
      "sender": "0x57ae6566f142646ab5000c46186d5d6f2b0728bc",
      "status": 1
    },
    {
      "step": "fillR",
      "role": "BUYER",
      "hash": "0xd6aeee42861780e2dbeb7d4a33580632f747f7caed87723564919bc266ae408b",
      "block": 60903914,
      "sender": "0xe8b0a080c5a897b2594fb939c7749b93c9017799",
      "status": 1
    },
    {
      "step": "fillF",
      "role": "BUYER",
      "hash": "0x93f06f3f378b0dddaa07bcf6cf4ea9613acf84e4fbe0dd2a2ec10caa49d2cafb",
      "block": 60903931,
      "sender": "0xe8b0a080c5a897b2594fb939c7749b93c9017799",
      "status": 1
    },
    {
      "step": "buyerRedeemClean",
      "role": "BUYER",
      "hash": "0xbd6e1c3b529bf2311e347ce9ea1056896cc445c28ee95ae9aedc310bf48557bc",
      "block": 60903957,
      "sender": "0xe8b0a080c5a897b2594fb939c7749b93c9017799",
      "status": 1
    },
    {
      "step": "refuseOn",
      "role": "SELLER",
      "hash": "0xb13cc38772103f0ad66d19db375dbb073ee210380ca952a7f891cd87cb844572",
      "block": 60903969,
      "sender": "0x57ae6566f142646ab5000c46186d5d6f2b0728bc",
      "status": 1
    },
    {
      "step": "buyerRedeemPartial",
      "role": "BUYER",
      "hash": "0x627bcddbde06696916a3410089d0240e076b2e38db036bc18544f3156075abf9",
      "block": 60903990,
      "sender": "0xe8b0a080c5a897b2594fb939c7749b93c9017799",
      "status": 1
    },
    {
      "step": "sellerReclaimFull",
      "role": "SELLER",
      "hash": "0x1d3a0505e7301c7758be1843243582dc3f6820dbe3f2ca157c3479c02075b6a3",
      "block": 60904012,
      "sender": "0x57ae6566f142646ab5000c46186d5d6f2b0728bc",
      "status": 1
    },
    {
      "step": "sellerReclaimPartial",
      "role": "SELLER",
      "hash": "0xa4b457fd00ce0b22716193e9403a0a3552b650d3ba62ce35118518d9f4141c30",
      "block": 60904031,
      "sender": "0x57ae6566f142646ab5000c46186d5d6f2b0728bc",
      "status": 1
    },
    {
      "step": "sellerRedirect",
      "role": "SELLER",
      "hash": "0x638cacad6313408350f187c3a13658804d3a679c8c8b7c94c73561a1a5ab4f48",
      "block": 60904046,
      "sender": "0x57ae6566f142646ab5000c46186d5d6f2b0728bc",
      "status": 1
    },
    {
      "step": "refuseOff",
      "role": "SELLER",
      "hash": "0x0c098d2c24590cf3c4cdbe59875c814f747c98ca4bdd2fa142de9fc5a1f11cf9",
      "block": 60904082,
      "sender": "0x57ae6566f142646ab5000c46186d5d6f2b0728bc",
      "status": 1
    },
    {
      "step": "helperWithdraws",
      "role": "HELPER",
      "hash": "0x1ccac34c99443cfd359623843c5aedea189abe46d7fbb15231964c62b9d3b4ea",
      "block": 60904101,
      "sender": "0x1f23a8adeba9f113816cbc547508ad2805331d34",
      "status": 1
    },
    {
      "step": "helperWithdraws",
      "role": "HELPER",
      "hash": "0x686fcce86022f60b6c56a4b28d2349a0cc298127e120b5323d3d7188ddf661ea",
      "block": 60904110,
      "sender": "0x1f23a8adeba9f113816cbc547508ad2805331d34",
      "status": 1
    },
    {
      "step": "sellerWithdrawProceeds",
      "role": "SELLER",
      "hash": "0x5d3f0016b7d2c23a868ed61252674ea35c630eb5158e8ca5431fab2a105093ba",
      "block": 60904126,
      "sender": "0x57ae6566f142646ab5000c46186d5d6f2b0728bc",
      "status": 1
    },
    {
      "step": "sweep-SELLER",
      "role": "SELLER",
      "hash": "0xeabaf5aa7bf96146728cf53db7471623c4214103b0fd9bf6460c83d2b6ffefaf",
      "block": 60904158,
      "sender": "0x57ae6566f142646ab5000c46186d5d6f2b0728bc",
      "status": 1
    },
    {
      "step": "sweep-BUYER",
      "role": "BUYER",
      "hash": "0x84804f4cd2a738f8a607127d719087f412ed40f0e5af1113c9e834ea33ae25a6",
      "block": 60904171,
      "sender": "0xe8b0a080c5a897b2594fb939c7749b93c9017799",
      "status": 1
    },
    {
      "step": "sweep-HELPER",
      "role": "HELPER",
      "hash": "0xb6a3c0359968c704d5058e2455a29ec7431330b268fe2bf566b80278441ae05e",
      "block": 60904184,
      "sender": "0x1f23a8adeba9f113816cbc547508ad2805331d34",
      "status": 1
    }
  ],
  "testContracts": [
    {
      "name": "F01TestBook",
      "address": "0xf1d5fadb136ad21d9dcf58614993a6d2b1c6b5a4",
      "hash": "0x7e297b1d615b8ef4b61d4a65dad5e50470afffd9336cfb3727112de15f242111",
      "block": 60865419
    },
    {
      "name": "RoyaltyTestNFT",
      "address": "0xdb01af27aaa03a2559c343e29a921f4758295884",
      "hash": "0xaeef74a7413d1c35793c8370310f65b7ce3b998000c161d1fa6bb55d5c9afdd5",
      "block": 60865421
    },
    {
      "name": "F01TestToken",
      "address": "0xe43ad1a460aa47819c17f003fbc60772387cf3c0",
      "hash": "0x9dee0da602a715d494c3db13ae1b8c517073d5b0250a8f698de3bb37b9e5478f",
      "block": 60865424
    },
    {
      "name": "F01TestToken",
      "address": "0x2e9e80c591661ff57c1d399ad4c910eed2f2fe55",
      "hash": "0x3dcd682fe2d2b221a0088e2199bd1610c337eb72c43612fb3bdbbddf9031eb38",
      "block": 60865426
    }
  ]
}
```
