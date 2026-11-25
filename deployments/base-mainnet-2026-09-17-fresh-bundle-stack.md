# Fresh bundle, vault, royalty receiver and escrow · Base mainnet

A new Bundle collection, vault, royalty receiver and escrow replaced the first beta stack for new bundles. The release archive verified runtime bytecode, proxy implementation slots and all three controller bindings. The operator then seeded token #102 with ten USDC base units for fresh bundle #1.

Source: 76d632cb39f72c6f67bd32c25ff3c48965bedf6b. Signer: `0xF8e03bd4436371E0e2F7C02E529b2172fe72b4EF`.

## Transactions and addresses

| Nonce | Operation | Created contract or destination | Block | Transaction |
|---:|---|---|---:|---|
| 215 | Deploy Bundle implementation | `0x19be700bf6744253a36fb14e7d8d6a55b8b0b40f` | 51436376 | `0x5943117061b673667e89aa1011435296aab561b2ccb8e6b5f51d42dda78168d4` |
| 216 | Deploy Bundle proxy | `0x59900b207ea703b0bbcf8fd84c5e11de46826185` | 51436377 | `0xbe9c7ae9f5f3821388812b0bbae6a5c84976a010f38079e8f6f37426965ad336` |
| 217 | Deploy vault | `0xf39e70134782d7b27d4dba01a0b98b1d69e49b12` | 51436378 | `0xef6cbf012e6e763dfba0bad397aada076810ef7e7bde9d35016cbe7e001890a3` |
| 218 | Deploy royalty receiver | `0x9182e5b06bf25a49c0e6ed04d2a44146d25d4394` | 51436379 | `0x5fcaf4ad9a92588bc4026f9df4b6da08434afe62e835a963988a9108b9ef54ff` |
| 219 | Deploy escrow implementation | `0x867b4b13dc0c0b5f0c888e4f5eb0009da76aee02` | 51436380 | `0xec7e8971d2e13b08a5917e6ebeea4805f457427ed8237548130e5148188238c6` |
| 220 | Deploy escrow proxy | `0xcc29f5c82c8b7c01cac6036047e7413df458f86d` | 51436381 | `0x698127eae56c48ebfb6804a0285af2fa1fe97e5c74bcbd1cffd04ff5b65743b6` |
| 221 | Bind Bundle controller | `0x59900b207ea703b0bbcf8fd84c5e11de46826185` | 51436382 | `0xbe522ae7f5c4164da065e2face1180da43be274abd390b60dcce87dfe493ff1e` |
| 222 | Bind vault controller | `0xf39e70134782d7b27d4dba01a0b98b1d69e49b12` | 51436383 | `0x06196cdbccc6e0f3e224c5237e15d798b835b36ab2babb06575a94da7274a762` |
| 223 | Bind royalty receiver | `0x9182e5b06bf25a49c0e6ed04d2a44146d25d4394` | 51436384 | `0xb38c45da0b811038212e8414432da081ef3d9304379a460199b8387240cf3f68` |
| 224 | Mint #102 | `0xf4fd1a2ea84a16be24848aa6f4242e9caab18953` | 51440161 | `0x2b24590780ff4e6334bb1c756ecb10c68914b196da9c2c4f92336b136f8eb244` |
| 225 | Fund token account | `0x833589fcd6edb6e08f4c7c32d4f71b54bda02913` | 51440396 | `0x688afa17fb4a76689b70521d64961f24d486333ad21bab7083d0c4949be76b37` |
| 226 | Approve NFT | `0xf4fd1a2ea84a16be24848aa6f4242e9caab18953` | 51440550 | `0xff8b38fb28457507c394c1f916f54085a1ef58b1a1bcbd9dabac33a39c9949e3` |
| 227 | Enable migration | `0xcc29f5c82c8b7c01cac6036047e7413df458f86d` | 51440721 | `0x657b5c5c8440a2a97843fce3b99263bb5d6aed2e4ea5c680cf45d7876c68f1d4` |
| 228 | Deposit bundle #1 | `0xcc29f5c82c8b7c01cac6036047e7413df458f86d` | 51440731 | `0x1e490e56376a9964382db4f252766bed1b4623b0b61831b8b7c84a5057df4cb7` |
| 229 | Disable migration | `0xcc29f5c82c8b7c01cac6036047e7413df458f86d` | 51440757 | `0xc6ef57654aa6861cd587ee894d157210787009addd69500c68f50a2967d5e23e` |
| 230 | List bundle #1 | `0xcc29f5c82c8b7c01cac6036047e7413df458f86d` | 51440885 | `0xd916862e2add6ea43d968cfb87bef4191d708f2c93613766c4147385a57ff3a9` |

