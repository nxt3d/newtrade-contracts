# Changelog

Changes to the V2 contracts and their consumer handoff. Newest first. Storage, ABI and
event changes are called out explicitly because consumers pin them.

## Initial public release

This repository contains the live V2 system only. Compared with the entries below:
- `abi/` ships `NewTradeEscrowV2`, `NewTradeV2VaultV2`, `NewTradeBundle`, `SeaportV16.min` and
  `IERC6551ExecutableAccount` ABIs, hashed in `abi/artifact-manifest.sha256`. ABIs for the
  previous vault and the retired royalty receiver are no longer shipped.
- The migration fixture lives only in `test/fixtures/migration/all-logs-fixture.json`.
- The previous `NewTradeV2Vault`, the one-shot seeder and the retired royalty receiver are
  test-only contracts under `test/legacy/`.
- The renderer configured on chain (`0x4519D5429391aA6bBcBB33ad248470d5e45856c5`) and its
  graphics library are not part of this repository; the live image comes from `imageBaseURI`.

## 2026-09-18 — reclaim destination

Deployed to the live escrow; see `deployments/base-mainnet-2026-09-18-reclaim-destination.md`.
Later changes (fee from proceeds, option B, F-01 partial release) are described in their deployment records.

### Changed (ABI-breaking)
- `NewTradeEscrowV2.reclaim(uint256 bundleId)` is now
  `reclaim(uint256 bundleId, address extrasTo)`. The seller chooses where the manifest
  assets return; the controlling NFT always returns to the recorded seller.
  `extrasTo == address(0)` reverts `ZeroAddress` (checked first, so a missing destination is
  never reported as missing authority). `extrasTo` is otherwise unvalidated:
  the assets are the seller's own. Authorization is unchanged (recorded seller only, at or
  after `custodyDeadline`, never issued, state `Deposited` or `Listed`).
  - Why: a bundle deposited with `depositFromAccount` has its manifest assets pulled out
    of an ERC-6551 account; the previous `reclaim` could only send them to the seller's
    wallet and left that account empty. The seller now passes the original account (the
    `sourceAccount` of `BundleMigrated`) to put them back, or their own wallet to keep the
    old behaviour.
  - Not to be confused with `withdraw(address token)`, which pays out sale proceeds.
- `event BundleReclaimed(uint256 indexed bundleId, address indexed seller, uint64 reclaimedAt)`
  is now `BundleReclaimed(uint256 indexed bundleId, address indexed seller, address indexed extrasTo, uint64 reclaimedAt)`.
  The topic hash changes; log consumers must update their event signature.

### Removed (ABI-breaking)
- Public constants `CONDUIT_KEY` and `NEW_LISTING_START_TIME` (and their getters). Both were
  dead: nothing in the contracts, scripts or the app read them. Removed to recover EIP-170
  headroom. `OPENSEA_CONDUIT_KEY` and `OPENSEA_CONDUIT` are unchanged.

### Fixed
- Parameter inversion in the escrow's private `_burnAndRelease`: it was declared
  `(nftTo, extrasTo)` and forwarded positionally into
  `NewTradeV2Vault.release(bundleId, nft, nftId, extrasTo, nftTo)`, while redemption passed
  `(account, msg.sender)` — two swaps cancelling out. It is now `(extrasTo, nftTo)`,
  mirroring the vault, and every call uses named arguments. No behaviour change:
  redemption still sends the manifest assets to the fresh account and the controlling NFT
  to the holder.

### Unchanged
- Storage layout: identical (no new state, `Bundle` struct untouched, `getBundle` ABI
  unchanged). `NewTradeV2Vault`, `NewTradeBundle` and `NewTradeRoyaltyReceiver` are untouched.
- `redeemToFreshAccount` behaviour.

### Size
- `NewTradeEscrowV2` runtime 24,026 bytes, EIP-170 margin 550 (was 24,031 / 545; the
  `test/DeploySize.t.sol` gate requires 500).

### Tooling and handoff
- `tooling/export-abis.sh` failed because it inspected a claim-collection contract name that
  no longer existed; it now exports `NewTradeBundle.abi.json`. (The ABI set it exports today is
  listed under "Initial public release" above.)
- `tooling/export-migration-handoff.sh` keeps only the JSON document from `forge test --json`
  (forge can print a dependency notice first, e.g. in a fresh git worktree) and falls back to
  `shasum -a 256` where `sha256sum` is absent.
- `abi/` and `test/fixtures/migration/all-logs-fixture.json` regenerated. The handoff had
  not been re-exported since `a319ab2` (2026-09-15), so besides the escrow ABI this refresh
  also picks up pre-existing drift: `SeaportV16.min.abi.json` gains `information()`, and the
  migration fixture changed (sha256 `76459ba8…` -> `0f850749…`). Neither is caused by the
  reclaim change. Verified: running the (fixed) exporter on UNMODIFIED `main` (`76d632c`)
  produces the identical `0f850749…` fixture, i.e. the committed fixture was already stale on
  main. The fixture records a test deployment's emitted logs; the escrow, vault and source
  account addresses in it are derived from the test contract's CREATE nonce, which moved when
  the test setup gained deployments after 2026-09-15. The fixture contains no reclaim
  selector, no `Bundle` tuple and no removed constant, and its `expectedLogOrder` is unchanged.
  Consumers that keep a byte-for-byte copy of the old fixture are unaffected until they
  choose to re-copy it.
