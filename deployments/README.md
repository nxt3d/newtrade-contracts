# NewTrade V2 deployment records (Base mainnet)

These records cover the contracts of the live V2 system: the escrow proxy, the Bundle
claim collection, the upgradeable vault and its libraries, and every upgrade and
administrative change made to them. Each record gives the change and its purpose, the
source revision, addresses, transaction hashes and canonical blocks, release checks,
the recovery procedure and machine-readable JSON. Source revisions refer to pre-release
development history, which is not part of this repository.

Earlier deployments that are not part of the live system (the V1 escrow, the first V2
beta stack, test collections and individual bundle listings) are not included.

| Date | Record |
|---|---|
| 2026-09-17 | [Escrow proxy, Bundle collection, vault and royalty receiver (the live V2 proxies)](base-mainnet-2026-09-17-fresh-bundle-stack.md) |
| 2026-09-18 | [Escrow reclaim destination](base-mainnet-2026-09-18-reclaim-destination.md) |
| 2026-09-20–26 | [Escrow administration (protocol fee, surplus) and beta token setup](base-mainnet-2026-09-20-26-beta-setup-and-escrow-admin.md) |
| 2026-09-25 | [Bundle upgrade: on-chain image](base-mainnet-2026-09-25-bundle-image-upgrade.md) |
| 2026-09-25 | [Bundle upgrade: modular image (renderer, image and external base URIs)](base-mainnet-2026-09-25-bundle-image-modular-upgrade.md) |
| 2026-09-26 | [Escrow upgrade: protocol fee from proceeds](base-mainnet-2026-09-26-escrow-fee-from-proceeds-upgrade.md) |
| 2026-09-27 | [Bundle upgrade: claims non-transferable after the first sale](base-mainnet-2026-09-27-bundle-non-transferable-upgrade.md) |
| 2026-09-27 | [Escrow upgrade: option B (creator royalty credited in the ledger)](base-mainnet-2026-09-27-escrow-option-b-upgrade.md) |
| 2026-11-22 | [F-01 partial release: vault libraries, upgradeable vault, escrow upgrade and vault switch](base-mainnet-2026-11-22-f01-partial-release-upgrade.md) |
| 2026-11-22 | [F-01 live test and Bundle administration (owner, image base URI)](base-mainnet-2026-11-22-f01-live-test-and-bundle-admin.md) |
| 2026-11-23 | [Bundle ownership change and bundle #12 publication](base-mainnet-2026-11-23-bundle-owner-and-bundle-12-publication.md) |
| 2026-11-24 | [Bundle upgrade: zero marketplace royalty](base-mainnet-2026-11-24-bundle-zero-royalty-upgrade.md) |

## Source and live bytecode

Built from this tree with the release link flags, the vault and both libraries match their live runtimes exactly, and the escrow differs only in its metadata hash. The live Bundle `0x79a6…8a97` was compiled against the earlier six-value `BundleState`; this tree's build differs from it at one decoder-bound byte. See [Source on main](base-mainnet-2026-11-24-bundle-zero-royalty-upgrade.md#source-on-main-item-79-recorded-november-24).

## Evidence limits

The F-01 Plan B submissions, the OpenSea creator-earnings changes and both bundle #12 API posts are operator-reported off-chain events. Their corresponding Base transactions are independently documented.
