# KennyCraft · KCN Live

Read-only judge dashboard for the existing KennyCoin economy on **Solana devnet**. No signing, wallet creation, token minting, exchanges, or gameplay changes. This directory is independent of the game build.

## Run locally

Use **Node 22.13+** (tested with 22.23.3) and npm. Older Node 22 releases cannot load the scaffold's current Tailwind dependencies. Ensure the compatible Node binary is first on `PATH`, including for subprocesses.

```sh
cd dashboard
npm ci
cp .env.example .env.local
# Set KCN_MINT and at least player=<public address> in KCN_WALLETS.
npm run dev -- --hostname 127.0.0.1
```

Open http://127.0.0.1:3000. Without public addresses, the page shows setup instructions and `/api/kcn` returns 503, never an invented zero balance. Restart after changing environment values; configuration and activity caches are process-local.

| Variable                              | Meaning                                                                                                                                                              |
| ------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `KCN_MINT`                            | Existing devnet SPL token mint; required                                                                                                                             |
| `KCN_WALLETS`                         | Comma-separated `label=address`; `player` required. Optional `banker`, `escrow`, `builder`, `miner`, `farmer`. Addresses may be owners or individual token accounts. |
| `SOLANA_RPC_URL`                      | Defaults to public devnet RPC; a provider URL remains server-side                                                                                                    |
| `SOLANA_CLUSTER`                      | Unset or `devnet` only                                                                                                                                               |
| `KCN_PER_USD`                         | Positive illustrative game-bank rate; defaults to 10 KCN per dollar                                                                                                  |
| `NESSIE_API_KEY`, `NESSIE_ACCOUNT_ID` | Both required for the optional actual Nessie mock-account panel; never sent to the browser                                                                           |

Only public Solana addresses are needed. Never enter a seed phrase, private key, mint authority, or treasury secret. Duplicate labels/addresses, overlapping resolved token accounts, and token accounts for a different mint are configuration errors. Binary token data is a read failure, not a zero balance.

## Reading the display

- Every Solana request asks for **finalized** commitment. Confirmation latency is separate from the ~5-second completion-based balance poll. Reads in a snapshot are not an atomic same-slot view.
- Hero, supply, wallet table, and deltas retain exact decimal strings derived with `bigint`. Only chart geometry and the approximate fixed-rate dollar equivalent use floating point.
- Chart points are observations collected during this browser session (newest 120), not reconstructed history. One initial point is a dot. Mint/player changes reset the session.
- Activity refreshes at most once per 15 seconds, with one shared in-flight refresh. It examines up to 10 signatures per owner/token account, unions the newest 20, and keeps up to 100 finalized transaction results. Transaction reads are limited to two concurrently. Same-slot order is not a total chronology; this is not a complete ledger.
- Named banker/escrow movements are **inferred from configured roles**, not verified fiat settlement or contract-job completion. Untracked counterparties remain in deltas. Missing token metadata is omitted with a warning, not inferred as mint/burn. Failed transactions have no balance deltas.
- Balance read failures retain the last successful snapshot with a stale banner and its real timestamp. Activity failures preserve previous activity independently. Hidden tabs pause both polls; returning fetches immediately. No overlapping interval requests.
- The Nessie panel reads the supplied mock account, deposits, and withdrawals. Partial list failures retain the account and other list. Mock dollars are not correlated with KCN transfers without a shared backend reference.
- Remote descriptions and memos are rendered as escaped text. Explorer links explicitly select devnet.

`GET /api/kcn` returns the snapshot, 503 configuration errors, or a sanitized 502 RPC error. `GET /api/bank` returns `{configured:false}` without both optional keys, otherwise actual mock account data or a sanitized 502. Mutation methods return 405. Responses use `Cache-Control: no-store`. Keep this judge display on loopback; public hosting/authentication is out of scope.

## Verification

```sh
npm test
npm run lint
npm run build
# Optional production smoke after build:
npm run start -- --hostname 127.0.0.1
```

No chain configuration or network credentials are required for tests/build. Tests cover exact amounts, owner/token-account mapping, closed/new token accounts, role classification, missing metadata, failed transactions, ambiguous accounts, bounded concurrency, null-result retry, shared activity refresh, and independent activity failures. Chain tests use an isolated loopback RPC, never devnet writes.

Runtime verification completed against a **temporary local JSON-RPC harness**, not a real KCN deployment: player 20 → 40, banker 980 → 960, supply 1000; observed $2.00 → $4.00 equivalent, +20 activity and change indicator, then RPC errors retaining 40 with stale status. Setup state and mobile layout were checked in Chromium. No verification addresses or fixture responses are shipped in application code or `.env.local`.

The compiled production app was also exercised in Chromium. Independent fixture RPC reads matched the exact API balance (40 base units, zero decimals). Initial activity did not highlight, and memo markup remained plain text. An activity-only outage retained both live balances and the previous activity list. Controlled browser visibility suppressed both polls for more than 15 seconds and resumed immediately; delaying a KCN response by 6.5 seconds produced a ~11.5-second start-to-start gap with at most one in-flight KCN poll. Missing-config API responses, mutation-method 405 responses, and sanitized RPC 502 errors were checked directly. `npm test` (25 tests), lint, and production build passed.

**Live integration remains unverified:** Kenny must supply the existing public devnet mint and player owner/token-account address and initiate a normal backend action for the final live demo. Independently sum `getTokenAccountsByOwner` raw amounts for that mint (or read `getAccountInfo` for an individual token account), apply the mint decimals, and compare the exact `/api/kcn` balance. No replacement mint should be created. Optional live Nessie integration was not exercised because credentials were not supplied.
