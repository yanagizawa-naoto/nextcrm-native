import { embedBackfill } from "../embed-backfill";
import { prismadb } from "@/lib/prisma";
import { inngest } from "@/inngest/client";

jest.mock("@/inngest/client", () => ({ inngest: { createFunction: (_: unknown, handler: unknown) => ({ handler }), send: jest.fn() } }));
jest.mock("@/lib/prisma", () => ({ prismadb: {
  crm_Accounts: { findMany: jest.fn() }, crm_Contacts: { findMany: jest.fn() },
  crm_Leads: { findMany: jest.fn() }, crm_Opportunities: { findMany: jest.fn() },
} }));

const run = () => (embedBackfill as unknown as { handler: () => Promise<unknown> }).handler();
const accounts = prismadb.crm_Accounts.findMany as jest.Mock;
const contacts = prismadb.crm_Contacts.findMany as jest.Mock;
const leads = prismadb.crm_Leads.findMany as jest.Mock;
const opportunities = prismadb.crm_Opportunities.findMany as jest.Mock;
const send = inngest.send as jest.Mock;

beforeEach(() => {
  jest.resetAllMocks();
  for (const query of [accounts, contacts, leads, opportunities]) query.mockResolvedValue([]);
  send.mockResolvedValue({ ids: [] });
});

test("large backfills fetch and dispatch at most 512 IDs per batch without losing records", async () => {
  const ids = Array.from({ length: 1025 }, (_, i) => ({ id: String(i).padStart(8, "0") }));
  accounts.mockImplementation(async query => {
    expect(query.take).toBe(512);
    expect(query.orderBy).toEqual({ id: "asc" });
    expect(query.select).toEqual({ id: true });
    expect(query.skip).toBeUndefined();
    return ids.filter(row => !query.where || row.id > query.where.id.gt).slice(0, query.take);
  });
  contacts.mockResolvedValue([{ id: "contact-1" }]);
  expect(await run()).toEqual({ dispatched: 1026, accounts: 1025, contacts: 1, leads: 0, opportunities: 0 });
  expect(send.mock.calls.map(([events]) => events.length)).toEqual([512, 512, 1, 1]);
  expect(send.mock.calls.flatMap(([events]) => events).filter(e => e.name === "crm/account.saved").map(e => e.data.record_id)).toEqual(ids.map(r => r.id));
  expect(accounts.mock.calls[1][0].where).toEqual({ id: { gt: "00000511" } });
  expect(accounts.mock.calls[2][0].where).toEqual({ id: { gt: "00001023" } });
});

test("a rejected dispatch stops loading more pages", async () => {
  accounts.mockResolvedValue(Array.from({ length: 512 }, (_, i) => ({ id: String(i) })));
  send.mockRejectedValue(new Error("queue unavailable"));
  await expect(run()).rejects.toThrow("queue unavailable");
  expect(accounts).toHaveBeenCalledTimes(1);
  expect(contacts).not.toHaveBeenCalled();
});

test("an empty CRM dispatches no events", async () => {
  expect(await run()).toEqual({ dispatched: 0, accounts: 0, contacts: 0, leads: 0, opportunities: 0 });
  expect(send).not.toHaveBeenCalled();
});
