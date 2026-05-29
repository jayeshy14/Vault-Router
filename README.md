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
| **Owner** | Add / remove / replace facets via `diamondCut`, register / remove strategies, set caps + idle floor, configure fees, appoint / revoke curators |
| **Curator** | Set allocations, trigger rebalance and harvest — **within** the bounds the owner sets |
| **User** | Deposit / withdraw underlying asset |

The curator is a deliberately low-privilege operational key: it can move capital only between owner-allow-listed strategies and only within owner-set caps and the idle floor — it can never upgrade facets, change fees, or withdraw funds. This separation is what makes it safe to delegate day-to-day rebalancing to an automated operator (e.g. an off-chain agent) without exposing the vault to it. Owners are implicitly curators, so governance can always operate the vault directly.

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
- NAV circuit breaker — bounds how far the share price may move between checkpoints

### NAV circuit breaker

The vault prices its shares on-chain (idle balance + each strategy's reported
position). To contain a bad rebalance, oracle glitch, or strategy exploit, the
owner sets `maxSharePriceDeltaBps` — the maximum share-price move tolerated
between checkpoints. Two enforcement paths:

- **Hot-path tripwire** — every deposit/withdraw re-prices the vault and reverts
  (`SharePriceDeviation`) if the move exceeds the bound, so users never transact
  at an anomalous NAV. Self-healing: once the price is back in band, ops resume.
- **Latching poke** — anyone (a keeper or the curator agent) can call
  `guardCheckpoint()`; on a breach it latches the vault into a paused state that
  persists until the owner reviews and `unpause()`s. A revert can't latch a pause
  in the same call, so this dedicated poke is what makes the auto-pause stick.

The owner can also `pause()` / `unpause()` manually. With the bound set to `0` the
deviation check is disabled and only manual pause applies.

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
