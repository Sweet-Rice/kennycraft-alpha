import "server-only";
export interface BankState {
  configured: boolean;
  account?: { nickname: string; type: string; balance: number };
  recent?: {
    kind: "deposit" | "withdrawal";
    date: string | null;
    amount: number;
    description: string;
  }[];
  warnings?: string[];
}
interface NessieItem {
  transaction_date?: string;
  amount: number;
  description?: string;
}
export async function getBankState(): Promise<BankState> {
  const key = process.env.NESSIE_API_KEY,
    id = process.env.NESSIE_ACCOUNT_ID;
  if (!key || !id) return { configured: false };
  const base = `https://prod-api.nessieisreal.com/accounts/${encodeURIComponent(id)}`;
  const query = `?key=${encodeURIComponent(key)}`;
  const warnings: string[] = [];
  const [account, ...lists] = await Promise.all([
    fetch(`${base}${query}`, {
      cache: "no-store",
      signal: AbortSignal.timeout(12000),
    })
      .then(async (res) => {
        if (!res.ok) throw new Error("Nessie account unavailable");
        const data = await res.json();
        if (!Number.isFinite(data.balance))
          throw new Error("Nessie account unavailable");
        return {
          nickname: String(data.nickname ?? "Mock bank account"),
          type: String(data.type ?? "Account"),
          balance: data.balance as number,
        };
      })
      .catch(() => {
        throw new Error("Nessie account unavailable");
      }),
    ...(["deposits", "withdrawals"] as const).map(async (resource) => {
      try {
        const res = await fetch(`${base}/${resource}${query}`, {
          cache: "no-store",
          signal: AbortSignal.timeout(12000),
        });
        if (!res.ok) {
          warnings.push(`${resource} unavailable (status ${res.status})`);
          return [];
        }
        const items: NessieItem[] = await res.json();
        if (!Array.isArray(items)) {
          warnings.push(`${resource} unavailable (invalid response)`);
          return [];
        }
        return items
          .filter((item) => Number.isFinite(item.amount))
          .map((item) => ({
            kind:
              resource === "deposits"
                ? ("deposit" as const)
                : ("withdrawal" as const),
            date:
              item.transaction_date &&
              Number.isFinite(Date.parse(item.transaction_date))
                ? item.transaction_date
                : null,
            amount: item.amount,
            description: String(item.description ?? ""),
          }));
      } catch {
        warnings.push(`${resource} unavailable (network or response error)`);
        return [];
      }
    }),
  ]);
  const recent = lists
    .flat()
    .sort(
      (a, b) =>
        (b.date ? Date.parse(b.date) : -Infinity) -
        (a.date ? Date.parse(a.date) : -Infinity),
    )
    .slice(0, 10);
  return { configured: true, account, recent, warnings };
}
