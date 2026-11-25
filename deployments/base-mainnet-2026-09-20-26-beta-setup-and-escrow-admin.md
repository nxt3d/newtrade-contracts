# September beta token setup and escrow administration

The deployer minted Beta NFTs #103–106, transferred USDC for testing, set the escrow’s protocol fee to 500 basis points, and withdrew 500,000,000 wei of surplus ETH. The recipient and amount below come from the transaction calldata. Two transfers followed the mint of #104. Only the transfer to its registry-derived account is attributed to that NFT. The account register (record not included in this repository) identifies all four token accounts.

The mints use the September 17 Beta collection (record not included in this repository). The escrow’s [fee upgrade](base-mainnet-2026-09-26-escrow-fee-from-proceeds-upgrade.md) describes the surplus accounting. Each receipt succeeded at the block shown. Restoring a fee setting requires a separately authorized admin transaction. A prior transfer or mint remains part of the chain history.

| Date UTC | Nonce | Operation | Block | Transaction |
|---|---:|---|---:|---|
| 2026-09-20 | 235 | Mint Beta NFT #103 to 0x9a704664009d615a90dddf9345b6b8b2a214cfb2 | 51563391 | `0x81a83d64499e5c2df6e7016c9c4ca2f956f4f979a2ef5357840a842d4f08346e` |
| 2026-09-20 | 236 | Transfer 10 USDC base units to 0xb1b465538b85c6843bf024562f5ea045a6698862 | 51564354 | `0x17a3395082dcccc30c455921a56829bd559223cd7ec57bf5d333808a1ba31046` |
| 2026-09-25 | 237 | Set escrow protocol fee to 500 bps | 51758657 | `0x49683692e60dcd25f39dc4922af07a3475662dd9854e714128c418472df44244` |
| 2026-09-25 | 238 | Mint Beta NFT #104 to 0x9a704664009d615a90dddf9345b6b8b2a214cfb2 | 51759018 | `0x5c29e545c7bb4cc53bfe4fc20bf4d061633e2a86a44ae3d493587671313761d2` |
| 2026-09-25 | 239 | Transfer 10 USDC base units to 0x31b5e9095c9f9b1accc8c3afdc621d5753738523 | 51759103 | `0xea76230a0fa513a3d0671f01fc65215af4aaf3d362b10c5f724654115d708121` |
| 2026-09-25 | 240 | Transfer 10 USDC base units to 0x4f6b937ca9b1df4a17470e2ab86bba5ff83ca88f | 51759139 | `0x11f3f4b5b2fc500cffc2bb6d683e19c4c29923e33c728fe1d0f2df8f35c83436` |
| 2026-09-26 | 253 | Mint Beta NFT #105 to 0x9a704664009d615a90dddf9345b6b8b2a214cfb2 | 51825295 | `0xba81675ade5c9b2a2460e5d191b83251be4c6d96a66dcaf121e08ff2ea2d82e1` |
| 2026-09-26 | 254 | Transfer 10 USDC base units to 0x358167b0043f8a962a83641917633b5d1ca450ff | 51825308 | `0xdd33d491710fa986800a1da020a1107dd79baea8234f8a5df64475ffc7a5c235` |
| 2026-09-26 | 255 | Withdraw 500000000 wei of surplus ETH to 0xc3f96c409d26272fdb592c0d04e1d771a7df032e | 51825456 | `0x29904bbaade32fc343020017bec902b5d95614174208d28446c2389548faf09b` |
| 2026-09-26 | 256 | Mint Beta NFT #106 to 0x9a704664009d615a90dddf9345b6b8b2a214cfb2 | 51830149 | `0xa2c7861b360c206f0dc8cb0ef9e880be255d68c3337c60bbc3b937541dfa2f5b` |
| 2026-09-26 | 257 | Transfer 10000 USDC base units to 0x2d6ff82ae9881b5e82334a75401028ebc93c227d | 51830167 | `0x67cb0fb51336d124299e0132585052c48d52e74be5768bf7c0da783b464c1a79` |

