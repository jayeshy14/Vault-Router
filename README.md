# vault-router

Modular ERC-4626 vault built on the EIP-2535 Diamond pattern. Routes a single underlying asset (USDC on Base) across allow-listed strategy facets (Morpho Blue, Aave V3, Pendle PT) under a curator role.

**Status:** scaffold. Core / strategies / deploy land in upcoming commits.

## Roadmap

| Week | Scope |
|---|---|
| 1 | Diamond core, ERC-4626 surface, allocator + risk controls, harvest + fees, unit tests |
| 2 | Morpho Blue, Aave V3, Pendle PT strategy facets — each with mainnet-fork tests on Base |
| 3 | Invariant tests, Base Sepolia deploy, architecture writeup, README |

## Build

```sh
forge install
forge build
forge test
```

Run the Diamond storage-collision detector after every facet change:

```sh
npx -y diamond-detect --facets 'src/facets/**' .
```

## License

MIT.
