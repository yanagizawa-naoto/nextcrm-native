import { InvoicesTabs } from "./_components/InvoicesTabs";

export default function InvoicesLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold tracking-tight">{"請求書"}</h1>
        <p className="text-sm text-muted-foreground">
          {"請求書の基本設定・採番系列・税率を管理します。"}</p>
      </div>
      <InvoicesTabs />
      {children}
    </div>
  );
}
