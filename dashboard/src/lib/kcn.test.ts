import { describe, expect, it } from "vitest";
import {
  appendObservation,
  balanceChange,
  classify,
  ConfigError,
  formatUnits,
  parseWallets,
  tokenDeltas,
  type Delta,
  type ResolvedWallet,
  type TokenBalance,
} from "./kcn";
const wallets: ResolvedWallet[] = [
  {
    label: "banker",
    role: "banker",
    address: "bank",
    tokenAccounts: ["bank-token"],
  },
  {
    label: "player",
    role: "player",
    address: "player",
    tokenAccounts: ["player-token", "player-token-2"],
  },
  {
    label: "escrow",
    role: "escrow",
    address: "escrow-token",
    tokenAccounts: ["escrow-token"],
  },
];
const balance = (
  accountIndex: number,
  amount: string,
  owner?: string,
  mint = "mint",
): TokenBalance => ({
  accountIndex,
  mint,
  owner,
  uiTokenAmount: { amount, decimals: 0 },
});
const movement = (role: Delta["role"], raw: bigint): Delta => ({
  role,
  raw,
  label: role,
  owner: role,
});
describe("exact quantities", () => {
  it("formats base units without floating point or rounding", () => {
    expect(formatUnits(123456789n, 6)).toBe("123.456789");
    expect(formatUnits(0n, 6)).toBe("0");
    expect(formatUnits(-1200000n, 6)).toBe("-1.2");
    expect(formatUnits(9007199254740993n, 0)).toBe("9007199254740993");
    expect(balanceChange("9007199254740993", "9007199254740994", 0)).toBe("+1");
    expect(balanceChange("12.005", "10", 3)).toBe("-2.005");
  });
});
describe("wallet configuration", () => {
  const valid = (a: string) => a.startsWith("valid");
  it("requires a player and ignores empty optional addresses", () => {
    expect(
      parseWallets(
        " PLAYER = valid-player,banker=,builder=valid-builder",
        valid,
      ).wallets.map((w) => w.role),
    ).toEqual(["player", "worker"]);
    expect(() => parseWallets("banker=valid-bank", valid)).toThrow(ConfigError);
  });
  it.each([
    "player=valid-a,player=valid-b",
    "player=valid-a,banker=valid-a",
    "player=bad",
    "player=valid-a,unknown=valid-b",
  ])("rejects ambiguous or invalid entries %s", (raw) => {
    expect(() => parseWallets(raw, valid)).toThrow(ConfigError);
  });
});
describe("transaction deltas", () => {
  it("retains new accounts and ignores other mints", () => {
    const result = tokenDeltas(
      [balance(0, "1000", "bank")],
      [
        balance(0, "950", "bank"),
        balance(1, "50", "player"),
        balance(2, "999", "player", "unrelated"),
      ],
      ["bank-token", "player-token", "other"],
      "mint",
      wallets,
    );
    expect(result.map((d) => [d.label, d.raw])).toEqual([
      ["banker", -50n],
      ["player", 50n],
    ]);
    expect(classify(result, 0).kind).toBe("bank_buy");
  });
  it("accounts for closures, aggregates player accounts, and resolves individual escrow accounts", () => {
    const result = tokenDeltas(
      [balance(0, "80", "player"), balance(1, "20", "player")],
      [balance(1, "50", "player"), balance(2, "50", "some-program")],
      ["player-token", "player-token-2", "escrow-token"],
      "mint",
      wallets,
    );
    expect(result.map((d) => [d.label, d.raw])).toEqual([
      ["player", -50n],
      ["escrow", 50n],
    ]);
    expect(classify(result, 0).kind).toBe("escrow_fund");
  });
  it("keeps untracked counterparties and ownerless token accounts", () => {
    const result = tokenDeltas(
      [balance(0, "20", "player")],
      [balance(0, "0", "player"), balance(1, "20")],
      ["player-token", "unknown-token"],
      "mint",
      wallets,
    );
    expect(result.map((d) => [d.owner, d.raw])).toEqual([
      ["player", -20n],
      ["unknown-token", 20n],
    ]);
    expect(classify(result, 0).kind).toBe("transfer");
  });
  it("refuses missing metadata instead of inventing supply changes", () => {
    expect(() =>
      tokenDeltas(undefined, [balance(0, "5")], ["token"], "mint", wallets),
    ).toThrow();
    expect(() =>
      tokenDeltas([balance(0, "5")], null, ["token"], "mint", wallets),
    ).toThrow();
    expect(tokenDeltas([], [], [], "mint", wallets)).toEqual([]);
  });
});
describe("evidence-limited classification", () => {
  it.each([
    ["banker", "player", "bank_buy"],
    ["player", "banker", "bank_sell"],
    ["player", "escrow", "escrow_fund"],
    ["escrow", "worker", "escrow_release"],
    ["escrow", "player", "escrow_refund"],
  ] as const)("recognizes balanced %s to %s", (from, to, kind) => {
    expect(classify([movement(from, -50n), movement(to, 50n)], 0).kind).toBe(
      kind,
    );
  });
  it("keeps multi-party and imbalanced movements generic", () => {
    expect(
      classify(
        [
          movement("banker", -50n),
          movement("player", 20n),
          movement("escrow", 30n),
        ],
        0,
      ).kind,
    ).toBe("transfer");
    expect(
      classify([movement("banker", -50n), movement("player", 49n)], 0).kind,
    ).toBe("transfer");
    expect(classify([movement("player", 50n)], 0).kind).toBe("mint");
    expect(classify([movement("player", -50n)], 0).kind).toBe("burn");
  });
});
it("retains the newest 120 observations without mutating exact strings", () => {
  const exact = "9007199254740993";
  let points: { t: number; balance: number }[] = [];
  for (let t = 0; t < 125; t++)
    points = appendObservation(points, { t, balance: Number(exact) });
  expect(points.map((p) => p.t)).toEqual(
    Array.from({ length: 120 }, (_, i) => i + 5),
  );
  expect(exact).toBe("9007199254740993");
});
