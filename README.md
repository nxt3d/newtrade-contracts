# NewTrade contracts

NewTrade V2 bundles an NFT and the agreed assets in its ERC-6551 account into a bundle NFT that can be bought and sold atomically on Base. Without NewTrade, the seller can withdraw assets from the account before the sale settles, and an approved spender can withdraw them after it. The escrow takes custody of the NFT and the assets before the bundle NFT is listed. On redemption, the buyer receives the NFT and the assets move to a fresh account bound to it, where prior approvals do not apply. The seller can reclaim an unsold bundle after its deadline.

An agent NFT represents the identity of an AI agent. Its ERC-6551 account can hold fungible tokens or digital collectible NFTs. A buyer who values both the identity and the assets can verify the balance and still receive an empty account. The seller can withdraw the assets before the sale settles, and a spender with an existing approval can withdraw them even after the NFT changes hands. The same risk arises whenever assets in an account contribute to the price of the NFT that controls it.

The solution is for the owner to take the agreed assets out of the ERC-6551 account, bundle them with the NFT in a permissionless escrow, and sell the bundle NFT the escrow issues. The owner can also bundle assets from their wallet.

The **escrow** records the NFT and the agreed assets as a **bundle** with a custody deadline. A separate **vault** holds the NFT and the assets. The **bundle NFT** is the claim to redeem the bundle. Each bundle receives a **bundle ID**, and its bundle NFT uses the same number as its token ID. Bundle ID and token ID can therefore be used interchangeably. The **bundle NFT collection** is the separate ERC-721 contract that mints bundle NFTs.

- **`NewTradeEscrowV2`** records the immutable list of assets in each bundle and acts as the Seaport zone that validates the sale terms. At settlement, the escrow credits the seller with the net proceeds and the royalty recipient with the ERC-2981 royalty on the original NFT.
- **`NewTradeV2VaultV2`** releases each item separately on redemption or reclaim. If a transfer fails, the item stays in the vault and anyone can retry its release.
- **`NewTradeBundle`** mints the bundle NFT to the escrow. It transfers to the buyer at the first sale and cannot be transferred again. Redemption or reclaim burns it. The collection quotes zero royalty to marketplaces because the escrow credits the royalty at settlement.

[`ARCHITECTURE.md`](ARCHITECTURE.md) and [`SPEC.md`](SPEC.md) describe the design and
trust model. The Solidity source and `src/INewTradeEscrowV2.sol` are the source of truth.

## Quickstart

