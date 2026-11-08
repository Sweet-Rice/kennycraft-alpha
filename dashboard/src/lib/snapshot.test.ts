import { describe, expect, it } from "vitest";
import { observeSnapshot, parseSnapshot, type Snapshot } from "./snapshot";
const initial: Snapshot = {
  mode: "ONLINE",
  queued: 0,
  usd: 5000,
  wallets: { player: 20, treasury: 980, escrow: 0 },
  ledger: [],
};
const queued: Snapshot = {
  ...initial,
  queued: 1,
  wallets: { ...initial.wallets, player: 40, treasury: 960 },
  ledger: [
    {
      id: 1,
      kind: "exchange_in",
      from_wallet: "treasury",
      to_wallet: "player",
      amount: 20,
      status: "queued",
      contract_id: null,
      sig: null,
    },
  ],
};
describe("backend snapshots", () => {
  it("accepts real zero balances and unavailable mock-bank data without replacing it", () => {
    const data = parseSnapshot(
      JSON.stringify({
        ...initial,
        usd: null,
        wallets: { player: 0, treasury: 1000 },
      }),
    );
    expect(data.wallets.player).toBe(0);
    expect(data.usd).toBeNull();
  });
  it.each([
    { ...initial, wallets: { treasury: 980 } },
    { ...initial, wallets: { player: "20" } },
    { ...initial, wallets: { player: 9007199254740992 } },
    { ...initial, ledger: [{ ...queued.ledger[0], amount: 9007199254740992 }] },
    { ...initial, ledger: [{ ...queued.ledger[0], status: null }] },
  ])("rejects incompatible or precision-losing snapshots", (data) => {
    expect(() => parseSnapshot(JSON.stringify(data))).toThrow();
  });
});
describe("session observations", () => {
  it("suppresses initial highlights, then shows new entries and exact balance changes", () => {
    const loaded = observeSnapshot(null, queued, 1000);
    expect(loaded.highlights).toEqual({});
    expect(loaded.change).toBeNull();
    const next = {
      ...queued,
      wallets: { ...queued.wallets, player: 50 },
      ledger: [{ ...queued.ledger[0], id: 2, amount: 10 }, ...queued.ledger],
    };
    const updated = observeSnapshot(loaded, next, 2000);
    expect(updated.highlights).toEqual({ 2: 2000 });
    expect(updated.change).toEqual({ amount: "+10", at: 2000 });
  });
  it("updates settlement without highlighting or counting the same payment twice", () => {
    const first = observeSnapshot(null, initial, 1000);
    const pending = observeSnapshot(first, queued, 2000);
    const settled = {
      ...queued,
      queued: 0,
      ledger: [
        { ...queued.ledger[0], status: "settled", sig: "public-signature" },
      ],
    };
    const updated = observeSnapshot(pending, settled, 8000);
    expect(updated.data.ledger[0]).toMatchObject({
      id: 1,
      status: "settled",
      sig: "public-signature",
    });
    expect(updated.highlights).toEqual({});
    expect(updated.change).toEqual(pending.change);
    expect(updated.points).toEqual([
      { t: 1000, balance: 20 },
      { t: 2000, balance: 40 },
      { t: 8000, balance: 40 },
    ]);
  });
  it("retains the newest 120 snapshots and signed changes at the safe-integer boundary", () => {
    let view = observeSnapshot(
      null,
      { ...initial, wallets: { player: Number.MAX_SAFE_INTEGER } },
      0,
    );
    view = observeSnapshot(
      view,
      { ...initial, wallets: { player: Number.MAX_SAFE_INTEGER - 1 } },
      1,
    );
    expect(view.change?.amount).toBe("-1");
    for (let at = 2; at < 125; at++) view = observeSnapshot(view, initial, at);
    expect(view.points.map((point) => point.t)).toEqual(
      Array.from({ length: 120 }, (_, i) => i + 5),
    );
  });
});
