"use client";

import { useEffect, useState } from "react";
import {
  CartesianGrid,
  Line,
  LineChart,
  ResponsiveContainer,
  Tooltip,
  XAxis,
  YAxis,
} from "recharts";
import {
  appendObservation,
  balanceChange,
  memoKind,
  shorten,
  type KcnEvent,
  type KcnState,
} from "@/lib/kcn";
import type { BankState } from "@/lib/nessie";

interface PollError {
  missing?: string[];
}
// Completion-based timers prevent slow RPC requests from overlapping. Visibility cancels work.
function usePolling<T, S>(
  url: string,
  delay: number,
  apply: (previous: S | null, data: T) => S,
) {
  const [state, setState] = useState<S | null>(null);
  const [error, setError] = useState<PollError | null>(null);
  const [paused, setPaused] = useState(false);
  useEffect(() => {
    let disposed = false,
      inFlight = false,
      rerun = false;
    let timer: ReturnType<typeof setTimeout> | undefined;
    let controller: AbortController | undefined;
    async function poll() {
      if (disposed || document.hidden) return;
      if (inFlight) {
        rerun = true;
        return;
      }
      inFlight = true;
      controller = new AbortController();
      try {
        const response = await fetch(url, {
          cache: "no-store",
          signal: AbortSignal.any([
            controller.signal,
            AbortSignal.timeout(20000),
          ]),
        });
        const payload = await response.json();
        if (disposed || controller.signal.aborted) return;
        if (!response.ok) {
          setError({
            missing: payload.error === "config" ? payload.missing : undefined,
          });
          return;
        }
        setState((previous) => apply(previous, payload));
        setError(null);
      } catch {
        if (!disposed && !controller.signal.aborted) setError({});
      } finally {
        inFlight = false;
        if (!disposed && !document.hidden) {
          if (rerun) {
            rerun = false;
            void poll();
          } else timer = setTimeout(poll, delay);
        }
      }
    }
    function visibility() {
      clearTimeout(timer);
      setPaused(document.hidden);
      if (document.hidden) controller?.abort();
      else void poll();
    }
    document.addEventListener("visibilitychange", visibility);
    visibility();
    return () => {
      disposed = true;
      clearTimeout(timer);
      controller?.abort();
      document.removeEventListener("visibilitychange", visibility);
    };
  }, [url, delay, apply]);
  return { state, error, paused };
}
interface KcnView {
  data: KcnState;
  identity: string;
  points: { t: number; balance: number }[];
  seen: Set<string>;
  activityLoaded: boolean;
  highlights: Record<string, number>;
  change: { amount: string; at: number } | null;
}
function observeKcn(previous: KcnView | null, data: KcnState): KcnView {
  const identity = `${data.mint.address}:${data.wallets.find((w) => w.role === "player")?.address}`;
  const old = previous?.identity === identity ? previous : null;
  const now = Date.now(),
    seen = new Set(old?.seen),
    highlights = { ...old?.highlights };
  for (const event of data.events) {
    if (old?.activityLoaded && !seen.has(event.signature))
      highlights[event.signature] = now;
    seen.add(event.signature);
  }
  for (const [signature, at] of Object.entries(highlights))
    if (now - at > 5000) delete highlights[signature];
  const changed = old && data.player.balance !== old.data.player.balance;
  return {
    data,
    identity,
    seen,
    highlights,
    activityLoaded: Boolean(old?.activityLoaded || data.activityFetchedAt),
    points: appendObservation(old?.points ?? [], {
      t: now,
      balance: Number(data.player.balance),
    }),
    change: changed
      ? {
          amount: balanceChange(
            old.data.player.balance,
            data.player.balance,
            data.mint.decimals,
          ),
          at: now,
        }
      : (old?.change ?? null),
  };
}
interface BankView {
  data: BankState;
  at: string;
}
function observeBank(_previous: BankView | null, data: BankState): BankView {
  return { data, at: new Date().toISOString() };
}
const money = new Intl.NumberFormat("en-US", {
  style: "currency",
  currency: "USD",
});
function timestamp(value: string | number | null): string {
  if (value === null) return "Time unavailable";
  return new Date(
    typeof value === "number" ? value * 1000 : value,
  ).toLocaleString();
}
function ActivityRow({ event, fresh }: { event: KcnEvent; fresh: boolean }) {
  const inferred = [
    "bank_buy",
    "bank_sell",
    "escrow_fund",
    "escrow_release",
    "escrow_refund",
    "fee",
    "trade_buy",
    "trade_sell",
  ].includes(event.kind);
  return (
    <li className={`activity-row ${fresh ? "new-event" : ""}`}>
      <div className="flex flex-wrap items-center justify-between gap-2">
        <h3
          className={event.failed ? "text-rose-300 font-medium" : "font-medium"}
        >
          {event.title}
        </h3>
        <span
          className={`badge ${event.failed ? "text-rose-300" : "text-slate-400"}`}
        >
          {event.failed ? "Failed · confirmed" : "Confirmed"}
        </span>
      </div>
      {inferred && !memoKind(event.memo) && (
        <p className="mt-1 text-xs text-amber-200/80">
          Inferred from configured wallet roles
        </p>
      )}
      <div className="mt-3 flex flex-wrap gap-x-5 gap-y-1 font-mono text-sm">
        {event.deltas.map((d, index) => (
          <span
            key={`${d.label}:${index}`}
            className={
              d.amount.startsWith("-") ? "text-rose-300" : "text-emerald-300"
            }
          >
            {d.label}{" "}
            <strong>
              {d.amount.startsWith("-") ? "" : "+"}
              {d.amount} KCN
            </strong>
          </span>
        ))}
      </div>
      {event.memo && (
        <p className="mt-2 break-words text-sm text-slate-400">
          Memo: {event.memo}
        </p>
      )}
      <div className="mt-3 flex flex-wrap items-center justify-between gap-2 text-xs text-slate-500">
        <time>{timestamp(event.blockTime)}</time>
        <a href={event.explorerUrl} target="_blank" rel="noreferrer">
          {shorten(event.signature)} ↗
        </a>
      </div>
    </li>
  );
}
export default function LiveDashboard() {
  const kcn = usePolling<KcnState, KcnView>("/api/kcn", 5000, observeKcn);
  const bank = usePolling<BankState, BankView>("/api/bank", 15000, observeBank);
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    const timer = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(timer);
  }, []);
  const view = kcn.state,
    data = view?.data;
  const escrow = data?.wallets.find((w) => w.role === "escrow");
  const activityUnavailable = data?.warnings.includes(
    "Recent activity unavailable",
  );
  const b = bank.state?.data;
  return (
    <main className="mx-auto max-w-[1440px] px-5 py-7 sm:px-10 lg:py-10">
      <header className="mb-7 flex flex-wrap items-start justify-between gap-5 border-b border-slate-800 pb-6">
        <div>
          <div className="eyebrow mb-2">
            KennyCraft economy / read-only observer
          </div>
          <h1 className="text-2xl font-semibold tracking-tight sm:text-3xl">
            KennyCraft <span className="text-slate-600">·</span> KCN Live
          </h1>
          <p className="mt-2 text-sm text-slate-400">
            Solana devnet · confirmed{" "}
            <span className="mx-2 text-slate-700">/</span> No signing. No funds
            moved.
          </p>
        </div>
        <div className="text-right text-xs text-slate-400">
          <span
            className={`badge ${data && !kcn.error && !kcn.paused ? "text-emerald-300 border-emerald-800" : "text-slate-400"}`}
          >
            <span
              className={`h-1.5 w-1.5 rounded-full ${data && !kcn.error && !kcn.paused ? "bg-emerald-400" : "bg-slate-500"}`}
            />
            {kcn.error
              ? "Connection error"
              : kcn.paused
                ? "Paused"
                : data
                  ? "Live reads"
                  : "Connecting"}
          </span>
          {data && (
            <>
              <p className="mt-2 font-mono">
                Slot {data.slot.toLocaleString()}
              </p>
              <p className="mt-1">
                Last success{" "}
                {Math.max(
                  0,
                  Math.floor((now - Date.parse(data.fetchedAt)) / 1000),
                )}
                s ago
              </p>
              <time className="mt-1 block">{timestamp(data.fetchedAt)}</time>
            </>
          )}
        </div>
      </header>
      {kcn.error?.missing && (
        <section className="panel mb-6 border-amber-800/60" role="alert">
          <div className="eyebrow text-amber-300">
            Public addresses required
          </div>
          <h2 className="mt-2 text-xl">Connect the existing KCN economy</h2>
          <p className="mt-3 text-slate-400">
            Set these in <code>.env.local</code> and restart the server.
          </p>
          <ul className="mt-4 space-y-2 font-mono text-sm text-amber-200">
            {kcn.error.missing.map((field) => (
              <li key={field}>{field}</li>
            ))}
          </ul>
          <p className="mt-4 text-sm text-slate-500">
            Use the existing devnet mint and player owner or token-account
            address. Never enter private keys.
          </p>
        </section>
      )}
      {kcn.error && !kcn.error.missing && (
        <div
          role="alert"
          className="mb-6 rounded-xl border border-rose-800/60 bg-rose-950/30 p-4 text-sm text-rose-200"
        >
          {data
            ? "Connection error — showing last successful balances"
            : "Unable to connect to Solana devnet — retrying every 5 seconds. No balances available yet."}
          {data && (
            <span className="mt-1 block text-xs text-rose-300">
              Last success: {timestamp(data.fetchedAt)}
            </span>
          )}
        </div>
      )}
      {!data && !kcn.error && (
        <section className="panel mb-6" role="status">
          Reading confirmed KCN balances…
        </section>
      )}
      {data && view && (
        <>
          <div className="mb-5 grid gap-5 lg:grid-cols-[1.1fr_1fr]">
            <section className="panel hero relative overflow-hidden">
              <div className="eyebrow text-emerald-300">Player balance</div>
              <div className="my-5 flex flex-wrap items-baseline gap-3">
                <strong
                  id="player-balance"
                  className="break-all font-mono text-5xl font-medium tracking-tighter sm:text-6xl"
                >
                  {data.player.balance}
                </strong>
                <span className="font-mono text-xl text-emerald-300">KCN</span>
                {view.change && now - view.change.at < 3000 && (
                  <span
                    role="status"
                    className={`font-mono ${view.change.amount.startsWith("-") ? "text-rose-300" : "text-emerald-300"}`}
                  >
                    {view.change.amount} KCN
                  </span>
                )}
              </div>
              <p className="text-xl text-slate-200">
                ≈ {money.format(data.player.usd)}{" "}
                <span className="text-sm text-slate-400">
                  game-bank equivalent
                </span>
              </p>
              <p className="mt-2 font-mono text-xs text-slate-500">
                $1 = {data.kcnPerUsd} KCN
              </p>
              <p className="mt-6 text-xs text-amber-200/80">
                Devnet / mock-bank equivalent — not real funds
              </p>
            </section>
            <section
              className="panel min-w-0"
              aria-label="Session balance chart"
            >
              <div className="flex flex-wrap items-center justify-between gap-2">
                <h2 className="eyebrow">Balance observed this session</h2>
                <span className="text-xs text-slate-500">
                  KCN · approximate geometry
                </span>
              </div>
              <div className="mt-4 h-[190px] w-full">
                <ResponsiveContainer width="100%" height="100%" minWidth={0}>
                  <LineChart
                    data={view.points}
                    margin={{ top: 10, right: 8, left: -25, bottom: 0 }}
                  >
                    <CartesianGrid stroke="#1e293b" vertical={false} />
                    <XAxis
                      dataKey="t"
                      type="number"
                      domain={["dataMin", "dataMax"]}
                      tickFormatter={(v) =>
                        new Date(v).toLocaleTimeString([], {
                          hour: "2-digit",
                          minute: "2-digit",
                          second: "2-digit",
                        })
                      }
                      stroke="#64748b"
                      tick={{ fontSize: 10 }}
                      minTickGap={50}
                    />
                    <YAxis
                      stroke="#64748b"
                      tick={{ fontSize: 10 }}
                      domain={[0, "auto"]}
                    />
                    <Tooltip
                      labelFormatter={(v) =>
                        new Date(Number(v)).toLocaleTimeString()
                      }
                      contentStyle={{
                        background: "#0f172a",
                        border: "1px solid #334155",
                        borderRadius: 8,
                      }}
                      formatter={(v) => [`≈ ${v} KCN`, "Observed balance"]}
                    />
                    <Line
                      type="stepAfter"
                      dataKey="balance"
                      stroke="#6ee7b7"
                      strokeWidth={2}
                      dot={view.points.length === 1 ? { r: 4 } : false}
                      isAnimationActive={false}
                    />
                  </LineChart>
                </ResponsiveContainer>
              </div>
              <p className="mt-2 text-xs text-slate-500">
                Session samples only; not reconstructed transaction history.
              </p>
            </section>
          </div>
          <div className="mb-7 flex flex-wrap justify-between gap-2 text-xs text-slate-500">
            <a
              href={data.mint.explorerUrl}
              title={data.mint.address}
              target="_blank"
              rel="noreferrer"
            >
              Mint {shorten(data.mint.address)} ↗
            </a>
            <span>
              Exact total supply{" "}
              <span className="font-mono text-slate-300">
                {data.mint.supply} KCN
              </span>
            </span>
            <span>Balance polls ~5s · confirmation adds about a second</span>
          </div>
          <section className="panel mb-5">
            <h2 className="section-title">Tracked wallets</h2>
            <div className="overflow-x-auto">
              <table className="mt-4 w-full text-left text-sm">
                <thead className="text-xs uppercase tracking-wider text-slate-500">
                  <tr>
                    <th className="pb-3 font-normal">Role</th>
                    <th className="pb-3 font-normal">Public address</th>
                    <th className="pb-3 text-right font-normal">Exact KCN</th>
                  </tr>
                </thead>
                <tbody>
                  {data.wallets.map((wallet) => (
                    <tr
                      key={wallet.label}
                      className="border-t border-slate-800/80"
                    >
                      <th className="py-4 pr-4 font-medium capitalize">
                        {wallet.label}
                      </th>
                      <td className="py-4">
                        <a
                          className="font-mono text-xs"
                          href={wallet.explorerUrl}
                          title={wallet.address}
                          target="_blank"
                          rel="noreferrer"
                        >
                          {shorten(wallet.address)} ↗
                        </a>
                      </td>
                      <td className="py-4 pl-4 text-right font-mono">
                        {wallet.balance}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </section>
          {escrow && (
            <section className="panel mb-5">
              <div className="flex flex-wrap items-center justify-between gap-3">
                <h2 className="section-title">Escrow movements</h2>
                <strong className="font-mono text-emerald-200">
                  {escrow.balance} KCN held
                </strong>
              </div>
              <p className="mt-2 text-xs text-slate-500">
                Wallet movements only; contract job status is not available from
                these balances.
              </p>
              <ul className="mt-3">
                {data.events
                  .filter((e) => e.kind.startsWith("escrow_"))
                  .map((e) => (
                    <ActivityRow
                      key={e.signature}
                      event={e}
                      fresh={Boolean(
                        view.highlights[e.signature] &&
                        now - view.highlights[e.signature] < 5000,
                      )}
                    />
                  ))}
              </ul>
              {!data.events.some((e) => e.kind.startsWith("escrow_")) && (
                <p className="mt-4 text-sm text-slate-400">
                  {activityUnavailable
                    ? "Recent escrow activity unavailable"
                    : "No recent inferred escrow movements found"}
                </p>
              )}
            </section>
          )}
          <div className="grid items-start gap-5 lg:grid-cols-[1.4fr_1fr]">
            <section className="panel min-w-0">
              <div className="flex flex-wrap items-center justify-between gap-3">
                <h2 className="section-title">Recent KCN activity</h2>
                <span className="badge text-slate-400">~15s refresh</span>
              </div>
              <p className="mt-2 text-xs text-slate-500">
                Activity read: {timestamp(data.activityFetchedAt)} · same-slot
                order is not guaranteed.
              </p>
              {data.warnings.map((warning) => (
                <p
                  key={warning}
                  className="mt-3 text-sm text-amber-200"
                  role="status"
                >
                  {warning}
                  {warning === "Recent activity unavailable" &&
                  data.activityFetchedAt
                    ? " — showing last successful activity"
                    : ""}
                </p>
              ))}
              <ul className="mt-3">
                {data.events.map((event) => (
                  <ActivityRow
                    key={event.signature}
                    event={event}
                    fresh={Boolean(
                      view.highlights[event.signature] &&
                      now - view.highlights[event.signature] < 5000,
                    )}
                  />
                ))}
              </ul>
              {!data.events.length && !activityUnavailable && (
                <p className="py-7 text-sm text-slate-400">
                  No recent KCN movements found
                </p>
              )}
              {!data.events.length && activityUnavailable && (
                <p className="py-7 text-sm text-slate-500">
                  Activity could not be read. This is not an empty history.
                </p>
              )}
            </section>
            <section className="panel min-w-0">
              <div className="flex flex-wrap items-center justify-between gap-3">
                <h2 className="section-title">Nessie mock bank</h2>
                <span className="badge text-slate-400">Optional</span>
              </div>
              {bank.error && (
                <p className="mt-4 text-sm text-amber-200" role="status">
                  {b?.account
                    ? "Bank connection error — showing last successful account"
                    : "Nessie account unavailable — retrying"}
                </p>
              )}
              {b?.configured && b.account ? (
                <>
                  <p className="mt-5 text-sm text-slate-400">
                    {b.account.nickname} · {b.account.type}
                  </p>
                  <p className="mt-2 font-mono text-3xl">
                    {money.format(b.account.balance)}
                  </p>
                  <p className="mt-2 text-xs text-slate-500">
                    {b.account.available !== b.account.balance &&
                      `${money.format(b.account.available)} available (withdrawals settle in ~1 min) · `}
                    Retrieved mock dollar balance · {timestamp(bank.state!.at)}
                  </p>
                  {b.warnings?.map((w) => (
                    <p key={w} className="mt-3 text-sm text-amber-200">
                      {w}
                    </p>
                  ))}
                  <ul className="mt-5">
                    {b.recent?.map((item, index) => (
                      <li
                        className="border-t border-slate-800 py-3 text-sm"
                        key={index}
                      >
                        <div className="flex justify-between gap-3">
                          <span className="capitalize">{item.kind}</span>
                          <span className="font-mono">
                            {money.format(item.amount)}
                          </span>
                        </div>
                        <p className="mt-1 break-words text-slate-400">
                          {item.description}
                        </p>
                        <time className="mt-1 block text-xs text-slate-500">
                          {timestamp(item.date)}
                        </time>
                      </li>
                    ))}
                  </ul>
                  {!b.recent?.length && (
                    <p className="mt-4 text-sm text-slate-500">
                      No retrieved deposits or withdrawals.
                    </p>
                  )}
                  <p className="mt-4 text-xs text-slate-500">
                    Dollar activity is not correlated with KCN transfers. No
                    shared backend settlement reference is available.
                  </p>
                </>
              ) : b && !b.configured ? (
                <>
                  <p className="mt-5 text-sm text-slate-400">
                    Not configured. To display the banker’s mock dollar account,
                    set:
                  </p>
                  <p className="mt-4 font-mono text-xs leading-7 text-slate-300">
                    NESSIE_API_KEY
                    <br />
                    NESSIE_ACCOUNT_ID
                  </p>
                  <p className="mt-4 text-xs text-slate-500">
                    Keys stay on the server. KCN balance reads do not require
                    Nessie.
                  </p>
                </>
              ) : (
                !bank.error && (
                  <p className="mt-5 text-sm text-slate-500">
                    Checking optional bank configuration…
                  </p>
                )
              )}
            </section>
          </div>
        </>
      )}
      <footer className="mt-8 flex flex-wrap justify-between gap-2 border-t border-slate-800 pt-4 text-xs text-slate-600">
        <span>KennyCoin / existing KennyCraft economy</span>
        <span>Read-only judge display · local access only</span>
      </footer>
    </main>
  );
}
