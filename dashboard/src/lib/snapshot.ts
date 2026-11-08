// Fields consumed from host/kchost.py's GET /events stream. Balances are game-ledger KCN,
// including queued entries; usd is Nessie's available mock cents, or null on a bank read failure.
export interface LedgerEntry {
  id: number;
  kind: string;
  from_wallet: string;
  to_wallet: string;
  amount: number;
  contract_id: number | null;
  status: string;
  sig: string | null;
}
export interface Snapshot {
  mode: string;
  queued: number;
  usd: number | null;
  wallets: Record<string, number>;
  ledger: LedgerEntry[];
}
export interface Observation {
  data: Snapshot;
  at: number;
  points: { t: number; balance: number }[];
  newestEntry: number;
  highlights: Record<number, number>;
  change: { amount: string; at: number } | null;
}
export function parseSnapshot(raw: string): Snapshot {
  const data = JSON.parse(raw) as Snapshot;
  if (
    !data ||
    typeof data.mode !== "string" ||
    !Number.isSafeInteger(data.queued) ||
    (data.usd !== null && !Number.isSafeInteger(data.usd)) ||
    !data.wallets ||
    !Object.hasOwn(data.wallets, "player") ||
    !Object.values(data.wallets).every(Number.isSafeInteger) ||
    !Array.isArray(data.ledger) ||
    !data.ledger.every(
      (entry) =>
        entry &&
        Number.isSafeInteger(entry.id) &&
        Number.isSafeInteger(entry.amount) &&
        typeof entry.kind === "string" &&
        typeof entry.status === "string" &&
        typeof entry.from_wallet === "string" &&
        typeof entry.to_wallet === "string" &&
        (entry.contract_id === null ||
          Number.isSafeInteger(entry.contract_id)) &&
        (entry.sig === null || typeof entry.sig === "string"),
    )
  )
    throw new Error("Invalid backend snapshot");
  // Reject unsafe JSON integers rather than silently rounding money. kc-host currently uses whole KCN.
  return data;
}
export function observeSnapshot(
  previous: Observation | null,
  data: Snapshot,
  at: number,
): Observation {
  const highlights: Record<number, number> = {};
  for (const entry of data.ledger) {
    const firstSeen = previous?.highlights[entry.id];
    if (firstSeen !== undefined && at - firstSeen < 5000)
      highlights[entry.id] = firstSeen;
    else if (previous && entry.id > previous.newestEntry)
      highlights[entry.id] = at;
  }
  const difference = previous
    ? BigInt(data.wallets.player) - BigInt(previous.data.wallets.player)
    : 0n;
  return {
    data,
    at,
    highlights,
    newestEntry: Math.max(
      previous?.newestEntry ?? 0,
      ...data.ledger.map((entry) => entry.id),
    ),
    points: [
      ...(previous?.points ?? []),
      { t: at, balance: data.wallets.player },
    ].slice(-120),
    change:
      difference !== 0n
        ? { amount: `${difference > 0n ? "+" : ""}${difference}`, at }
        : (previous?.change ?? null),
  };
}
export const activityTitles: Record<string, string> = {
  exchange_in: "Banker: dollars → KCN",
  exchange_out: "Banker: KCN → dollars",
  fund: "Escrow funded",
  release: "Escrow paid contractor",
  fee: "Fee to treasury",
  refund: "Escrow refund",
  trade_buy: "Bought materials",
  trade_sell: "Sold materials",
};
