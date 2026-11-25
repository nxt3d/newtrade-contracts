# Live V2 architecture

The live V2 system is `NewTradeEscrowV2` (UUPS proxy), the upgradeable vault
`NewTradeV2VaultV2` (UUPS proxy, linked to the `VaultAdmission` and `VaultCustodyIn`
libraries) and the claim collection `NewTradeBundle` (UUPS proxy). The escrow is its own
Seaport zone. The source and `src/INewTradeEscrowV2.sol` define the executable protocol.

The vault holds the controlling NFT and the explicit canonical manifest. The seller lists
exact sale terms on chain. Seaport offers the restricted claim, and `BundleSold` records the
authoritative first sale. At that sale the escrow credits the seller's proceeds and the
controlling NFT's ERC-2981 royalty in its owed ledger, and keeps the protocol fee as
surplus. The Bundle quotes zero royalty to marketplaces. The claim cannot move again after
the first sale. The current holder redeems; only the recorded seller can reclaim an unsold
bundle after its deadline. On reclaim the controlling NFT returns to the seller and the
manifest assets go to the `extrasTo` address the seller passes to
`reclaim(bundleId, extrasTo)`. Release is per entry with gas guards, so one failing asset
cannot block the rest.

The Bundle's `tokenURI` is built on chain. Its image is the image base URI plus the id if
set, otherwise the configured renderer's answer, otherwise the built-in card: here
the built-in `NewTradeBundleCard`. The fallback renderer configured on chain,
`0x4519D5429391aA6bBcBB33ad248470d5e45856c5`, is outside this repository; the live image
comes from `imageBaseURI`, which is set and takes precedence over the renderer. Any unusable
renderer answer falls back to the card.

## Source and consumer handoff

- Live contracts: `src/`, `src/interfaces/` and `src/libraries/`.
- Tests: `test/`, with RPC-dependent and live-input cases skipped by default. Historical
  contracts the tests still deploy (the previous vault, the one-shot ledger seeder, the
  retired royalty receiver, the royalty test NFT and the original V2 deploy script) live in `test/legacy/`.
  Fixtures and token mocks live in `test/fixtures/` and `test/mocks/`.
- `tooling/export-abis.sh` regenerates the consumer ABIs in `abi/`.
  `tooling/export-migration-handoff.sh` also refreshes the deterministic migration fixture
  in `test/fixtures/migration/` and the ABI checksum manifest.
- Consumers copy reviewed artifacts into their own tracked locations.

## Live source and bytecode

Built with the release link flags (`--libraries` for `VaultAdmission` and
`VaultCustodyIn` at their live addresses), both libraries and the vault match their live
runtimes exactly. The escrow matches in every executable byte; only its metadata hash
differs.

The live Bundle `0x79a6…8a97` was compiled against an earlier `NewTradeV2Types.sol`, whose
`BundleState` has six values. This tree appends `Redeeming` and `Reclaiming`. The Bundle's
ABI decoder range-checks the `state` it reads in `tokenURI`, so a release build from this
tree differs at exactly that bound: one executable byte (`PUSH1 0x06` live, `0x08` here),
plus metadata. The live bound cannot be reached through an existing token, because redeem
and reclaim burn the claim in the same transaction that writes the new state. The comparison
is in the [Bundle zero-royalty deployment record](deployments/base-mainnet-2026-11-24-bundle-zero-royalty-upgrade.md#source-on-main-item-79-recorded-november-24).

## Storage and trust

The escrow uses direct private state variables; future implementations must preserve
field order and types and append new fields. The vault keeps its state in an ERC-7201
namespace, and `test/layout/check_storage_layout.py` gates both layouts. OpenZeppelin
parents keep their own namespaced storage. Upgrade and admin authority are part of the
trust model.
