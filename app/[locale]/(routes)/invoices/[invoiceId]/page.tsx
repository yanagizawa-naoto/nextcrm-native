import { INVOICE_TYPE_LABELS } from "@/types/invoice";
import { notFound } from "next/navigation";
import { getLocale, getTranslations } from "next-intl/server";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { Separator } from "@/components/ui/separator";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { getInvoiceById } from "../data/get-invoices";
import { StatusBadge } from "../components/status-badge";
import { InvoiceActions } from "./components/invoice-actions";
import { PaymentList } from "./components/payment-list";
import { ActivityLog } from "./components/activity-log";

interface Props {
  params: Promise<{ invoiceId: string }>;
}

function formatDate(d: Date | string | null, locale: string) {
  if (!d) return "-";
  return new Date(d).toLocaleDateString(locale);
}

function formatCurrency(amount: string | number, currency: string, locale: string) {
  const num = typeof amount === "string" ? parseFloat(amount) : amount;
  if (isNaN(num)) return String(amount);
  return new Intl.NumberFormat(locale, {
    style: "currency",
    currency: currency || "JPY",
    minimumFractionDigits: currency === "JPY" ? 0 : 2,
  }).format(num);
}

export default async function InvoiceDetailPage({ params }: Props) {
  const { invoiceId } = await params;
  const locale = await getLocale();
  const t = await getTranslations("InvoicesPage");
  const invoice = await getInvoiceById(invoiceId);

  if (!invoice) {
    notFound();
  }

  const statusLabels: Record<string, string> = {
    DRAFT: t("status.DRAFT"),
    ISSUED: t("status.ISSUED"),
    SENT: t("status.SENT"),
    PARTIALLY_PAID: t("status.PARTIALLY_PAID"),
    PAID: t("status.PAID"),
    OVERDUE: t("status.OVERDUE"),
    CANCELLED: t("status.CANCELLED"),
    DISPUTED: t("status.DISPUTED"),
    REFUNDED: t("status.REFUNDED"),
    WRITTEN_OFF: t("status.WRITTEN_OFF"),
  };

  const billing =
    (invoice.billingSnapshot as Record<string, string> | null) ?? {};
  const accountEmail =
    (invoice.account as { email?: string } | null)?.email ?? undefined;

  return (
    <div className="space-y-6">
      {/* Header */}
      <div className="flex flex-col md:flex-row md:items-center md:justify-between gap-4">
        <div className="flex items-center gap-3">
          <h1 className="text-2xl font-bold">
            {invoice.number ?? "下書き"}
          </h1>
          <Badge variant="secondary">{INVOICE_TYPE_LABELS[invoice.type] ?? invoice.type}</Badge>
          <StatusBadge status={invoice.status} labels={statusLabels} />
        </div>
        <InvoiceActions
          invoiceId={invoice.id}
          status={invoice.status}
          balanceDue={invoice.balanceDue.toString()}
          currency={invoice.currency}
          accountEmail={accountEmail}
        />
      </div>

      <Separator />

      {/* Two-column layout */}
      <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
        {/* Left: Customer & dates */}
        <Card>
          <CardHeader className="pb-3">
            <CardTitle className="text-base">{"詳細"}</CardTitle>
          </CardHeader>
          <CardContent className="space-y-3 text-sm">
            <div className="grid grid-cols-2 gap-2">
              <span className="text-muted-foreground">
                {t("table.account")}
              </span>
              <span className="font-medium">
                {invoice.account?.name ?? "-"}
              </span>
            </div>
            {billing.street && (
              <div className="grid grid-cols-2 gap-2">
                <span className="text-muted-foreground">{"住所"}</span>
                <span>
                  {[billing.zip, billing.state, billing.city, billing.street].filter(Boolean).join(" ")}
                </span>
              </div>
            )}
            <div className="grid grid-cols-2 gap-2">
              <span className="text-muted-foreground">
                {t("table.issueDate")}
              </span>
              <span>{formatDate(invoice.issueDate, locale)}</span>
            </div>
            <div className="grid grid-cols-2 gap-2">
              <span className="text-muted-foreground">
                {t("table.dueDate")}
              </span>
              <span>{formatDate(invoice.dueDate, locale)}</span>
            </div>
            {invoice.variableSymbol && (
              <div className="grid grid-cols-2 gap-2">
                <span className="text-muted-foreground">
                  {t("form.variableSymbol")}
                </span>
                <span>{invoice.variableSymbol}</span>
              </div>
            )}
            {invoice.series && (
              <div className="grid grid-cols-2 gap-2">
                <span className="text-muted-foreground">
                  {t("form.series")}
                </span>
                <span>{invoice.series.name}</span>
              </div>
            )}
          </CardContent>
        </Card>

        {/* Right: Totals */}
        <Card>
          <CardHeader className="pb-3">
            <CardTitle className="text-base">{"金額の内訳"}</CardTitle>
          </CardHeader>
          <CardContent className="space-y-3 text-sm">
            <div className="grid grid-cols-2 gap-2">
              <span className="text-muted-foreground">{"小計"}</span>
              <span className="font-mono">
                {formatCurrency(
                  invoice.subtotal.toString(),
                  invoice.currency,
                  locale
                )}
              </span>
            </div>
            {parseFloat(invoice.discountTotal.toString()) > 0 && (
              <div className="grid grid-cols-2 gap-2">
                <span className="text-muted-foreground">{"値引き"}</span>
                <span className="font-mono text-red-600">
                  -
                  {formatCurrency(
                    invoice.discountTotal.toString(),
                    invoice.currency,
                    locale
                  )}
                </span>
              </div>
            )}
            <div className="grid grid-cols-2 gap-2">
              <span className="text-muted-foreground">{"税額"}</span>
              <span className="font-mono">
                {formatCurrency(
                  invoice.vatTotal.toString(),
                  invoice.currency,
                  locale
                )}
              </span>
            </div>
            <Separator />
            <div className="grid grid-cols-2 gap-2 font-semibold">
              <span>{"総合計"}</span>
              <span className="font-mono">
                {formatCurrency(
                  invoice.grandTotal.toString(),
                  invoice.currency,
                  locale
                )}
              </span>
            </div>
            <div className="grid grid-cols-2 gap-2">
              <span className="text-muted-foreground">{"入金済み"}</span>
              <span className="font-mono text-green-600">
                {formatCurrency(
                  invoice.paidTotal.toString(),
                  invoice.currency,
                  locale
                )}
              </span>
            </div>
            <div className="grid grid-cols-2 gap-2 font-semibold">
              <span>{"未入金額"}</span>
              <span className="font-mono">
                {formatCurrency(
                  invoice.balanceDue.toString(),
                  invoice.currency,
                  locale
                )}
              </span>
            </div>
            {invoice.bankName && (
              <>
                <Separator />
                <div className="grid grid-cols-2 gap-2">
                  <span className="text-muted-foreground">{"金融機関"}</span>
                  <span>{invoice.bankName}</span>
                </div>
                {invoice.iban && (
                  <div className="grid grid-cols-2 gap-2">
                    <span className="text-muted-foreground">{"IBAN（国際銀行口座番号）"}</span>
                    <span className="font-mono text-xs">{invoice.iban}</span>
                  </div>
                )}
                {invoice.swift && (
                  <div className="grid grid-cols-2 gap-2">
                    <span className="text-muted-foreground">{"SWIFTコード"}</span>
                    <span className="font-mono text-xs">
                      {invoice.swift}
                    </span>
                  </div>
                )}
              </>
            )}
          </CardContent>
        </Card>
      </div>

      {/* Line Items */}
      <Card>
        <CardHeader className="pb-3">
          <CardTitle className="text-base">
            {t("form.lineItems")}
          </CardTitle>
        </CardHeader>
        <CardContent>
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead className="w-8">#</TableHead>
                <TableHead>{t("form.description")}</TableHead>
                <TableHead className="text-right">
                  {t("form.quantity")}
                </TableHead>
                <TableHead className="text-right">
                  {t("form.unitPrice")}
                </TableHead>
                <TableHead className="text-right">
                  {t("form.discount")}
                </TableHead>
                <TableHead className="text-right">
                  {t("form.taxRate")}
                </TableHead>
                <TableHead className="text-right">
                  {t("form.total")}
                </TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {invoice.lineItems.map((li, idx) => (
                <TableRow key={li.id}>
                  <TableCell className="text-muted-foreground">
                    {idx + 1}
                  </TableCell>
                  <TableCell>
                    <div>
                      <span className="font-medium">{li.description}</span>
                      {li.product && (
                        <span className="text-xs text-muted-foreground ml-2">
                          ({li.product.name})
                        </span>
                      )}
                    </div>
                  </TableCell>
                  <TableCell className="text-right font-mono">
                    {li.quantity.toString()}
                  </TableCell>
                  <TableCell className="text-right font-mono">
                    {formatCurrency(
                      li.unitPrice.toString(),
                      invoice.currency,
                      locale
                    )}
                  </TableCell>
                  <TableCell className="text-right">
                    {parseFloat(li.discountPercent.toString()) > 0
                      ? `${li.discountPercent}%`
                      : "-"}
                  </TableCell>
                  <TableCell className="text-right">
                    {li.taxRate
                      ? `${li.taxRate.name} (${li.taxRate.rate}%)`
                      : "-"}
                  </TableCell>
                  <TableCell className="text-right font-mono font-medium">
                    {formatCurrency(
                      li.lineTotal.toString(),
                      invoice.currency,
                      locale
                    )}
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </CardContent>
      </Card>

      {/* Notes */}
      {(invoice.publicNotes || invoice.internalNotes) && (
        <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
          {invoice.publicNotes && (
            <Card>
              <CardHeader className="pb-3">
                <CardTitle className="text-base">
                  {t("form.publicNotes")}
                </CardTitle>
              </CardHeader>
              <CardContent>
                <p className="text-sm whitespace-pre-wrap">
                  {invoice.publicNotes}
                </p>
              </CardContent>
            </Card>
          )}
          {invoice.internalNotes && (
            <Card>
              <CardHeader className="pb-3">
                <CardTitle className="text-base">
                  {t("form.internalNotes")}
                </CardTitle>
              </CardHeader>
              <CardContent>
                <p className="text-sm whitespace-pre-wrap">
                  {invoice.internalNotes}
                </p>
              </CardContent>
            </Card>
          )}
        </div>
      )}

      {/* Payments */}
      <Card>
        <CardHeader className="pb-3">
          <CardTitle className="text-base">{"入金履歴"}</CardTitle>
        </CardHeader>
        <CardContent>
          <PaymentList
            payments={JSON.parse(JSON.stringify(invoice.payments))}
            currency={invoice.currency}
            locale={locale}
          />
        </CardContent>
      </Card>

      {/* Activity */}
      <Card>
        <CardHeader className="pb-3">
          <CardTitle className="text-base">{"活動履歴"}</CardTitle>
        </CardHeader>
        <CardContent>
          <ActivityLog
            activities={JSON.parse(JSON.stringify(invoice.activity))}
          />
        </CardContent>
      </Card>
    </div>
  );
}
