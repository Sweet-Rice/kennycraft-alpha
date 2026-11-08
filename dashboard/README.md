# KennyCraft · KCN Live

Read-only judge dashboard for the **existing kc-host backend API**. Run it on Kenny's machine alongside the backend. No dashboard wallet addresses, mint address, Solana RPC URL, signing keys, or Nessie credentials are needed.

## Run

Use Node **22.13+** and npm (verified with Node 22.23.3). Ensure the compatible Node binary is first on `PATH`, including subprocesses.

1. Start the existing, already-configured KennyCraft backend as usual. Its `host/kchost.py` serves `GET /events` at `http://127.0.0.1:8000`.
2. In another terminal, from the repository root:

   ```sh
   cd dashboard
   npm ci
   npm run dev -- --hostname 127.0.0.1
   ```

3. Open http://127.0.0.1:3000.

**No `.env.local` is required.** If the backend uses a different port or host, optionally set `KCN_BACKEND_URL` in `dashboard/.env.local` and restart Next.js; see `.env.example`. This is the backend base URL, not its `/events` path. Remove old dashboard Solana/wallet/Nessie variables; they are no longer read.

Backend wallet/mint configuration and Nessie credentials remain owned by kc-host. This dashboard does not start the settler, create replacement tokens, or perform any financial/game actions. Keep both applications on loopback; public deployment/authentication is out of scope.

## One read-only stream

The browser connects to `GET /api/events`. Next.js proxies only the backend's `GET /events` server-sent events, without caching or buffering. No exchange, interaction, cancellation, or other mutation endpoint is proxied. There are no separate chain/bank polls and no direct Solana or Nessie integration in this app.

The consumed snapshot fields match `Host.snapshot()` in `host/kchost.py`:

| Field            | Display meaning                                                                                           |
| ---------------- | --------------------------------------------------------------------------------------------------------- |
| `wallets`        | Whole-KCN game-ledger balances, including queued entries                                                  |
| `ledger`         | Recent backend entries: kind, from/to wallets, amount, contract ID, status, and optional Solana signature |
| `mode`, `queued` | Existing settler's health and queue count                                                                 |
| `usd`            | Nessie's available mock cents reported by the backend; `null` means unavailable                           |

- **Game-ledger balances are not independently verified on-chain balances.** A queued payment already affects the game balance. The UI displays queued/settled status without inferring it from token movements or memo text. Explorer links are shown when a transaction signature is available and select devnet explicitly.
- The fixed `$1 = 10 KCN` hero equivalent is illustrative, not real funds or market value. The bank panel shows actual backend-reported **available** mock dollars, not a fabricated account total or transaction history.
- Snapshot amounts must be safe JSON integers. Unsafe integers and incompatible payloads are rejected rather than silently rounding money or substituting zero. Signed changes use bigint subtraction. The backend currently exposes whole KCN, not raw token base units.
- The chart retains the latest 120 snapshots received this browser session. One initial observation is a dot. It is not reconstructed chain history. New ledger IDs highlight after the initial snapshot; settling an existing ID does not count as another payment.
- Disconnections retain the last valid snapshot and its browser receipt time with a stale banner. Initial failures show connection instructions, never invented balances. Reconnection is automatic, including after an HTTP 502 before the backend starts. Hidden tabs close the stream; returning reconnects immediately. Unmount closes the stream and reconnect timer.
- The backend emits only when its snapshot changes. An old last-update time alone does not mean the open stream is broken. `Live stream` describes the dashboard connection; `ONLINE`/`DEGRADED`/`OFFLINE` describes the backend settler separately.
- Remote text is escaped by React. No private keys or Nessie secrets are loaded by this application.

## Verification

```sh
npm test
npm run lint
npm run build
npm run start -- --hostname 127.0.0.1
```

Tests/build need neither the backend nor credentials. Tests cover incompatible/unsafe money payloads, nullable bank data, initial highlight suppression, new ledger entries, queued-to-settled transitions without double-counting, signed exact changes, and the 120-snapshot retention boundary.

Browser smoke used a **temporary local SSE harness matching `Host.snapshot()`**, not a claimed live KennyCraft session: 20 → 40 KCN, +20 indicator, queued → settled, devnet transaction link, bank available dollars, disconnected stream retaining 40, recovery from initial HTTP 502 without reloading, and rejection of an unsafe-integer snapshot while retaining the previous balance. No test responses or deployment wallet addresses are shipped in application code. The real backend is not available on this development machine; the final live check is to run both applications on Kenny's machine and initiate a normal backend action there.

Verification passed: 9 behavior tests, lint, and production build. The compiled production app displayed pushed queued-to-settled updates without duplicating activity. Mobile layout and hidden-tab closure/resume were checked; the upstream connection count dropped to zero when hidden. The stream endpoint returned `text/event-stream`, and POST returned 405. The obsolete `/api/kcn` and `/api/bank` endpoints returned 404. The temporary harness was removed after verification.