Requires [Foundry](https://getfoundry.sh). Dependencies are git submodules pinned to
forge-std v1.16.1 and OpenZeppelin Contracts / Contracts Upgradeable v5.6.1.

```bash
git clone --recursive https://github.com/nxt3d/newtrade-contracts.git
cd newtrade-contracts
forge build
forge test
```

If you cloned without `--recursive`, run `git submodule update --init --recursive` first.

The build uses solc 0.8.28 with `via_ir = true`, optimizer runs 1 and EVM `cancun`
(see `foundry.toml`). The IR pipeline is required, and a cold build takes a few minutes.
`forge test` runs offline: the unit, invariant, fixture and gas-guard suites pass, and the
fork suites under `test/fork/` skip themselves when no fork is configured. The
storage-layout gate is a separate check:

```bash
python3 test/layout/check_storage_layout.py
```

### Fork suites (optional, read-only)

The fork suites replay upgrades and sales against real Base state. Nothing is ever
broadcast. They need a Base mainnet RPC with archive access:

```bash
export RPC_8453=<your Base RPC URL>
forge test --fork-url "$RPC_8453" --match-path 'test/fork/*' --threads 1
```

Suites tied to a past world are pinned to that block or skip themselves outside it. Run
the Bundle zero-royalty rehearsal with `--fork-block-number 61403135` and the
non-transferable suite with `--fork-block-number 51863600`. The real OpenSea calldata
replay (`test/fork/RealCalldataReplay.t.sol`) is opt-in and reads its inputs from the
environment (see [`.env.example`](.env.example)). `test/rpc/estimate-and-execute.sh` is a
local anvil gas check that uses anvil's well-known development keys. Never point it at a
live network.

## Deployments (Base mainnet, chain 8453)

| Contract | Address |
|---|---|
| NewTradeEscrowV2 (proxy) | [`0xCc29F5c82C8b7c01Cac6036047E7413Df458f86d`](https://basescan.org/address/0xCc29F5c82C8b7c01Cac6036047E7413Df458f86d) |
| NewTradeV2VaultV2 (proxy) | [`0xe3a95e47B8ECC9F8E42a7BDE58dde2FBCbc69C53`](https://basescan.org/address/0xe3a95e47B8ECC9F8E42a7BDE58dde2FBCbc69C53) |
| NewTradeBundle (proxy) | [`0x59900b207ea703B0bBcF8fD84C5E11dE46826185`](https://basescan.org/address/0x59900b207ea703B0bBcF8fD84C5E11dE46826185) |
| VaultAdmission (library) | [`0xcbb51e4Cc6166bfa58B3E23AeC9beA0AcCE94a46`](https://basescan.org/address/0xcbb51e4Cc6166bfa58B3E23AeC9beA0AcCE94a46) |
| VaultCustodyIn (library) | [`0x150eaeFfa8134D731B364F67f040cf1661210B64`](https://basescan.org/address/0x150eaeFfa8134D731B364F67f040cf1661210B64) |

[`deployments/`](deployments/README.md) records every deployment, upgrade and
administrative change of these contracts on Base mainnet, from 2026-09-17 to 2026-11-24.

**Contract details.**
- The escrow, the vault and the Bundle are UUPS proxies.
- The vault implementation is linked to the `VaultAdmission` and `VaultCustodyIn`
  libraries listed above, and it releases each manifest entry under a gas guard.
- The Bundle builds its `tokenURI` on chain. The image is the image base URI plus the
  bundle ID if a base URI is set, otherwise the configured renderer's answer, otherwise
  the built-in `NewTradeBundleCard`. `BundleImageURI` checks every image URI, and an
  unusable answer always falls back to the card. Any renderer that implements
  `INewTradeBundleImage` can be set.
- On Base, the configured fallback renderer is
  `0x4519D5429391aA6bBcBB33ad248470d5e45856c5`, which is outside this repository. The
  live image comes from `imageBaseURI`, which is set and takes precedence over the
  renderer.

**Source and live bytecode.** Build with the release settings:

```bash
forge build --skip test --skip script \
  --libraries src/libraries/VaultAdmission.sol:VaultAdmission:0xcbb51e4cc6166bfa58b3e23aec9bea0acce94a46 \
  --libraries src/libraries/VaultCustodyIn.sol:VaultCustodyIn:0x150eaeffa8134d731b364f67f040cf1661210b64
```

Then compare with `eth_getCode`, with the UUPS self-address immutables zeroed:
- **Vault and libraries:** match the live code exactly, including metadata.
- **Escrow:** the executable code is identical, and only the metadata hash differs.
- **Bundle:** the live implementation `0x79a6…8a97` was compiled against the earlier
  six-value `BundleState`. This tree appends two states, so its Bundle build differs at one
  ABI-decoder byte plus the metadata hash (see `ARCHITECTURE.md`).

Read the implementation slot on chain before assuming any tree matches a proxy.

## Layout

- `src/`: the live contracts, interfaces (`src/interfaces/`), the linked vault libraries
  (`src/libraries/`), the image-URI rules (`BundleImageURI`) and the built-in card
  (`NewTradeBundleCard`).
- `test/`: unit, invariant, fixture and gas-guard tests.
  - `test/fork/` holds the opt-in fork suites.
  - `test/layout/` holds the storage-layout gate.
  - `test/rpc/` holds the local anvil gas check.
  - `test/legacy/` holds historical contracts the tests still deploy: the previous vault,
    the one-shot ledger seeder, the retired royalty receiver, the royalty test NFT and the original V2 deploy script.
  - `test/fixtures/` and `test/mocks/` hold the fixtures and token mocks.
- `abi/`: consumer ABIs for the escrow, the vault and the Bundle, plus the Seaport and
  ERC-6551 interfaces, with `artifact-manifest.sha256`. The migration fixture is in
  `test/fixtures/migration/`.
- `tooling/`: scripts that regenerate `abi/` and the migration fixture (`export-abis.sh`,
  `export-migration-handoff.sh`, which needs `jq`).

## Security

These contracts hold user assets. The upgrade and admin keys are part of the trust model
(see `ARCHITECTURE.md`). This is not an audit report. Review the source and the deployment
records before relying on them.

## License

[MIT](LICENSE). Every Solidity file carries `SPDX-License-Identifier: MIT`. Dependencies
keep their own licenses: forge-std is MIT or Apache-2.0, and OpenZeppelin Contracts and
Contracts Upgradeable are MIT.
