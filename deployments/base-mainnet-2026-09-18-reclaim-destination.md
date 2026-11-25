# Escrow reclaim destination and duplicate implementation · Base mainnet

The operator enabled migration, deployed the reclaim-destination implementation twice and upgraded the escrow proxy to the first copy. The upgrade calldata selects the contract created at nonce 232. The second deployment at nonce 233 was never selected in that upgrade.

Source: 4c202bc42356961647d1a99bda13b56e839ec021. Signer: `0xF8e03bd4436371E0e2F7C02E529b2172fe72b4EF`.

## Transactions and addresses

| Nonce | Operation | Created contract or destination | Block | Transaction |
|---:|---|---|---:|---|
| 231 | Set migration flag | `0xcc29f5c82c8b7c01cac6036047e7413df458f86d` | 51491317 | `0x946b1b3968a4c0d0e7dd8c826a3edfc25c6affddb0aa8569a4e2e7f83a639db1` |
| 232 | Deploy escrow implementation | `0x08306a31fc2dd0a00bd8780961fccb923e22c314` | 51491802 | `0x80af8b612cc073b23913a96f703a3136e4bdf7e3b7f9039428a37b5bf6fc2c6b` |
| 233 | Deploy duplicate implementation | `0x1fc9d09ccb5c98bf9f9b4ad87478b5da5e8f5db2` | 51491812 | `0x55fd8feffc93148289c8cf901b14fe843469f93f6ff76359acf1ab6af3b7e1f0` |
| 234 | Upgrade fresh escrow proxy | `0xcc29f5c82c8b7c01cac6036047e7413df458f86d` | 51491856 | `0xb7fa25543ed210e2ce4c9f09a2bbcde983136a1219876f1c669af75b16e45daf` |

## Verification

The historical Base audit located each sender nonce in a canonical block and matched its receipt, block number and status (all successful).

## Rollback

The previous implementation was 0x867b4B13dC0C0B5F0c888E4f5eb0009dA76aEe02. A separately approved compatible upgrade can restore it. Keep the duplicate out of proxy and app configuration.

## Machine-readable record

```json
{
  "chainId": 8453,
  "source": "4c202bc42356961647d1a99bda13b56e839ec021",
  "transactions": [
    {
      "operation": "Set migration flag",
      "nonce": 231,
      "hash": "0x946b1b3968a4c0d0e7dd8c826a3edfc25c6affddb0aa8569a4e2e7f83a639db1",
      "block": 51491317,
      "to": "0xcc29f5c82c8b7c01cac6036047e7413df458f86d",
      "selector": "0x521c27f2",
      "date": "2026-09-18",
      "contract": null,
      "status": 1
    },
    {
      "operation": "Deploy escrow implementation",
      "nonce": 232,
      "hash": "0x80af8b612cc073b23913a96f703a3136e4bdf7e3b7f9039428a37b5bf6fc2c6b",
      "block": 51491802,
      "to": null,
      "selector": "0x60a08060",
      "date": "2026-09-18",
      "contract": "0x08306a31fc2dd0a00bd8780961fccb923e22c314",
      "status": 1
    },
    {
      "operation": "Deploy duplicate implementation",
      "nonce": 233,
      "hash": "0x55fd8feffc93148289c8cf901b14fe843469f93f6ff76359acf1ab6af3b7e1f0",
      "block": 51491812,
      "to": null,
      "selector": "0x60a08060",
      "date": "2026-09-18",
      "contract": "0x1fc9d09ccb5c98bf9f9b4ad87478b5da5e8f5db2",
      "status": 1
    },
    {
      "operation": "Upgrade fresh escrow proxy",
      "nonce": 234,
      "hash": "0xb7fa25543ed210e2ce4c9f09a2bbcde983136a1219876f1c669af75b16e45daf",
      "block": 51491856,
      "to": "0xcc29f5c82c8b7c01cac6036047e7413df458f86d",
      "selector": "0x4f1ef286",
      "date": "2026-09-18",
      "contract": null,
      "status": 1
    }
  ]
}
```
