import "server-only";
import {
  address,
  createSolanaRpc,
  isAddress,
  type Address,
  type Rpc,
  type SolanaRpcApi,
  type TransactionVersion,
  type GetTransactionApiResponseJsonParsed,
} from "@solana/kit";
import {
  classify,
  ConfigError,
  explorerAddress,
  explorerTx,
  formatUnits,
  parseWallets,
  tokenDeltas,
  type KcnEvent,
  type KcnState,
  type ResolvedWallet,
  type TrackedWallet,
} from "./kcn";

interface ChainConfig {
  mint: Address;
  wallets: TrackedWallet[];
  rate: number;
  rpc: Rpc<SolanaRpcApi>;
}
type ParsedTransaction =
  GetTransactionApiResponseJsonParsed<void | TransactionVersion>;
function loadConfig(): ChainConfig {
  const errors: string[] = [];
  const mint = process.env.KCN_MINT?.trim() ?? "";
  if (!mint || !isAddress(mint)) errors.push("KCN_MINT");
  let wallets: TrackedWallet[] = [];
  try {
    wallets = parseWallets(process.env.KCN_WALLETS ?? "", isAddress).wallets;
  } catch (error) {
    if (error instanceof ConfigError) errors.push(...error.missing);
    else throw error;
  }
  if (process.env.SOLANA_CLUSTER && process.env.SOLANA_CLUSTER !== "devnet")
    errors.push("SOLANA_CLUSTER must be devnet");
  const rate = Number(process.env.KCN_PER_USD ?? 10);
  if (!Number.isFinite(rate) || rate <= 0)
    errors.push("KCN_PER_USD must be finite and positive");
  if (errors.length) throw new ConfigError(errors);
  return {
    mint: address(mint),
    wallets,
    rate,
    rpc: createSolanaRpc(
      process.env.SOLANA_RPC_URL || "https://api.devnet.solana.com",
    ),
  };
}
let config: ChainConfig | undefined;
// "confirmed" matches kc-host's settler; "finalized" showed payments ~13 s after they landed.
const commitment = "confirmed" as const;
const tokenPrograms: Record<string, true> = {
  TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA: true,
  TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb: true,
};

// Runtime checks are necessary: jsonParsed may still return binary data.
function readTokenData(data: unknown, mint: string, label: string): bigint {
  if (!data || typeof data !== "object" || !("parsed" in data))
    throw new Error(`Unparsed token data for ${label}`);
  const parsed = data.parsed as {
    type?: string;
    info?: { mint?: string; tokenAmount?: { amount?: string } };
  };
  if (parsed.type !== "account" || !parsed.info)
    throw new Error(`Unparsed token account for ${label}`);
  if (parsed.info.mint !== mint)
    throw new ConfigError([
      `Wallet ${label} is a token account for a different mint`,
    ]);
  const amount = parsed.info.tokenAmount?.amount;
  if (typeof amount !== "string" || !/^\d+$/.test(amount))
    throw new Error(`Invalid token amount for ${label}`);
  return BigInt(amount);
}
// Which token accounts hold each wallet's KCN. Public devnet allows only 10
// getTokenAccountsByOwner calls per 10 s, so this lookup is cached and redone
// once a minute (or when an account closes); every poll then reads all balances
// with a single getMultipleAccounts.
const ACCOUNTS_TTL_MS = 60000;
let accountsByWallet: Map<string, string[]> | undefined;
let accountsAt = 0;
async function findTokenAccounts(wallet: TrackedWallet, cfg: ChainConfig) {
  const accounts = await cfg.rpc
    .getTokenAccountsByOwner(
      address(wallet.address),
      { mint: cfg.mint },
      { encoding: "jsonParsed", commitment },
    )
    .send({ abortSignal: AbortSignal.timeout(12000) });
  for (const item of accounts.value)
    readTokenData(item.account.data, cfg.mint, wallet.label);
  if (accounts.value.length)
    return accounts.value.map((item) => item.pubkey as string);
  const own = await cfg.rpc
    .getAccountInfo(address(wallet.address), {
      encoding: "jsonParsed",
      commitment,
    })
    .send({ abortSignal: AbortSignal.timeout(12000) });
  if (own.value && Object.hasOwn(tokenPrograms, own.value.owner)) {
    readTokenData(own.value.data, cfg.mint, wallet.label);
    return [wallet.address];
  }
  return [];
}
async function resolveWallets(cfg: ChainConfig) {
  if (!accountsByWallet || Date.now() - accountsAt >= ACCOUNTS_TTL_MS) {
    const found = new Map<string, string[]>();
    for (const wallet of cfg.wallets)
      // one at a time: stays under the method limit
      found.set(wallet.address, await findTokenAccounts(wallet, cfg));
    accountsByWallet = found;
    accountsAt = Date.now();
  }
  const all = cfg.wallets.flatMap((w) => accountsByWallet!.get(w.address)!);
  const infos = all.length
    ? (
        await cfg.rpc
          .getMultipleAccounts(
            all.map((a) => address(a)),
            { encoding: "jsonParsed", commitment },
          )
          .send({ abortSignal: AbortSignal.timeout(12000) })
      ).value
    : [];
  const rawByAccount = new Map<string, bigint>();
  all.forEach((account, i) => {
    const info = infos[i];
    const wallet = cfg.wallets.find((w) =>
      accountsByWallet!.get(w.address)!.includes(account),
    )!;
    if (!info) accountsAt = 0; // closed since the lookup: find the accounts again next poll
    rawByAccount.set(
      account,
      info ? readTokenData(info.data, cfg.mint, wallet.label) : 0n,
    );
  });
  return cfg.wallets.map((wallet) => {
    const tokenAccounts = accountsByWallet!.get(wallet.address)!;
    const raw = tokenAccounts.reduce(
      (sum, a) => sum + rawByAccount.get(a)!,
      0n,
    );
    return { ...wallet, tokenAccounts, raw };
  });
}