## Verification

The historical Base audit located each sender nonce in a canonical block and matched its receipt, block number and status (all successful). Release evidence: prepare-deploy-fresh-base-bundle-stack-sep17/deployment-record.md and promote-fresh-bundle1-site-sep17/report.md.

## Rollback

Keep both stacks addressable for existing positions. Restoring app pins requires a custody- and order-aware release decision; original addresses cannot be removed.

## Machine-readable record

```json
{
  "chainId": 8453,
  "source": "76d632cb39f72c6f67bd32c25ff3c48965bedf6b",
  "transactions": [
    {
      "operation": "Deploy Bundle implementation",
      "nonce": 215,
      "hash": "0x5943117061b673667e89aa1011435296aab561b2ccb8e6b5f51d42dda78168d4",
      "block": 51436376,
      "to": null,
      "selector": "0x60a08060",
      "date": "2026-09-17",
      "contract": "0x19be700bf6744253a36fb14e7d8d6a55b8b0b40f",
      "status": 1
    },
    {
      "operation": "Deploy Bundle proxy",
      "nonce": 216,
      "hash": "0xbe9c7ae9f5f3821388812b0bbae6a5c84976a010f38079e8f6f37426965ad336",
      "block": 51436377,
      "to": null,
      "selector": "0x60806040",
      "date": "2026-09-17",
      "contract": "0x59900b207ea703b0bbcf8fd84c5e11de46826185",
      "status": 1
    },
    {
      "operation": "Deploy vault",
      "nonce": 217,
      "hash": "0xef6cbf012e6e763dfba0bad397aada076810ef7e7bde9d35016cbe7e001890a3",
      "block": 51436378,
      "to": null,
      "selector": "0x60c08060",
      "date": "2026-09-17",
      "contract": "0xf39e70134782d7b27d4dba01a0b98b1d69e49b12",
      "status": 1
    },
    {
      "operation": "Deploy royalty receiver",
      "nonce": 218,
      "hash": "0x5fcaf4ad9a92588bc4026f9df4b6da08434afe62e835a963988a9108b9ef54ff",
      "block": 51436379,
      "to": null,
      "selector": "0x60a03460",
      "date": "2026-09-17",
      "contract": "0x9182e5b06bf25a49c0e6ed04d2a44146d25d4394",
      "status": 1
    },
    {
      "operation": "Deploy escrow implementation",
      "nonce": 219,
      "hash": "0xec7e8971d2e13b08a5917e6ebeea4805f457427ed8237548130e5148188238c6",
      "block": 51436380,
      "to": null,
      "selector": "0x60a08060",
      "date": "2026-09-17",
      "contract": "0x867b4b13dc0c0b5f0c888e4f5eb0009da76aee02",
      "status": 1
    },
    {
      "operation": "Deploy escrow proxy",
      "nonce": 220,
      "hash": "0x698127eae56c48ebfb6804a0285af2fa1fe97e5c74bcbd1cffd04ff5b65743b6",
      "block": 51436381,
      "to": null,
      "selector": "0x60806040",
      "date": "2026-09-17",
      "contract": "0xcc29f5c82c8b7c01cac6036047e7413df458f86d",
      "status": 1
    },
    {
      "operation": "Bind Bundle controller",
      "nonce": 221,
      "hash": "0xbe522ae7f5c4164da065e2face1180da43be274abd390b60dcce87dfe493ff1e",
      "block": 51436382,
      "to": "0x59900b207ea703b0bbcf8fd84c5e11de46826185",
      "selector": "0x09d00f26",
      "date": "2026-09-17",
      "contract": null,
      "status": 1
    },
    {
      "operation": "Bind vault controller",
      "nonce": 222,
      "hash": "0x06196cdbccc6e0f3e224c5237e15d798b835b36ab2babb06575a94da7274a762",
      "block": 51436383,
      "to": "0xf39e70134782d7b27d4dba01a0b98b1d69e49b12",
      "selector": "0x09d00f26",
      "date": "2026-09-17",
      "contract": null,
      "status": 1
    },
    {
      "operation": "Bind royalty receiver",
      "nonce": 223,
      "hash": "0xb38c45da0b811038212e8414432da081ef3d9304379a460199b8387240cf3f68",
      "block": 51436384,
      "to": "0x9182e5b06bf25a49c0e6ed04d2a44146d25d4394",
      "selector": "0x09d00f26",
      "date": "2026-09-17",
      "contract": null,
      "status": 1
    },
    {
      "operation": "Mint #102",
      "nonce": 224,
      "hash": "0x2b24590780ff4e6334bb1c756ecb10c68914b196da9c2c4f92336b136f8eb244",
      "block": 51440161,
      "to": "0xf4fd1a2ea84a16be24848aa6f4242e9caab18953",
      "selector": "0x40c10f19",
      "date": "2026-09-17",
      "contract": null,
      "status": 1
    },
    {
      "operation": "Fund token account",
      "nonce": 225,
      "hash": "0x688afa17fb4a76689b70521d64961f24d486333ad21bab7083d0c4949be76b37",
      "block": 51440396,
      "to": "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913",
      "selector": "0xa9059cbb",
      "date": "2026-09-17",
      "contract": null,
      "status": 1
    },
    {
      "operation": "Approve NFT",
      "nonce": 226,
      "hash": "0xff8b38fb28457507c394c1f916f54085a1ef58b1a1bcbd9dabac33a39c9949e3",
      "block": 51440550,
      "to": "0xf4fd1a2ea84a16be24848aa6f4242e9caab18953",
      "selector": "0x095ea7b3",
      "date": "2026-09-17",
      "contract": null,
      "status": 1
    },
    {
      "operation": "Enable migration",
      "nonce": 227,
      "hash": "0x657b5c5c8440a2a97843fce3b99263bb5d6aed2e4ea5c680cf45d7876c68f1d4",
      "block": 51440721,
      "to": "0xcc29f5c82c8b7c01cac6036047e7413df458f86d",
      "selector": "0x521c27f2",
      "date": "2026-09-17",
      "contract": null,
      "status": 1
    },
    {
      "operation": "Deposit bundle #1",
      "nonce": 228,
      "hash": "0x1e490e56376a9964382db4f252766bed1b4623b0b61831b8b7c84a5057df4cb7",
      "block": 51440731,
      "to": "0xcc29f5c82c8b7c01cac6036047e7413df458f86d",
      "selector": "0x5fd6fe0e",
      "date": "2026-09-17",
      "contract": null,
      "status": 1
    },
    {
      "operation": "Disable migration",
      "nonce": 229,
      "hash": "0xc6ef57654aa6861cd587ee894d157210787009addd69500c68f50a2967d5e23e",
      "block": 51440757,
      "to": "0xcc29f5c82c8b7c01cac6036047e7413df458f86d",
      "selector": "0x521c27f2",
      "date": "2026-09-17",
      "contract": null,
      "status": 1
    },
    {
      "operation": "List bundle #1",
      "nonce": 230,
      "hash": "0xd916862e2add6ea43d968cfb87bef4191d708f2c93613766c4147385a57ff3a9",
      "block": 51440885,
      "to": "0xcc29f5c82c8b7c01cac6036047e7413df458f86d",
      "selector": "0xd035346c",
      "date": "2026-09-17",
      "contract": null,
      "status": 1
    }
  ]
}
```
