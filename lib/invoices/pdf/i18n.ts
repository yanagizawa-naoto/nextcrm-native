export interface PdfStrings {
  invoice: string;
  creditNote: string;
  proforma: string;
  issueDate: string;
  dueDate: string;
  taxableSupplyDate: string;
  supplier: string;
  customer: string;
  vatId: string;
  regId: string;
  description: string;
  qty: string;
  unitPrice: string;
  discount: string;
  vat: string;
  lineTotal: string;
  subtotal: string;
  vatTotal: string;
  grandTotal: string;
  paymentInstructions: string;
  bank: string;
  iban: string;
  swift: string;
  variableSymbol: string;
  page: string;
  of: string;
}

const EN: PdfStrings = {
  invoice: "Invoice",
  creditNote: "Credit Note",
  proforma: "Proforma Invoice",
  issueDate: "Issue Date",
  dueDate: "Due Date",
  taxableSupplyDate: "Taxable Supply Date",
  supplier: "Supplier",
  customer: "Customer",
  vatId: "VAT ID",
  regId: "Reg. ID",
  description: "Description",
  qty: "Qty",
  unitPrice: "Unit Price",
  discount: "Discount",
  vat: "VAT",
  lineTotal: "Total",
  subtotal: "Subtotal",
  vatTotal: "VAT Total",
  grandTotal: "Grand Total",
  paymentInstructions: "Payment Instructions",
  bank: "Bank",
  iban: "IBAN",
  swift: "SWIFT",
  variableSymbol: "Variable Symbol",
  page: "Page",
  of: "of",
};

const CZ: PdfStrings = {
  invoice: "Faktura",
  creditNote: "Dobropis",
  proforma: "Proforma faktura",
  issueDate: "Datum vystaveni",
  dueDate: "Datum splatnosti",
  taxableSupplyDate: "Datum zdanitelneho plneni",
  supplier: "Dodavatel",
  customer: "Odberatel",
  vatId: "DIC",
  regId: "ICO",
  description: "Popis",
  qty: "Mnozstvi",
  unitPrice: "Cena za jednotku",
  discount: "Sleva",
  vat: "DPH",
  lineTotal: "Celkem",
  subtotal: "Mezisouce",
  vatTotal: "DPH celkem",
  grandTotal: "Celkem k uhrade",
  paymentInstructions: "Platebni udaje",
  bank: "Banka",
  iban: "IBAN",
  swift: "SWIFT",
  variableSymbol: "Variabilni symbol",
  page: "Strana",
  of: "z",
};

const JA: PdfStrings = {
  invoice: "請求書", creditNote: "返金・減額通知書", proforma: "仮請求書",
  issueDate: "発行日", dueDate: "支払期限", taxableSupplyDate: "取引日",
  supplier: "請求元", customer: "請求先", vatId: "税務登録番号", regId: "法人番号・登録番号",
  description: "品名・内容", qty: "数量", unitPrice: "単価", discount: "値引率",
  vat: "税", lineTotal: "金額", subtotal: "小計", vatTotal: "税額合計", grandTotal: "ご請求金額",
  paymentInstructions: "お支払い情報", bank: "金融機関", iban: "IBAN", swift: "SWIFT",
  variableSymbol: "振込参照番号", page: "ページ", of: "／",
};

const bundles: Record<string, PdfStrings> = { en: EN, cs: CZ, cz: CZ, ja: JA };

export function getPdfStrings(locale: string): PdfStrings {
  return bundles[locale] ?? EN;
}