type Activity = { events: KcnEvent[]; warnings: string[]; fetchedAt: string };
let lastActivity: Activity | undefined;
let lastAttempt = 0;
let activityInFlight: Promise<Activity> | undefined;
const transactions = new Map<string, ParsedTransaction>();

async function refreshActivity(
  cfg: ChainConfig,
  wallets: ResolvedWallet[],
  decimals: number,
): Promise<Activity> {
  // Every KCN transfer touches a token account, so owners add nothing but RPC calls.
  const addresses = new Set(wallets.flatMap((w) => w.tokenAccounts));
  const lists = await Promise.all(
    [...addresses].map((a) =>
      cfg.rpc
        .getSignaturesForAddress(address(a), { limit: 10, commitment })
        .send({ abortSignal: AbortSignal.timeout(12000) }),
    ),
  );
  const bySignature = new Map(lists.flat().map((s) => [s.signature, s]));
  // Stable sort intentionally leaves the RPC order intact for entries sharing a slot.
  const recent = [...bySignature.values()]
    .sort((a, b) => (a.slot > b.slot ? -1 : a.slot < b.slot ? 1 : 0))
    .slice(0, 20);
  const results = new Map<string, ParsedTransaction>();
  for (let start = 0; start < recent.length; start += 2) {
    await Promise.all(
      recent.slice(start, start + 2).map(async (item) => {
        const tx =
          transactions.get(item.signature) ??
          (await cfg.rpc
            .getTransaction(item.signature, {
              encoding: "jsonParsed",
              maxSupportedTransactionVersion: 0,
              commitment,
            })
            .send({ abortSignal: AbortSignal.timeout(12000) }));
        if (!tx) return;
        results.set(item.signature, tx);
        if (!transactions.has(item.signature)) {
          transactions.set(item.signature, tx);
          if (transactions.size > 100)
            transactions.delete(transactions.keys().next().value!);
        }
      }),
    );
  }
  const events: KcnEvent[] = [],
    warnings = new Set<string>();
  const trackedAccounts = new Set(wallets.flatMap((w) => w.tokenAccounts));
  for (const item of recent) {
    const tx = results.get(item.signature);
    if (!tx) {
      warnings.add("Some recent transactions are not yet available");
      continue;
    }
    const keys = tx.transaction.message.accountKeys.map((key) =>
      typeof key === "string" ? key : key.pubkey,
    );
    const base = {
      signature: item.signature,
      slot: Number(tx.slot),
      blockTime: tx.blockTime === null ? null : Number(tx.blockTime),
      memo: item.memo,
      explorerUrl: explorerTx(item.signature, "devnet"),
    };
    if (!tx.meta) {
      warnings.add("Some recent activity has missing token balance metadata");
      continue;
    }
    if (tx.meta.err !== null) {
      if (keys.some((key) => trackedAccounts.has(key)))
        events.push({
          ...base,
          kind: "failed",
          title: "Failed transaction",
          failed: true,
          deltas: [],
        });
      continue;
    }
    if (!tx.meta.preTokenBalances || !tx.meta.postTokenBalances) {
      warnings.add("Some recent activity has missing token balance metadata");
      continue;
    }
    const deltas = tokenDeltas(
      tx.meta.preTokenBalances,
      tx.meta.postTokenBalances,
      keys,
      cfg.mint,
      wallets,
    );
    if (!deltas.length) continue;
    events.push({
      ...base,
      ...classify(deltas, decimals, item.memo),
      failed: false,
      deltas: deltas.map((d) => ({
        label: d.label,
        role: d.role,
        amount: formatUnits(d.raw, decimals),
      })),
    });
  }
  return {
    events,
    warnings: [...warnings],
    fetchedAt: new Date().toISOString(),
  };
}
async function getActivity(
  cfg: ChainConfig,
  wallets: ResolvedWallet[],
  decimals: number,
) {
  if (!activityInFlight && Date.now() - lastAttempt >= 15000) {
    lastAttempt = Date.now();
    activityInFlight = refreshActivity(cfg, wallets, decimals)
      .then((result) => {
        lastActivity = result;
        return result;
      })
      .finally(() => {
        activityInFlight = undefined;
      });
  }
  if (activityInFlight) {
    try {
      await activityInFlight;
    } catch {
      return {
        events: lastActivity?.events ?? [],
        fetchedAt: lastActivity?.fetchedAt ?? null,
        warnings: [
          ...(lastActivity?.warnings ?? []),
          "Recent activity unavailable",
        ],
      };
    }
  }
  // A failed attempt is throttled too, but must remain visibly unavailable until a success.
  const unavailable =
    !lastActivity || lastAttempt > Date.parse(lastActivity.fetchedAt);
  return {
    events: lastActivity?.events ?? [],
    fetchedAt: lastActivity?.fetchedAt ?? null,
    warnings: [
      ...(lastActivity?.warnings ?? []),
      ...(unavailable ? ["Recent activity unavailable"] : []),
    ],
  };
}
export async function getKcnState(): Promise<KcnState> {
  const cfg = (config ??= loadConfig());
  const [slot, supply, resolved] = await Promise.all([
    cfg.rpc
      .getSlot({ commitment })
      .send({ abortSignal: AbortSignal.timeout(12000) }),
    cfg.rpc
      .getTokenSupply(cfg.mint, { commitment })
      .send({ abortSignal: AbortSignal.timeout(12000) }),
    resolveWallets(cfg),
  ]);
  const seen = new Set<string>();
  for (const wallet of resolved)
    for (const account of wallet.tokenAccounts) {
      if (seen.has(account))
        throw new ConfigError([
          `Token account is assigned to multiple wallet roles (${wallet.label})`,
        ]);
      seen.add(account);
    }
  const decimals = supply.value.decimals;
  const wallets = resolved.map(({ raw, ...w }) => ({
    ...w,
    balance: formatUnits(raw, decimals),
    explorerUrl: explorerAddress(w.address, "devnet"),
  }));
  const player = wallets.find((w) => w.role === "player")!;
  const activity = await getActivity(cfg, wallets, decimals);
  return {
    cluster: "devnet",
    symbol: "KCN",
    slot: Number(slot),
    kcnPerUsd: cfg.rate,
    mint: {
      address: cfg.mint,
      decimals,
      supply: formatUnits(BigInt(supply.value.amount), decimals),
      explorerUrl: explorerAddress(cfg.mint, "devnet"),
    },
    wallets,
    player: { balance: player.balance, usd: Number(player.balance) / cfg.rate },
    events: activity.events,
    activityFetchedAt: activity.fetchedAt,
    warnings: activity.warnings,
    fetchedAt: new Date().toISOString(),
  };
}
