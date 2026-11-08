import { createServer, type Server } from "node:http";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { KcnState } from "./kcn";
vi.mock("server-only", () => ({}));

const mint = "11111111111111111111111111111111";
const player = "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA";
const banker = "So11111111111111111111111111111111111111112";
const playerToken = "SysvarRent111111111111111111111111111111111";
const bankToken = "SysvarC1ock11111111111111111111111111111111";
let server: Server;
let getState: () => Promise<KcnState>;
let mode:
  | "normal"
  | "binary"
  | "wrong-mint"
  | "failed"
  | "missing"
  | "activity-error"
  | "balance-error";
let decimals: number,
  rawPlayer: string,
  rawBanker: string,
  nullTransaction: boolean;
let signatures: string[], activeTransactions: number, peakTransactions: number;
let transactionReads: Record<string, number>;
interface Gate {
  promise: Promise<void>;
  resolve: () => void;
}
let transactionGate: Gate | null, twoTransactions: Gate;
function account(pubkey: string, owner: string, amount: string) {
  return {
    pubkey,
    account: {
      owner: player,
      lamports: 1,
      executable: false,
      rentEpoch: 0,
      data:
        mode === "binary"
          ? ["AAAA", "base64"]
          : {
              program: "spl-token",
              space: 165,
              parsed: {
                type: "account",
                info: {
                  mint: mode === "wrong-mint" ? banker : mint,
                  owner,
                  tokenAmount: { amount, decimals },
                },
              },
            },
    },
  };
}
function tokenBalance(index: number, amount: string, owner: string) {
  return {
    accountIndex: index,
    mint,
    owner,
    uiTokenAmount: { amount, decimals },
  };
}
beforeEach(async () => {
  vi.resetModules();
  vi.useFakeTimers({ toFake: ["Date"] });
  vi.setSystemTime(new Date("2026-11-08T12:00:00Z"));
  mode = "normal";
  decimals = 0;
  rawPlayer = "20";
  rawBanker = "980";
  signatures = [];
  nullTransaction = false;
  activeTransactions = 0;
  peakTransactions = 0;
  transactionReads = {};
  transactionGate = null;
  twoTransactions = Promise.withResolvers<void>();
  server = createServer(async (request, response) => {
    let body = "";
    for await (const chunk of request) body += chunk;
    const { method, params = [], id } = JSON.parse(body);
    let result: unknown;
    if (
      (mode === "activity-error" && method === "getSignaturesForAddress") ||
      (mode === "balance-error" && method === "getTokenSupply")
    ) {
      response.setHeader("Content-Type", "application/json");
      response.end(
        JSON.stringify({
          jsonrpc: "2.0",
          id,
          error: { code: -32005, message: "test provider failure" },
        }),
      );
      return;
    }
    if (method === "getSlot") result = 100;
    else if (method === "getTokenSupply")
      result = { context: { slot: 100 }, value: { amount: "1000", decimals } };
    else if (method === "getTokenAccountsByOwner")
      result = {
        context: { slot: 100 },
        value:
          params[0] === player
            ? [account(playerToken, player, rawPlayer)]
            : params[0] === banker
              ? [account(bankToken, banker, rawBanker)]
              : [],
      };
    else if (method === "getAccountInfo")
      result = {
        context: { slot: 100 },
        value:
          params[0] === playerToken
            ? account(playerToken, player, rawPlayer).account
            : null,
      };
    else if (method === "getSignaturesForAddress")
      result = signatures.map((signature) => ({
        signature,
        slot: 100,
        err: null,
        memo: null,
        blockTime: null,
        confirmationStatus: "finalized",
      }));
    else if (method === "getTransaction") {
      const signature = params[0];
      transactionReads[signature] = (transactionReads[signature] ?? 0) + 1;
      activeTransactions++;
      peakTransactions = Math.max(peakTransactions, activeTransactions);
      if (activeTransactions === 2) twoTransactions.resolve();
      if (transactionGate) await transactionGate.promise;
      activeTransactions--;
      result = nullTransaction
        ? null
        : {
            slot: 100,
            blockTime: null,
            version: "legacy",
            transaction: {
              signatures: [signature],
              message: {
                accountKeys: [{ pubkey: bankToken }, { pubkey: playerToken }],
                instructions: [],
                recentBlockhash: mint,
              },
            },
            meta: {
              err:
                mode === "failed" ? { InstructionError: [0, "Custom"] } : null,
              fee: 5000,
              preBalances: [],
              postBalances: [],
              preTokenBalances: [
                tokenBalance(0, "980", banker),
                tokenBalance(1, "20", player),
              ],
              postTokenBalances:
                mode === "missing"
                  ? undefined
                  : [
                      tokenBalance(0, "960", banker),
                      tokenBalance(1, "40", player),
                    ],
              status: { Ok: null },
              innerInstructions: [],
              logMessages: [],
              rewards: [],
            },
          };
    }
    response.setHeader("Content-Type", "application/json");
    response.end(JSON.stringify({ jsonrpc: "2.0", id, result }));
  });
  const listening = Promise.withResolvers<void>();
  server.listen(0, "127.0.0.1", listening.resolve);
  await listening.promise;
  const location = server.address();
  if (!location || typeof location === "string")
    throw new Error("Fixture did not bind");
  vi.stubEnv("SOLANA_RPC_URL", `http://127.0.0.1:${location.port}`);
  vi.stubEnv("SOLANA_CLUSTER", "devnet");
  vi.stubEnv("KCN_MINT", mint);
  vi.stubEnv("KCN_WALLETS", `player=${player},banker=${banker}`);
  vi.stubEnv("KCN_PER_USD", "10");
  // Dynamic import intentionally resets process-local config and activity caches for each isolation boundary.
  getState = (await import("./chain")).getKcnState;
});
afterEach(async () => {
  vi.useRealTimers();
  vi.unstubAllEnvs();
  const closed = Promise.withResolvers<void>();
  server.close((error) => (error ? closed.reject(error) : closed.resolve()));
  server.closeAllConnections();
  await closed.promise;
});
describe("finalized state boundary", () => {
  it("retains exact amounts beyond Number precision at the JSON boundary", async () => {
    decimals = 6;
    rawPlayer = "9007199254740993";
    const state = await getState();
    expect(state.player.balance).toBe("9007199254.740993");
    expect(state.wallets.find((w) => w.role === "player")?.balance).toBe(
      "9007199254.740993",
    );
    expect(JSON.parse(JSON.stringify(state)).player.balance).toBe(
      "9007199254.740993",
    );
  });
  it("resolves an individual token account and rejects a different mint", async () => {
    vi.stubEnv("KCN_WALLETS", `player=${playerToken}`);
    expect((await getState()).wallets[0]).toMatchObject({
      balance: "20",
      tokenAccounts: [playerToken],
    });
    mode = "wrong-mint";
    await expect(getState()).rejects.toMatchObject({
      name: "Error",
      missing: expect.any(Array),
    });
  });
  it("rejects overlapping owner and individual-account roles", async () => {
    vi.stubEnv("KCN_WALLETS", `player=${player},escrow=${playerToken}`);
    await expect(getState()).rejects.toMatchObject({
      missing: expect.any(Array),
    });
  });
  it("fails unparsed token reads instead of reporting zero", async () => {
    mode = "binary";
    await expect(getState()).rejects.toThrow(/Unparsed/);
  });
  it("omits incomplete activity metadata without inventing mint or burn", async () => {
    mode = "missing";
    signatures = ["1".repeat(64)];
    const state = await getState();
    expect(state.events).toEqual([]);
    expect(state.warnings).toContainEqual(expect.stringMatching(/metadata/));
    expect(state.player.balance).toBe("20");
  });
  it("failed transactions have no balance deltas", async () => {
    mode = "failed";
    signatures = ["1".repeat(64)];
    const state = await getState();
    expect(state.events).toMatchObject([
      { failed: true, kind: "failed", deltas: [] },
    ]);
    expect(state.player.balance).toBe("20");
  });
  it("preserves previous activity while delivering new balances on activity failure", async () => {
    signatures = ["1".repeat(64)];
    const first = await getState();
    vi.setSystemTime(new Date("2026-11-08T12:00:16Z"));
    mode = "activity-error";
    rawPlayer = "40";
    const next = await getState();
    expect(next.player.balance).toBe("40");
    expect(next.events).toEqual(first.events);
    expect(next.activityFetchedAt).toBe(first.activityFetchedAt);
    expect(next.warnings).toContainEqual(expect.stringMatching(/unavailable/i));
    const throttled = await getState();
    expect(throttled.warnings).toEqual(next.warnings);
    mode = "balance-error";
    await expect(getState()).rejects.toThrow();
  });
  it("shares refreshes, bounds transaction concurrency, caches results but not nulls", async () => {
    signatures = ["1", "2", "3", "4", "5"].map((value) => value.repeat(64));
    nullTransaction = true;
    transactionGate = Promise.withResolvers<void>();
    const pending = getState();
    await twoTransactions.promise;
    transactionGate.resolve();
    transactionGate = null;
    const unavailable = await pending;
    expect(unavailable.events).toEqual([]);
    expect(unavailable.activityFetchedAt).not.toBeNull();
    expect(peakTransactions).toBe(2);
    nullTransaction = false;
    vi.setSystemTime(new Date("2026-11-08T12:00:16Z"));
    const [a, b] = await Promise.all([getState(), getState()]);
    expect(a.events.map((event) => event.signature)).toEqual(signatures);
    expect(b.events).toEqual(a.events);
    expect(Object.values(transactionReads)).toEqual([2, 2, 2, 2, 2]);
    vi.setSystemTime(new Date("2026-11-08T12:00:32Z"));
    await getState();
    expect(Object.values(transactionReads)).toEqual([2, 2, 2, 2, 2]);
  });
});
