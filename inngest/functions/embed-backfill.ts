import { inngest } from "@/inngest/client";
import { prismadb } from "@/lib/prisma";

const BATCH_SIZE = 512;

export const embedBackfill = inngest.createFunction(
  { id: "embed-backfill", name: "Embed Backfill All CRM Records", triggers: [{ event: "crm/backfill.requested" }] },
  async () => {
    const totals = { dispatched: 0, accounts: 0, contacts: 0, leads: 0, opportunities: 0 };
    const sources = [
      ["accounts", "crm/account.saved"], ["contacts", "crm/contact.saved"],
      ["leads", "crm/lead.saved"], ["opportunities", "crm/opportunity.saved"],
    ] as const;
    for (const [entity, name] of sources) {
      let after: string | undefined;
      while (true) {
        const query = {
          select: { id: true } as const, take: BATCH_SIZE,
          orderBy: { id: "asc" } as const,
          ...(after ? { where: { id: { gt: after } } } : {}),
        };
        // Keyset pagination uses the primary key and remains valid if the last
        // record is deleted between batches. No growing offset or ID list.
        const rows = entity === "accounts" ? await prismadb.crm_Accounts.findMany(query)
          : entity === "contacts" ? await prismadb.crm_Contacts.findMany(query)
          : entity === "leads" ? await prismadb.crm_Leads.findMany(query)
          : await prismadb.crm_Opportunities.findMany(query);
        if (rows.length === 0) break;
        await inngest.send(rows.map(row => ({ name, data: { record_id: row.id } })));
        totals[entity] += rows.length;
        totals.dispatched += rows.length;
        after = rows[rows.length - 1].id;
        if (rows.length < BATCH_SIZE) break;
      }
    }
    return totals;
  }
);
