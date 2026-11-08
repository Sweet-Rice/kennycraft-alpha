export type Role =
  "player" | "banker" | "treasury" | "escrow" | "worker" | "other";
export interface TrackedWallet {
  label: string;
  address: string;
  role: Role;
}
export interface ResolvedWallet extends TrackedWallet {
  tokenAccounts: string[];
}
export interface Delta {
  owner: string;
  label: string;
  role: Role;
  raw: bigint;
}
export type EventKind =
  | "mint"
  | "burn"
  | "bank_buy"
  | "bank_sell"
  | "escrow_fund"
  | "escrow_release"
  | "escrow_refund"
  | "fee"
  | "trade_buy"
  | "trade_sell"
  | "transfer"
  | "failed";
export interface KcnEvent {
  signature: string;
  slot: number;
  blockTime: number | null;
  kind: EventKind;
  title: string;
  deltas: { label: string; role: Role; amount: string }[];
  memo: string | null;
  failed: boolean;
  explorerUrl: string;
}
export interface KcnState {
  cluster: "devnet";
  slot: number;
  symbol: "KCN";
  kcnPerUsd: number;
  mint: {
    address: string;
    decimals: number;
    supply: string;
    explorerUrl: string;
  };
  wallets: (ResolvedWallet & { balance: string; explorerUrl: string })[];
  player: { balance: string; usd: number };
  events: KcnEvent[];
  activityFetchedAt: string | null;
  warnings: string[];
  fetchedAt: string;
}
export class ConfigError extends Error {
  constructor(public missing: string[]) {
    super("KCN configuration required");
  }
}
const roles: Record<string, Role> = {
  player: "player",
  banker: "banker",
  treasury: "treasury",
  escrow: "escrow",
  builder: "worker",
  miner: "worker",
  farmer: "worker",
};
export function parseWallets(
  raw: string,
  isValid: (a: string) => boolean,
): { wallets: TrackedWallet[]; warnings: string[] } {
  const wallets: TrackedWallet[] = [],
    errors: string[] = [];
  const labels = new Set<string>(),
    addresses = new Set<string>();
  for (const pair of raw.split(",")) {
    if (!pair.trim()) continue;
    const [labelPart, ...parts] = pair.split("=");
    const label = labelPart.trim().toLowerCase(),
      addr = parts.join("=").trim();
    if (!Object.hasOwn(roles, label)) {
      errors.push(`Unknown wallet label: ${label}`);
      continue;
    }
    if (labels.has(label)) errors.push(`Duplicate wallet label: ${label}`);
    labels.add(label);
    if (!addr) continue;
    if (!isValid(addr)) {
      errors.push(`Invalid address for ${label}`);
      continue;
    }
    if (addresses.has(addr)) errors.push(`Duplicate wallet address: ${label}`);
    addresses.add(addr);
    wallets.push({ label, address: addr, role: roles[label] });
  }
  if (!wallets.some((w) => w.role === "player"))
    errors.push("KCN_WALLETS (player=<address>)");
  if (errors.length) throw new ConfigError(errors);
  return { wallets, warnings: [] };
}
export function formatUnits(raw: bigint, decimals: number): string {
  const sign = raw < 0n ? "-" : "",
    absolute = raw < 0n ? -raw : raw;
  const scale = 10n ** BigInt(decimals);
  const fraction = (absolute % scale)
    .toString()
    .padStart(decimals, "0")
    .replace(/0+$/, "");
  return `${sign}${absolute / scale}${fraction ? `.${fraction}` : ""}`;
}
export interface TokenBalance {
  accountIndex: number;
  mint: string;
  owner?: string;
  uiTokenAmount: { amount: string; decimals: number };
}
// A missing array is not evidence of a mint or burn. The caller surfaces this as an activity warning.
export function tokenDeltas(
  pre: readonly TokenBalance[] | null | undefined,
  post: readonly TokenBalance[] | null | undefined,
  accountKeys: string[],
  mint: string,
  wallets: ResolvedWallet[],
): Delta[] {
  if (!pre || !post) throw new Error("Missing token balance metadata");
  const before = new Map(
    pre.filter((b) => b.mint === mint).map((b) => [b.accountIndex, b]),
  );
  const after = new Map(
    post.filter((b) => b.mint === mint).map((b) => [b.accountIndex, b]),
  );
  const sums = new Map<string, Delta>();
  for (const index of new Set([...before.keys(), ...after.keys()])) {
    const a = before.get(index),
      b = after.get(index);
    const tokenAccount = accountKeys[index] ?? "Unknown account";
    const owner = b?.owner ?? a?.owner ?? tokenAccount;
    const wallet =
      wallets.find((w) => w.tokenAccounts.includes(tokenAccount)) ??
      wallets.find((w) => w.address === owner);
    const label = wallet?.label ?? shorten(owner),
      role = wallet?.role ?? "other";
    // Group untracked owners by their full address, not their potentially colliding display abbreviation.
    const key = wallet ? `tracked:${wallet.label}` : `owner:${owner}`;
    const raw =
      BigInt(b?.uiTokenAmount.amount ?? "0") -
      BigInt(a?.uiTokenAmount.amount ?? "0");
    const existing = sums.get(key);
    if (existing) existing.raw += raw;
    else sums.set(key, { owner, label, role, raw });
  }
  return [...sums.values()]
    .filter((d) => d.raw !== 0n)
    .sort((a, b) => (a.raw < b.raw ? -1 : a.raw > b.raw ? 1 : 0));
}
// kc-host's settler writes "KC#<contract> <kind> e<entry>" (or "KC <kind> e<entry>") as the
// memo of every transfer, so the bank's own label beats inferring one from wallet roles.
const MEMO_KINDS: Record<string, [EventKind, string]> = {
  exchange_in: ["bank_buy", "Banker: dollars → KCN"],
  exchange_out: ["bank_sell", "Banker: KCN → dollars"],
  fund: ["escrow_fund", "Contract funded into escrow"],
  release: ["escrow_release", "Escrow paid the contractor"],
  fee: ["fee", "Contract fee to the treasury"],
  refund: ["escrow_refund", "Escrow refunded the player"],
  trade_buy: ["trade_buy", "Bought materials from the trader"],
  trade_sell: ["trade_sell", "Sold materials to the trader"],
};
export function memoKind(
  memo: string | null | undefined,
): { kind: EventKind; title: string } | null {
  const m = memo?.match(/\bKC(?:#(\d+))? ([a-z_]+) e\d+/);
  const known = m && MEMO_KINDS[m[2]];
  if (!known) return null;
  return {
    kind: known[0],
    title: m[1] ? `${known[1]} (contract #${m[1]})` : known[1],
  };
}
export function classify(
  deltas: Delta[],
  decimals: number,
  memo?: string | null,
): { kind: EventKind; title: string } {
  const fromMemo = memoKind(memo);
  if (fromMemo) return fromMemo;
  const nonzero = deltas.filter((d) => d.raw !== 0n);
  const total = nonzero.reduce((sum, d) => sum + d.raw, 0n);
  if (total > 0n && nonzero.every((d) => d.raw > 0n))
    return {
      kind: "mint",
      title: `Minted ${formatUnits(total, decimals)} KCN`,
    };
  if (total < 0n && nonzero.every((d) => d.raw < 0n))
    return {
      kind: "burn",
      title: `Burned ${formatUnits(-total, decimals)} KCN`,
    };
  if (nonzero.length === 2 && total === 0n) {
    const from = nonzero.find((d) => d.raw < 0n)!,
      to = nonzero.find((d) => d.raw > 0n)!;
    const movements: Record<string, EventKind> = {
      "banker:player": "bank_buy",
      "player:banker": "bank_sell",
      "treasury:player": "bank_buy",
      "player:treasury": "bank_sell",
      "escrow:treasury": "fee",
      "player:escrow": "escrow_fund",
      "escrow:worker": "escrow_release",
      "escrow:player": "escrow_refund",
    };
    const kind = movements[`${from.role}:${to.role}`];
    if (kind)
      return {
        kind,
        title: `${from.label.charAt(0).toUpperCase() + from.label.slice(1)} → ${to.label}`,
      };
  }
  return { kind: "transfer", title: "KCN movement" };
}
export function shorten(value: string): string {
  return value.length > 14 ? `${value.slice(0, 5)}…${value.slice(-5)}` : value;
}
export function explorerTx(sig: string, cluster: "devnet"): string {
  return `https://explorer.solana.com/tx/${encodeURIComponent(sig)}?cluster=${cluster}`;
}
export function explorerAddress(addr: string, cluster: "devnet"): string {
  return `https://explorer.solana.com/address/${encodeURIComponent(addr)}?cluster=${cluster}`;
}
export function appendObservation(
  points: { t: number; balance: number }[],
  next: { t: number; balance: number },
): { t: number; balance: number }[] {
  return [...points, next].slice(-120);
}
// Exact decimal-string subtraction for the transient UI change indicator; chart numbers never feed this path.
export function balanceChange(
  previous: string,
  next: string,
  decimals: number,
): string {
  const raw = (s: string) => {
    const [whole, fraction = ""] = s.split(".");
    return (
      BigInt(whole) * 10n ** BigInt(decimals) +
      BigInt(fraction.padEnd(decimals, "0") || "0")
    );
  };
  const difference = raw(next) - raw(previous);
  return `${difference > 0n ? "+" : ""}${formatUnits(difference, decimals)}`;
}
