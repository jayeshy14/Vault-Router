# Vault Router

Modular ERC-4626 yield vault built on the EIP-2535 Diamond pattern. Routes a single underlying asset (USDC) across allow listed strategy facets under a curator role.

## Why

Most curated yield vaults use cloned proxies or monolithic upgradeable contracts. A Diamond based vault gives you per strategy upgradeability and allows add, replace, or remove a strategy facet without redeploying the vault or migrating user funds. The ERC-4626 surface stays stable while the strategy layer evolves.

## Architecture

```
                  ┌─────────────────────────────┐
                  │          Vault.sol          │
                  │   (ERC-4626 + Diamond proxy)│
                  └──────────────┬──────────────┘
                                 │ delegatecall
       ┌─────────────────────────┼────────────────────┐
       │                         │                    │
       ▼                         ▼                    ▼
┌─────────────┐       ┌──────────────────┐   ┌───────────────────┐
│ Allocator   │       │  HarvestFacet    │   │  Strategy Facets  │
│ Facet       │       │  - harvest()     │   │  - Morpho Blue    │
│ - rebalance │       │  - harvestAll()  │   │  - Aave V3        │
│ - setCaps   │       └──────────────────┘   │  - Idle           │
└─────────────┘                              └───────────────────┘

```

All facet state is isolated using EIP-7201 namespaced storage — no storage collisions across upgrades.

## Roles

| Role | Permissions |
|------|-------------|
| **Owner** | Add / remove / replace facets via `diamondCut` |
| **Curator** | Register strategies, set allocations, trigger rebalance and harvest |
| **User** | Deposit / withdraw underlying asset |

## Strategies

| Strategy | Protocol | Yield Source |
|----------|----------|-------------|
| `MorphoStrategyFacet` | Morpho Blue (MetaMorpho vaults) | Lending supply rate |
| `AaveStrategyFacet` | Aave V3 | aToken rebasing yield |
| `IdleStrategyFacet` | — | Idle reserve (no deployment) |

New strategies are added as facets and registered through the curator, no vault redeployment required.

## Risk Controls

- Per strategy allocation caps
- Global idle reserve floor, configurable % kept liquid for instant withdrawals
- Performance fee gated by High Water Mark, fees only taken on net gains
- Management fee accrues linearly (capped at 10% annually)
- Slippage protection on strategy deposits

## Fees

- **Performance fee** — taken on gains above the High Water Mark on each deposit/withdrawal
- **Management fee** — accrues continuously, claimed on each deposit/withdrawal
- Both configurable by owner, performance fee capped at 50%, management fee at 10% annually

## Quickstart

```sh
git clone https://github.com/jayeshy14/Vault-Router
forge install
forge build
forge test
```

Run the Diamond storage collision detector after every facet change:

```sh
npx -y diamond-detect --facets 'src/facets/**' .
```

Run mainnet fork tests:

```sh
forge test --fork-url $ARB_RPC_URL --match-path 'test/integration/*'
```

## License

MIT
