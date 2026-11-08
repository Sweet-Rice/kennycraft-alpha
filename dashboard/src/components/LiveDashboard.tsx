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
  activityTitles,
  observeSnapshot,
  parseSnapshot,
  type LedgerEntry,
  type Observation,
} from "@/lib/snapshot";

function useBackendStream() {
  const [view, setView] = useState<Observation | null>(null);
  const [status, setStatus] = useState("Connecting");
  const [error, setError] = useState<string | null>(null);
  useEffect(() => {
    let source: EventSource | null = null;
    let reconnect: number | undefined;
    function connect() {
      window.clearTimeout(reconnect);
      source?.close();
      if (document.hidden) {
        setStatus("Paused");
        return;
      }
      setStatus("Connecting");
      source = new EventSource("/api/events");
      source.onmessage = (event) => {
        try {
          const data = parseSnapshot(event.data);
          const at = Date.now();
          setView((previous) => observeSnapshot(previous, data, at));
          setStatus("Live stream");
          setError(null);
        } catch {
          setStatus("Connection error");
          setError("Invalid backend snapshot");
        }
      };
      // Explicit reconnect also covers HTTP 502, which can permanently close native EventSource.
      source.onerror = () => {
        source?.close();
        setStatus("Connection error");
        setError("Backend connection lost");
        reconnect = window.setTimeout(connect, 3000);
      };
    }
    document.addEventListener("visibilitychange", connect);
    connect();
    return () => {
      window.clearTimeout(reconnect);
      source?.close();
      document.removeEventListener("visibilitychange", connect);
    };
  }, []);
  return { view, status, error };
}
const money = new Intl.NumberFormat("en-US", {
  style: "currency",
  currency: "USD",
});
function ActivityRow({ entry, fresh }: { entry: LedgerEntry; fresh: boolean }) {
  return (
    <li className={`activity-row ${fresh ? "new-event" : ""}`}>
      <div className="flex flex-wrap items-center justify-between gap-2">
        <h3 className="font-medium">
          {Object.hasOwn(activityTitles, entry.kind)
            ? activityTitles[entry.kind]
            : entry.kind}
        </h3>
        <span
          className={`badge ${entry.status === "settled" ? "text-emerald-300" : "text-amber-200"}`}
        >
          {entry.status}
        </span>
      </div>
      <div className="mt-3 flex flex-wrap gap-x-5 gap-y-1 font-mono text-sm">
        <span className="text-rose-300">
          {entry.from_wallet} <strong>−{entry.amount} KCN</strong>
        </span>
        <span className="text-emerald-300">
          {entry.to_wallet} <strong>+{entry.amount} KCN</strong>
        </span>
      </div>
      <div className="mt-3 flex flex-wrap items-center justify-between gap-2 text-xs text-slate-500">
        <span>
          Ledger e{entry.id}
          {entry.contract_id !== null
            ? ` · contract #${entry.contract_id}`
            : ""}
        </span>
        {entry.sig && (
          <a
            href={`https://explorer.solana.com/tx/${encodeURIComponent(entry.sig)}?cluster=devnet`}
            target="_blank"
            rel="noreferrer"
          >
            View transaction ↗
          </a>
        )}
      </div>
    </li>
  );
}
function SessionChart({ points }: { points: Observation["points"] }) {
  return (
    <section className="panel min-w-0" aria-label="Session balance chart">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <h2 className="eyebrow">Balance observed this session</h2>
        <span className="text-xs text-slate-500">KCN · ledger</span>
      </div>
      <div className="mt-4 h-[190px] w-full">
        <ResponsiveContainer width="100%" height="100%" minWidth={0}>
          <LineChart
            data={points}
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
              labelFormatter={(v) => new Date(Number(v)).toLocaleTimeString()}
              contentStyle={{
                background: "#0f172a",
                border: "1px solid #334155",
                borderRadius: 8,
              }}
              formatter={(v) => [`${v} KCN`, "Observed balance"]}
            />
            <Line
              type="stepAfter"
              dataKey="balance"
              stroke="#6ee7b7"
              strokeWidth={2}
              dot={points.length === 1 ? { r: 4 } : false}
              isAnimationActive={false}
            />
          </LineChart>
        </ResponsiveContainer>
      </div>
      <p className="mt-2 text-xs text-slate-500">
        Latest 120 backend snapshots; not historical chain data.
      </p>
    </section>
  );
}
export default function LiveDashboard() {
  const { view, status, error } = useBackendStream();
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    const clock = window.setInterval(() => setNow(Date.now()), 1000);
    return () => window.clearInterval(clock);
  }, []);
  const data = view?.data;
  const live = status === "Live stream";
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
            Backend ledger · Solana devnet settlement{" "}
            <span className="mx-2 text-slate-700">/</span> No funds moved by
            this display.
          </p>
        </div>
        <div className="text-right text-xs text-slate-400">
          <span
            className={`badge ${live ? "text-emerald-300 border-emerald-800" : "text-slate-400"}`}
          >
            <span
              className={`h-1.5 w-1.5 rounded-full ${live ? "bg-emerald-400" : "bg-slate-500"}`}
            />
            {status}
          </span>
          {view && (
            <>
              <p className="mt-2">
                Last backend update{" "}
                {Math.max(0, Math.floor((now - view.at) / 1000))}s ago
              </p>
              <time className="mt-1 block">
                {new Date(view.at).toLocaleString()}
              </time>
            </>
          )}
        </div>
      </header>
      {error && (
        <div
          role="alert"
          className="mb-6 rounded-xl border border-rose-800/60 bg-rose-950/30 p-4 text-sm text-rose-200"
        >
          {error} —{" "}
          {view
            ? "showing last successful balances"
            : "waiting for the first valid snapshot"}
          .
          <p className="mt-2 text-xs">
            {view
              ? `Last backend update: ${new Date(view.at).toLocaleString()}`
              : "Start the existing kc-host backend on this machine at port 8000. The dashboard reconnects automatically."}
          </p>
        </div>
      )}
      {!data && !error && (
        <section className="panel mb-6" role="status">
          Connecting to the local KennyCraft backend…
        </section>
      )}
      {data && view && (
        <>
          <div className="mb-5 grid gap-5 lg:grid-cols-[1.1fr_1fr]">
            <section className="panel hero relative overflow-hidden">
              <div className="eyebrow text-emerald-300">
                Player balance · game ledger
              </div>
              <div className="my-5 flex flex-wrap items-baseline gap-3">
                <strong
                  id="player-balance"
                  className="break-all font-mono text-5xl font-medium tracking-tighter sm:text-6xl"
                >
                  {data.wallets.player}
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
                ≈ {money.format(data.wallets.player / 10)}{" "}
                <span className="text-sm text-slate-400">
                  game-bank equivalent
                </span>
              </p>
              <p className="mt-2 font-mono text-xs text-slate-500">
                $1 = 10 KCN
              </p>
              <p className="mt-6 text-xs text-amber-200/80">
                Devnet / mock-bank equivalent — not real funds
              </p>
            </section>
            <SessionChart points={view.points} />
          </div>
          <section className="panel mb-5">
            <div className="flex flex-wrap items-center justify-between gap-3">
              <h2 className="section-title">Settlement</h2>
              <div className="flex gap-2">
                <span
                  className={`badge ${data.mode === "ONLINE" ? "text-emerald-300" : "text-amber-200"}`}
                >
                  {data.mode}
                </span>
                <span className="badge text-slate-300">
                  {data.queued} queued
                </span>
              </div>
            </div>
            <p className="mt-3 text-sm text-slate-400">
              Balances include queued game-ledger entries. They are not
              independently verified on-chain balances. Entry status comes from
              the existing backend settler.
            </p>
          </section>
          <div className="mb-5 grid items-start gap-5 lg:grid-cols-[1.4fr_1fr]">
            <section className="panel">
              <h2 className="section-title">Economy wallets</h2>
              <table className="mt-4 w-full text-left text-sm">
                <thead className="text-xs uppercase tracking-wider text-slate-500">
                  <tr>
                    <th className="pb-3 font-normal">Role</th>
                    <th className="pb-3 text-right font-normal">Ledger KCN</th>
                  </tr>
                </thead>
                <tbody>
                  {Object.entries(data.wallets).map(([role, balance]) => (
                    <tr key={role} className="border-t border-slate-800/80">
                      <th className="py-3 pr-4 font-medium capitalize">
                        {role}
                      </th>
                      <td className="py-3 text-right font-mono">{balance}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </section>
            <section className="panel">
              <h2 className="section-title">Nessie mock bank</h2>
              <p className="mt-4 text-sm text-slate-400">
                Available mock dollars · reported by kc-host
              </p>
              {data.usd !== null ? (
                <p className="mt-2 font-mono text-3xl">
                  {money.format(data.usd / 100)}
                </p>
              ) : (
                <p className="mt-3 text-sm text-amber-200">
                  Bank unavailable — the backend has no current available
                  balance.
                </p>
              )}
              <p className="mt-4 text-xs text-slate-500">
                Nessie credentials stay with the existing backend. This is the
                available balance, not an invented account total.
              </p>
              {Object.hasOwn(data.wallets, "escrow") && (
                <div className="mt-6 border-t border-slate-800 pt-4">
                  <h3 className="eyebrow">Escrow · ledger</h3>
                  <p className="mt-2 font-mono text-xl">
                    {data.wallets.escrow} KCN
                  </p>
                </div>
              )}
            </section>
          </div>
          <section className="panel min-w-0">
            <div className="flex flex-wrap items-center justify-between gap-3">
              <h2 className="section-title">Recent backend activity</h2>
              <span className="badge text-slate-400">Live event stream</span>
            </div>
            <p className="mt-2 text-xs text-slate-500">
              Backend ledger entries, newest first. Queued does not mean
              settled; labels are supplied by the backend, not inferred from
              token movements.
            </p>
            <ul className="mt-3">
              {data.ledger.map((entry) => (
                <ActivityRow
                  key={entry.id}
                  entry={entry}
                  fresh={
                    view.highlights[entry.id] !== undefined &&
                    now - view.highlights[entry.id] < 5000
                  }
                />
              ))}
            </ul>
            {!data.ledger.length && (
              <p className="py-7 text-sm text-slate-400">
                No recent backend ledger entries
              </p>
            )}
          </section>
        </>
      )}
      <footer className="mt-8 flex flex-wrap justify-between gap-2 border-t border-slate-800 pt-4 text-xs text-slate-600">
        <span>KennyCoin / existing KennyCraft economy</span>
        <span>Read-only judge display · local access only</span>
      </footer>
    </main>
  );
}
