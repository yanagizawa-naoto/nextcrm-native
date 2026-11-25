import { z } from "zod";

/* ------------------------------------------------------------------ */
/*  Shared constants                                                   */
/* ------------------------------------------------------------------ */

export const INVOICE_STATUSES = [
  "DRAFT", "ISSUED", "SENT", "PARTIALLY_PAID", "PAID",
  "OVERDUE", "CANCELLED", "DISPUTED", "REFUNDED", "WRITTEN_OFF",
] as const;

export const INVOICE_TYPE_LABELS: Record<string, string> = { INVOICE: "請求書", CREDIT_NOTE: "返還請求書", PROFORMA: "仮請求書" };

export const INVOICE_TYPES = ["INVOICE", "CREDIT_NOTE", "PROFORMA"] as const;

/* ------------------------------------------------------------------ */
/*  Line item schema                                                   */
/* ------------------------------------------------------------------ */

export const lineItemInputSchema = z.object({
  position: z.number().int().min(0),
  productId: z.string().uuid().optional().nullable(),
  description: z.string().min(1, "品名・内容を入力してください"),
  quantity: z.number().positive("Quantity must be positive"),
  unitPrice: z.number().min(0, "単価は0以上にしてください"),
  discountPercent: z.number().min(0).max(100).default(0),
  taxRateId: z.string().uuid().optional().nullable(),
});

export type LineItemInput = z.infer<typeof lineItemInputSchema>;

/* ------------------------------------------------------------------ */
/*  Create invoice schema                                              */
/* ------------------------------------------------------------------ */

export const createInvoiceSchema = z.object({
  type: z.enum(INVOICE_TYPES).default("INVOICE"),
  accountId: z.string().uuid("Invalid account ID"),
  seriesId: z.string().uuid().optional().nullable(),
  currency: z.string().length(3, "Currency must be a 3-letter code"),
  issueDate: z.coerce.date().optional().nullable(),
  taxableSupplyDate: z.coerce.date().optional().nullable(),
  dueDate: z.coerce.date().optional().nullable(),
  bankName: z.string().optional().nullable(),
  bankAccount: z.string().optional().nullable(),
  iban: z.string().optional().nullable(),
  swift: z.string().optional().nullable(),
  variableSymbol: z.string().optional().nullable(),
  publicNotes: z.string().optional().nullable(),
  internalNotes: z.string().optional().nullable(),
  lineItems: z.array(lineItemInputSchema).min(1, "明細を1行以上追加してください"),
  originalInvoiceId: z.string().uuid().optional().nullable(),
});

export type CreateInvoiceInput = z.infer<typeof createInvoiceSchema>;

/* ------------------------------------------------------------------ */
/*  Update invoice schema (partial — only for DRAFT)                   */
/* ------------------------------------------------------------------ */

export const updateInvoiceSchema = z.object({
  accountId: z.string().uuid().optional(),
  currency: z.string().length(3).optional(),
  issueDate: z.coerce.date().optional().nullable(),
  taxableSupplyDate: z.coerce.date().optional().nullable(),
  dueDate: z.coerce.date().optional().nullable(),
  bankName: z.string().optional().nullable(),
  bankAccount: z.string().optional().nullable(),
  iban: z.string().optional().nullable(),
  swift: z.string().optional().nullable(),
  variableSymbol: z.string().optional().nullable(),
  publicNotes: z.string().optional().nullable(),
  internalNotes: z.string().optional().nullable(),
  lineItems: z.array(lineItemInputSchema).min(1).optional(),
});

export type UpdateInvoiceInput = z.infer<typeof updateInvoiceSchema>;

/* ------------------------------------------------------------------ */
/*  Issue invoice schema                                               */
/* ------------------------------------------------------------------ */

export const issueInvoiceSchema = z.object({
  invoiceId: z.string().uuid(),
  issueDate: z.coerce.date().optional(),
  dueDate: z.coerce.date().optional(),
  taxableSupplyDate: z.coerce.date().optional(),
});

export type IssueInvoiceInput = z.infer<typeof issueInvoiceSchema>;

/* ------------------------------------------------------------------ */
/*  Add payment schema                                                 */
/* ------------------------------------------------------------------ */

export const addPaymentSchema = z.object({
  invoiceId: z.string().uuid(),
  amount: z.number().positive("Payment amount must be positive"),
  paidAt: z.coerce.date(),
  method: z.string().min(1, "入金方法を選択してください"),
  reference: z.string().optional().nullable(),
  note: z.string().optional().nullable(),
});

export type AddPaymentInput = z.infer<typeof addPaymentSchema>;