```json
{
  "chainId": 8453,
  "signer": "0xF8e03bd4436371E0e2F7C02E529b2172fe72b4EF",
  "transactions": [
    {
      "nonce": 235,
      "hash": "0x81a83d64499e5c2df6e7016c9c4ca2f956f4f979a2ef5357840a842d4f08346e",
      "block": 51563391,
      "to": "0xf4fd1a2ea84a16be24848aa6f4242e9caab18953",
      "selector": "0x40c10f19",
      "date": "2026-09-20",
      "contract": null,
      "status": 1,
      "operation": "Mint Beta NFT #103 to 0x9a704664009d615a90dddf9345b6b8b2a214cfb2"
    },
    {
      "nonce": 236,
      "hash": "0x17a3395082dcccc30c455921a56829bd559223cd7ec57bf5d333808a1ba31046",
      "block": 51564354,
      "to": "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913",
      "selector": "0xa9059cbb",
      "date": "2026-09-20",
      "contract": null,
      "status": 1,
      "operation": "Transfer 10 USDC base units to 0xb1b465538b85c6843bf024562f5ea045a6698862"
    },
    {
      "nonce": 237,
      "hash": "0x49683692e60dcd25f39dc4922af07a3475662dd9854e714128c418472df44244",
      "block": 51758657,
      "to": "0xcc29f5c82c8b7c01cac6036047e7413df458f86d",
      "selector": "0xc5f0d916",
      "date": "2026-09-25",
      "contract": null,
      "status": 1,
      "operation": "Set escrow protocol fee to 500 bps"
    },
    {
      "nonce": 238,
      "hash": "0x5c29e545c7bb4cc53bfe4fc20bf4d061633e2a86a44ae3d493587671313761d2",
      "block": 51759018,
      "to": "0xf4fd1a2ea84a16be24848aa6f4242e9caab18953",
      "selector": "0x40c10f19",
      "date": "2026-09-25",
      "contract": null,
      "status": 1,
      "operation": "Mint Beta NFT #104 to 0x9a704664009d615a90dddf9345b6b8b2a214cfb2"
    },
    {
      "nonce": 239,
      "hash": "0xea76230a0fa513a3d0671f01fc65215af4aaf3d362b10c5f724654115d708121",
      "block": 51759103,
      "to": "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913",
      "selector": "0xa9059cbb",
      "date": "2026-09-25",
      "contract": null,
      "status": 1,
      "operation": "Transfer 10 USDC base units to 0x31b5e9095c9f9b1accc8c3afdc621d5753738523"
    },
    {
      "nonce": 240,
      "hash": "0x11f3f4b5b2fc500cffc2bb6d683e19c4c29923e33c728fe1d0f2df8f35c83436",
      "block": 51759139,
      "to": "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913",
      "selector": "0xa9059cbb",
      "date": "2026-09-25",
      "contract": null,
      "status": 1,
      "operation": "Transfer 10 USDC base units to 0x4f6b937ca9b1df4a17470e2ab86bba5ff83ca88f"
    },
    {
      "nonce": 253,
      "hash": "0xba81675ade5c9b2a2460e5d191b83251be4c6d96a66dcaf121e08ff2ea2d82e1",
      "block": 51825295,
      "to": "0xf4fd1a2ea84a16be24848aa6f4242e9caab18953",
      "selector": "0x40c10f19",
      "date": "2026-09-26",
      "contract": null,
      "status": 1,
      "operation": "Mint Beta NFT #105 to 0x9a704664009d615a90dddf9345b6b8b2a214cfb2"
    },
    {
      "nonce": 254,
      "hash": "0xdd33d491710fa986800a1da020a1107dd79baea8234f8a5df64475ffc7a5c235",
      "block": 51825308,
      "to": "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913",
      "selector": "0xa9059cbb",
      "date": "2026-09-26",
      "contract": null,
      "status": 1,
      "operation": "Transfer 10 USDC base units to 0x358167b0043f8a962a83641917633b5d1ca450ff"
    },
    {
      "nonce": 255,
      "hash": "0x29904bbaade32fc343020017bec902b5d95614174208d28446c2389548faf09b",
      "block": 51825456,
      "to": "0xcc29f5c82c8b7c01cac6036047e7413df458f86d",
      "selector": "0xb516fd98",
      "date": "2026-09-26",
      "contract": null,
      "status": 1,
      "operation": "Withdraw 500000000 wei of surplus ETH to 0xc3f96c409d26272fdb592c0d04e1d771a7df032e"
    },
    {
      "nonce": 256,
      "hash": "0xa2c7861b360c206f0dc8cb0ef9e880be255d68c3337c60bbc3b937541dfa2f5b",
      "block": 51830149,
      "to": "0xf4fd1a2ea84a16be24848aa6f4242e9caab18953",
      "selector": "0x40c10f19",
      "date": "2026-09-26",
      "contract": null,
      "status": 1,
      "operation": "Mint Beta NFT #106 to 0x9a704664009d615a90dddf9345b6b8b2a214cfb2"
    },
    {
      "nonce": 257,
      "hash": "0x67cb0fb51336d124299e0132585052c48d52e74be5768bf7c0da783b464c1a79",
      "block": 51830167,
      "to": "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913",
      "selector": "0xa9059cbb",
      "date": "2026-09-26",
      "contract": null,
      "status": 1,
      "operation": "Transfer 10000 USDC base units to 0x2d6ff82ae9881b5e82334a75401028ebc93c227d"
    }
  ]
}
```
