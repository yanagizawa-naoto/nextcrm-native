"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { toast } from "sonner";
import Link from "next/link";
import { Button } from "@/components/ui/button";
import { SendEmailDialog } from "./send-email-dialog";
import { AddPaymentDialog } from "./add-payment-dialog";
import {
  Pencil,
  Copy,
  FileDown,
  Ban,
  CheckCircle,
  RefreshCw,
} from "lucide-react";
import { issueInvoice } from "@/actions/invoices/issue-invoice";
import { cancelInvoice } from "@/actions/invoices/cancel-invoice";
import { duplicateInvoice } from "@/actions/invoices/duplicate-invoice";
import { regenerateInvoicePdf } from "@/actions/invoices/regenerate-pdf";

interface InvoiceActionsProps {
  invoiceId: string;
  status: string;
  balanceDue: string;
  currency: string;
  accountEmail?: string;
}

export function InvoiceActions({
  invoiceId,
  status,
  balanceDue,
  currency,
  accountEmail,
}: InvoiceActionsProps) {
  const router = useRouter();
  const [loading, setLoading] = useState<string | null>(null);

  const isDraft = status === "DRAFT";
  const canPay = [
    "ISSUED",
    "SENT",
    "PARTIALLY_PAID",
    "OVERDUE",
  ].includes(status);
  const canSend = ["ISSUED", "SENT"].includes(status);

  const handleAction = async (action: "issue" | "cancel" | "duplicate") => {
    setLoading(action);
    try {
      if (action === "issue") {
        await issueInvoice({ invoiceId });
        toast.success("請求書を発行しました");
        router.refresh();
      } else if (action === "cancel") {
        await cancelInvoice(invoiceId);
        toast.success("請求書を取り消しました");
        router.refresh();
      } else {
        const result = await duplicateInvoice(invoiceId);
        toast.success("請求書を複製しました");
        router.push(`/invoices/${result.id}`);
      }
    } catch {
      toast.error(`Failed to ${action} invoice`);
    } finally {
      setLoading(null);
    }
  };

  const handleRegenerate = async () => {
    setLoading("regenerate");
    const res = await regenerateInvoicePdf(invoiceId);
    if (res.ok) {
      toast.success("PDFを再作成しました");
      router.refresh();
    } else {
      toast.error(res.error);
    }
    setLoading(null);
  };

  return (
    <div className="flex flex-wrap gap-2">
      {isDraft && (
        <>
          <Link href={`/invoices/${invoiceId}/edit`}>
            <Button variant="outline" size="sm">
              <Pencil className="mr-2 h-4 w-4" />
              {"編集"}</Button>
          </Link>
          <Button
            variant="default"
            size="sm"
            onClick={() => handleAction("issue")}
            disabled={loading === "issue"}
          >
            <CheckCircle className="mr-2 h-4 w-4" />
            {loading === "issue" ? "発行中…" : "発行"}
          </Button>
          <Button
            variant="destructive"
            size="sm"
            onClick={() => {
              if (confirm("この下書きの請求書を取り消しますか？")) {
                handleAction("cancel");
              }
            }}
            disabled={loading === "cancel"}
          >
            <Ban className="mr-2 h-4 w-4" />
            {"取消"}</Button>
        </>
      )}

      {canSend && (
        <SendEmailDialog
          invoiceId={invoiceId}
          defaultEmail={accountEmail}
        />
      )}

      {canPay && (
        <AddPaymentDialog
          invoiceId={invoiceId}
          balanceDue={balanceDue}
          currency={currency}
        />
      )}

      <Button
        variant="outline"
        size="sm"
        onClick={() => handleAction("duplicate")}
        disabled={loading === "duplicate"}
      >
        <Copy className="mr-2 h-4 w-4" />
        {"複製"}</Button>

      <a
        href={`/api/invoices/${invoiceId}/pdf`}
        target="_blank"
        rel="noopener noreferrer"
      >
        <Button variant="outline" size="sm">
          <FileDown className="mr-2 h-4 w-4" />
          {"PDFを保存"}</Button>
      </a>

      {!isDraft && (
        <Button
          variant="outline"
          size="sm"
          onClick={handleRegenerate}
          disabled={loading === "regenerate"}
          title="現在の自社情報でPDFを再作成"
        >
          <RefreshCw className="mr-2 h-4 w-4" />
          {loading === "regenerate" ? "再作成中…" : "PDFを再作成"}
        </Button>
      )}
    </div>
  );
}
