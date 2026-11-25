import { getSession } from "@/lib/auth-server";
import { redirect } from "next/navigation";
import { getAuditLogAdmin } from "@/actions/crm/audit-log/get-audit-log-admin";
import { AdminFilters } from "@/components/crm/audit-log/AdminFilters";
import { AdminAuditLogClient } from "@/components/crm/audit-log/AdminPageClient";

const AuditLogPage = async (props: {
  searchParams?: Promise<{
    page?: string;
    entityType?: string;
    action?: string;
    dateFrom?: string;
    dateTo?: string;
  }>;
}) => {
  const session = await getSession();
  if (session?.user?.role !== "admin") redirect("/");

  const sp = await props.searchParams;
  const currentPage = Math.max(1, parseInt(sp?.page ?? "1", 10) || 1);
  const filters = {
    page: currentPage,
    entityType: sp?.entityType,
    action: sp?.action,
    dateFrom: sp?.dateFrom ? new Date(sp.dateFrom) : undefined,
    dateTo: sp?.dateTo ? new Date(sp.dateTo) : undefined,
  };

  const result = await getAuditLogAdmin(filters);
  if ("error" in result) return <div>{"アクセスできません"}</div>;

  return (
    <div className="p-6 space-y-6">
      <div>
        <h1 className="text-2xl font-bold tracking-tight">{"変更履歴"}</h1>
        <p className="text-muted-foreground text-sm mt-1">
          {"CRM全体の変更履歴を確認できます。"}</p>
      </div>
      <AdminFilters
        entityType={sp?.entityType}
        action={sp?.action}
        dateFrom={sp?.dateFrom}
        dateTo={sp?.dateTo}
      />
      <AdminAuditLogClient
        entries={result.data}
        total={result.total}
        page={result.page}
        totalPages={result.totalPages}
        role={session?.user?.role ?? "user"}
      />
    </div>
  );
};

export default AuditLogPage;
