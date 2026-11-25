# Bundle zero-royalty upgrade on Base mainnet

The owner approved the Bundle upgrade on November 23, 2026 (US Eastern). Base recorded it on **November 24 at 00:12:31 UTC**, block **61,443,878**. The proxy now quotes zero marketplace royalties on existing claims. The escrow still snapshots the controlling NFT’s creator royalty at listing and credits the recipient once at first exit.

OpenSea had twice required a 5% creator payment to the deployer, including when it rejected bundle #12. The previous Bundle implementation exposed that same 5% through ERC-2981 and the Royalty Registry resolved the collection to the Bundle. Removing that on-chain quote addresses one source of the fee. OpenSea controls its own collection settings and its resync timing is unknown.

## Transactions

All four receipts succeeded on Base (8453). The block links open the corresponding receipts. Times below are UTC on November 24.

| Step | Signer prefix | Nonce | Block and receipt | UTC | Gas used |
|---|---|---:|---:|---|---:|
| Start ownership transfer | 0x9a70 | 252 | [61,443,268](https://basescan.org/tx/0x24e143b07c109ea3a64b2f6457defcdcd686483ade6ee740cc9b5f2c8ca76c35) | 00:10:29 | 53,281 |
| Accept ownership | 0xf8e0 | 307 | [61,443,380](https://basescan.org/tx/0xf20f8a037738881cd5a3b8636fc8ba602e9a4168d05c31ad95c189f634e876c6) | 00:10:51 | 33,557 |
| CREATE implementation | 0xf8e0 | 308 | [61,443,728](https://basescan.org/tx/0x13d99f402b980d8116b71d9878e7d6c89211aafde0844b84d21ba220315b1209) | 00:12:01 | 3,847,173 |
| Upgrade Bundle proxy | 0xf8e0 | 309 | [61,443,878](https://basescan.org/tx/0xfd26d68eee7ccf95a5940c1f5a782aef9610798ba92d7cb4ff3b1def6c66b294) | 00:12:31 | 37,764 |

The owner initiated the ownership transfer from `0x9a704664009d615a90dddf9345b6b8b2a214cfb2`. The new owner, `0xf8e03bd4436371e0e2f7c02e529b2172fe72b4ef`, accepted at nonce 307, created the implementation at nonce 308 and upgraded the proxy at nonce 309 with empty initialization data.

| Contract | Address |
|---|---|
| Bundle proxy | `0x59900b207ea703b0bbcf8fd84c5e11de46826185` |
| New implementation | `0x79a67904af737376a51b8e3874d960418c890a97` |
| Previous implementation | `0x9182dc376e13d4d26612cda495c41906592d8ab3` |
| Escrow proxy | `0xCc29F5c82C8b7c01Cac6036047E7413Df458f86d` |

## Build and rehearsal

Source commit `e4b0b522f888de602119709178b4729718814435` changes the Bundle’s royalty quote and retains its token existence check. Independent review approved the code and the final operator package. The pre-release project build used solc 0.8.28, via IR, optimizer runs 1, Cancun and recursive submodules. An independent reviewer reproduced the 17,654-byte initcode with `forge build --skip test --skip script`. The operator independently rebuilt it before CREATE.

The independent reviewer’s pre-release comparison matched the storage layout and external selectors. Seven release-specific fork tests passed with the packaged initcode at each of Base blocks 61,403,135 and 61,409,823, including the rollback. Fork fills of #11 and #12 credited their existing snapshots of 50,000 and 5,000,000 wei to the creator once each. Those fills were simulations. Of IDs 1–12, only #3, #11 and #12 had live claims in rehearsal. The other nine had been burned by redemption or reclaim.

## Live verification

An independent reviewer read the four transactions and receipts, the implementation bytecode, and proxy state immediately before and at the upgrade block.

- The CREATE input matched the pinned raw-byte SHA-256 `a6e119f6d1eeb732e4577d2180cf58e831c7bec56919535710dc788312ad3eff`. Both runtime self-address words at byte offsets 6765 and 6913 contain the deployed address. Zeroing those words gives the pinned SHA-256 `9c4ee8ad70381dae8c20815d36c64d05a9850591ee70882713c7eb5673940f82` over 17,423 bytes.
- The ERC-1967 implementation slot changed from the previous implementation to the new one. The new implementation’s `proxiableUUID()` matched that slot, its direct owner was zero, and the proxy owner was `0xf8e03bd4436371e0e2f7c02e529b2172fe72b4ef`.
- At a sale price of 100,000,000 wei, claims #3, #11 and #12 returned a zero recipient and amount. Claim #1 reverted with the nonexistent-token error. The Bundle advertised ERC-2981, and the encoded token URI for each of the three live claims matched the preceding block.
- The operator reported HTTP 200 for OpenSea refreshes of #3, #11 and #12, and zero failures in production strict smoke. An independent reviewer read the production app’s OpenSea listing endpoint after the upgrade and found both #11 and #12 active.

## OpenSea fee watch

The operator observed only the 1% marketplace fee immediately after ownership acceptance and again after the upgrade. At **2026-11-24T00:16:18.336Z**, an independent reviewer’s direct collection API read returned a single required fee of **1%** to `0x0000a26b00c1f0df003000390027140000faa719`. The five-minute sampling window runs through November 25 at 00:16 UTC. A 5% recurrence triggers immediate manager notification and a report update. [OpenSea collection API](https://api.opensea.io/api/v2/collections/newtrade-bundle-v2)

The next two collection reads, at 00:21:18.742 and 00:26:18.994 UTC on November 24, both returned HTTP 401. The fee schedule is unknown at those two times.

## Rollback

The rollback restores the prior pass-through royalty quote. The owner verifies the current proxy owner and implementation slot before authorizing it. On Base, the owner calls `upgradeToAndCall(0x9182dc376e13d4d26612cda495c41906592d8ab3, 0x)` on the Bundle proxy with zero value. The exact unsigned call appears in the JSON below. An independent reviewer simulated it from the new owner at block 61,443,878 and received `0x`. After rollback, verify the slot, the restored quote for an existing claim, token metadata and collection fees. The ownership transfer is separate from the implementation rollback.

## Source on main (item 79, recorded November 24)

`main` now holds the live sources: merge `242c0aa` brings in the F-01 escrow and vault (`5b6fb0f`, last source change `cfabc76`) and this Bundle (`e4b0b52`). The deployed Bundle `0x79a6…8a97` was compiled from **`e4b0b52` against the pre-F-01 `NewTradeV2Types.sol`**, where `BundleState` has six values (`None` … `Reclaimed`). On `main` the same `NewTradeBundle.sol` (byte-identical to `e4b0b52`) compiles against the F-01 types, which append `Redeeming` and `Reclaiming` (eight values). A release build of the Bundle from `main` therefore differs from the live runtime at exactly one executable byte, the ABI decoder's range check on the `state` field of the `Bundle` struct that `tokenURI` reads from `escrow.getBundle(tokenId)`, plus the trailing CBOR metadata hash.

Release-linked comparison, read-only `eth_getCode` at Base block 61,752,674, UUPS self-address immutables zeroed in the live code:

| Runtime | Built from | Runtime bytes | Executable bytes that differ | Metadata bytes that differ | Masked SHA-256 (built) |
|---|---|---:|---:|---:|---|
| VaultAdmission `0xcbb5…4a46` | `main`, linked | 2,396 | 0 | 0 | `a99d8bf4…7fd21` (exact) |
| VaultCustodyIn `0x150e…0b64` | `main`, linked | 5,283 | 0 | 0 | `6951f684…76c10` (exact) |
| NewTradeV2VaultV2 implementation `0xb88a…f34d` | `main`, linked | 18,346 | 0 | 0 | `27ba9a17…37e7e5b` (exact) |
| NewTradeEscrowV2 implementation `0xc5d9…8071` | `main`, linked | 24,331 | 0 | 32 | `910fbba5…6db` (live `7007f6e0…ca7`) |
| Bundle `0x79a6…8a97` | `main` | 17,423 | 1 | 32 | `ea1f0062…587a` (live `9c4ee8ad…0f82`) |
| Bundle `0x79a6…8a97` | `e4b0b52` | 17,423 | 0 | 0 | `9c4ee8ad…0f82` (exact) |

Build flags: solc 0.8.28, via IR, optimizer runs 1, Cancun (`foundry.toml`), recursive submodules.
- Bundle: `forge build --skip test --skip script`.
- F-01 contracts: the same, plus the release link flags `--libraries src/libraries/VaultAdmission.sol:VaultAdmission:0xcbb51e4cc6166bfa58b3e23aec9bea0acce94a46 --libraries src/libraries/VaultCustodyIn.sol:VaultCustodyIn:0x150eaeffa8134d731b364f67f040cf1661210b64`. The `libraries` setting is part of each contract's metadata, so linking after compilation instead reproduces the executable bytes but not the metadata.

The escrow's 32 metadata bytes differ because the escrow imports `NewTradeBundle.sol`, and its metadata hash covers that file, which the zero-royalty change edited after `5b6fb0f`. `NewTradeEscrowV2.sol` itself is unchanged and its executable bytes are identical.

The one executable Bundle byte is offset 4,631: `PUSH1 0x06` live, `PUSH1 0x08` from `main`, in the sequence `PUSH1 n DUP2 LT ISZERO PUSH2 0x0758 JUMPI`. The live Bundle rejects a decoded state of 6 or more; `main`'s rejects 8 or more. The bound cannot be reached through a live token:
- `tokenURI` calls `_requireOwned(tokenId)` before decoding, and `royaltyInfo` does not read the escrow.
- `redeem` and `reclaim` write `b.state = Redeeming` / `Reclaiming` and then call `_burnAndRelease`, whose first action is `_receipt.controllerBurn(bundleId)`. The write, the burn and the release are one transaction, so a claim whose bundle is in state 6 or 7 no longer exists, and `tokenURI` reverts with the nonexistent-token error before the decoder runs.

Rebuilding the Bundle from `main` is therefore not a byte-for-byte reproduction of `0x79a6…8a97`; reproduce the live Bundle from `e4b0b52`. A future Bundle upgrade built from `main` would carry the eight-value bound, which also accepts the F-01 states.

Three historical fork suites compared their pinned worlds with "this repo's" Bundle build. They passed at `0f34fbd` and began failing at `e4b0b52`, because this source quotes zero royalty and is no longer `0x9182`'s build.
- `BundleCardUpgradeFork` and `BundleImageModularUpgradeFork` (pinned at 51,785,106) now expect exactly the royalty difference and identity for everything else.
- `BundleNonTransferableLiveFork` is now pinned to 51,863,600 and skips at any other block. It keeps the positive check of `0x9182`'s masked SHA-256 from the deployment record.

## Machine-readable record

```json
{
  "chainId": 8453,
  "status": "deployed",
  "sourceCommit": "e4b0b522f888de602119709178b4729718814435",
  "baseCommit": "0f34fbd7e856f035e64266b42bc3f61f040ef937",
  "proxy": "0x59900b207ea703b0bbcf8fd84c5e11de46826185",
  "implementation": "0x79a67904af737376a51b8e3874d960418c890a97",
  "previousImplementation": "0x9182dc376e13d4d26612cda495c41906592d8ab3",
  "owner": "0xf8e03bd4436371e0e2f7c02e529b2172fe72b4ef",
  "storageLayoutChanged": false,
  "runtimeBytes": 17423,
  "runtimeSha256Masked": "9c4ee8ad70381dae8c20815d36c64d05a9850591ee70882713c7eb5673940f82",
  "transactions": {
    "transferOwnership": {
      "hash": "0x24e143b07c109ea3a64b2f6457defcdcd686483ade6ee740cc9b5f2c8ca76c35",
      "from": "0x9a704664009d615a90dddf9345b6b8b2a214cfb2",
      "to": "0x59900b207ea703b0bbcf8fd84c5e11de46826185",
      "created": null,
      "block": 61443268,
      "utc": "2026-11-24T00:10:29.000Z",
      "gas": 53281,
      "nonce": 252,
      "data": "0xf2fde38b000000000000000000000000f8e03bd4436371e0e2f7c02e529b2172fe72b4ef"
    },
    "acceptOwnership": {
      "hash": "0xf20f8a037738881cd5a3b8636fc8ba602e9a4168d05c31ad95c189f634e876c6",
      "from": "0xf8e03bd4436371e0e2f7c02e529b2172fe72b4ef",
      "to": "0x59900b207ea703b0bbcf8fd84c5e11de46826185",
      "created": null,
      "block": 61443380,
      "utc": "2026-11-24T00:10:51.000Z",
      "gas": 33557,
      "nonce": 307,
      "data": "0x79ba5097"
    },
    "create": {
      "hash": "0x13d99f402b980d8116b71d9878e7d6c89211aafde0844b84d21ba220315b1209",
      "from": "0xf8e03bd4436371e0e2f7c02e529b2172fe72b4ef",
      "to": null,
      "created": "0x79a67904af737376a51b8e3874d960418c890a97",
      "block": 61443728,
      "utc": "2026-11-24T00:12:01.000Z",
      "gas": 3847173,
      "nonce": 308,
      "initcodeSha256": "a6e119f6d1eeb732e4577d2180cf58e831c7bec56919535710dc788312ad3eff"
    },
    "upgradeToAndCall": {
      "hash": "0xfd26d68eee7ccf95a5940c1f5a782aef9610798ba92d7cb4ff3b1def6c66b294",
      "from": "0xf8e03bd4436371e0e2f7c02e529b2172fe72b4ef",
      "to": "0x59900b207ea703b0bbcf8fd84c5e11de46826185",
      "created": null,
      "block": 61443878,
      "utc": "2026-11-24T00:12:31.000Z",
      "gas": 37764,
      "nonce": 309,
      "data": "0x4f1ef28600000000000000000000000079a67904af737376a51b8e3874d960418c890a9700000000000000000000000000000000000000000000000000000000000000400000000000000000000000000000000000000000000000000000000000000000"
    }
  },
  "rollback": {
    "from": "0xf8e03bd4436371e0e2f7c02e529b2172fe72b4ef",
    "to": "0x59900b207ea703b0bbcf8fd84c5e11de46826185",
    "value": "0",
    "data": "0x4f1ef2860000000000000000000000009182dc376e13d4d26612cda495c41906592d8ab300000000000000000000000000000000000000000000000000000000000000400000000000000000000000000000000000000000000000000000000000000000"
  },
  "openSeaObservation": {
    "at": "2026-11-24T00:16:18.336Z",
    "fees": [
      {
        "fee": 1,
        "recipient": "0x0000a26b00c1f0df003000390027140000faa719",
        "required": true
      }
    ]
  },
  "openSeaUnreadableSamples": [
    {
      "at": "2026-11-24T00:21:18.742Z",
      "error": "HTTP 401"
    },
    {
      "at": "2026-11-24T00:26:18.994Z",
      "error": "HTTP 401"
    }
  ]
}
```
