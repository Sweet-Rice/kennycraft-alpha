import "server-only";
export interface BankState {
  configured: boolean;
  account?: {
    nickname: string;
    type: string;
    balance: number;
    available: number;
  };
  recent?: {
    kind: "deposit" | "withdrawal";
    date: string | null;
    amount: number;
    description: string;
  }[];
  warnings?: string[];
}
interface NessieTransaction {
  kind?: string;
  amount_cents?: number;
  status?: string;
  description?: string;
  created_at?: string;
}
// Nessie v2: Bearer auth (keys start with nsk_), integer cents, one transactions list.
// The v1 host (prod-api.nessieisreal.com, ?key=) rejects v2 keys.
const BASE = "https://v2-prod-api.nessieisreal.com";
async function get(path: string, key: string) {
  const res = await fetch(`${BASE}${path}`, {
    cache: "no-store",
    headers: { Authorization: `Bearer ${key}` },
    signal: AbortSignal.timeout(12000),
  });
  if (!res.ok) throw new Error(`status ${res.status}`);
  return res.json();
}
export async function getBankState(): Promise<BankState> {
  const key = process.env.NESSIE_API_KEY,
    id = process.env.NESSIE_ACCOUNT_ID;
  if (!key || !id) return { configured: false };
  const path = `/accounts/${encodeURIComponent(id)}`;
  const [account, transactions] = await Promise.all([
    get(path, key).catch(() => {
      throw new Error("Nessie account unavailable");
    }),
    get(`${path}/transactions?limit=20`, key).then(
      (body) => ({ items: body?.items as NessieTransaction[] | undefined }),
      (error: Error) => ({ error: error.message }),
    ),
  ]);
  if (
    !Number.isFinite(account.balance_cents) ||
    !Number.isFinite(account.available_cents)
  )
    throw new Error("Nessie account unavailable");
  const warnings: string[] = [];
  let recent: BankState["recent"] = [];
  if ("error" in transactions)
    warnings.push(`transactions unavailable (${transactions.error})`);
  else if (!Array.isArray(transactions.items))
    warnings.push("transactions unavailable (invalid response)");
  else
    recent = transactions.items
      .filter(
        (t) =>
          (t.kind === "deposit" || t.kind === "withdrawal") &&
          Number.isFinite(t.amount_cents),
      )
      .map((t) => ({
        kind: t.kind as "deposit" | "withdrawal",
        date:
          t.created_at && Number.isFinite(Date.parse(t.created_at))
            ? t.created_at
            : null,
        amount: t.amount_cents! / 100,
        description: `${String(t.description ?? "")}${t.status === "pending" ? " (pending)" : ""}`,
      }))
      .sort(
        (a, b) =>
          (b.date ? Date.parse(b.date) : -Infinity) -
          (a.date ? Date.parse(a.date) : -Infinity),
      )
      .slice(0, 10);
  return {
    configured: true,
    account: {
      nickname: String(account.nickname ?? "Checking"),
      type: String(account.type ?? "Account"),
      balance: account.balance_cents / 100,
      available: account.available_cents / 100,
    },
    recent,
    warnings,
  };
}
