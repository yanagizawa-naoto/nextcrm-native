import path from "node:path";
import {
  Font,
  Document,
  Page,
  Text,
  View,
  StyleSheet,
} from "@react-pdf/renderer";
import { getPdfStrings, type PdfStrings } from "../i18n";

// Ship the font with the app so PDF creation also works offline.
Font.register({family: "NotoSansJP", fonts: [
  { src: path.resolve(process.cwd(), "public/fonts/NotoSansJP-Regular.ttf"), fontWeight: 400 },
  { src: path.resolve(process.cwd(), "public/fonts/NotoSansJP-Bold.ttf"), fontWeight: 700 },
]});

/* ------------------------------------------------------------------ */
/*  Data interfaces                                                    */
/* ------------------------------------------------------------------ */

export interface PdfParty {
  name: string;
  street?: string;
  city?: string;
  zip?: string;
  country?: string;
  vatId?: string;
  regId?: string;
}

export interface PdfLineItem {
  position: number;
  description: string;
  quantity: string;
  unitPrice: string;
  discountPercent: string;
  taxRate: string;
  lineTotal: string;
}

export interface PdfVatBucket {
  rate: string;
  base: string;
  vat: string;
}

export interface PdfPaymentInfo {
  bankName?: string;
  iban?: string;
  swift?: string;
  variableSymbol?: string;
}

export interface InvoicePdfData {
  type: "INVOICE" | "CREDIT_NOTE" | "PROFORMA";
  number: string;
  issueDate: string;
  dueDate?: string;
  taxableSupplyDate?: string;
  locale: string;
  currency: string;

  supplier: PdfParty;
  customer: PdfParty;

  lineItems: PdfLineItem[];

  subtotal: string;
  vatTotal: string;
  grandTotal: string;
  vatBreakdown: PdfVatBucket[];

  payment?: PdfPaymentInfo;
  publicNotes?: string;
}

/* ------------------------------------------------------------------ */
/*  Styles                                                             */
/* ------------------------------------------------------------------ */

const s = StyleSheet.create({
  page: { padding: 40, fontSize: 9, fontFamily: "NotoSansJP", fontWeight: 400 },
  header: { flexDirection: "row", justifyContent: "space-between", marginBottom: 20 },
  title: { fontSize: 18, fontFamily: "NotoSansJP", fontWeight: 700 },
  metaLabel: { fontSize: 8, color: "#666" },
  metaValue: { fontSize: 10, fontFamily: "NotoSansJP", fontWeight: 700 },
  section: { marginBottom: 12 },
  parties: { flexDirection: "row", justifyContent: "space-between", marginBottom: 20 },
  partyBox: { width: "48%" },
  partyTitle: { fontSize: 10, fontFamily: "NotoSansJP", fontWeight: 700, marginBottom: 4 },
  partyLine: { fontSize: 9, marginBottom: 1 },
  table: { marginBottom: 12 },
  tableHeader: {
    flexDirection: "row",
    borderBottomWidth: 1,
    borderBottomColor: "#333",
    paddingBottom: 4,
    marginBottom: 4,
    fontFamily: "NotoSansJP", fontWeight: 700,
  },
  tableRow: {
    flexDirection: "row",
    paddingVertical: 2,
    borderBottomWidth: 0.5,
    borderBottomColor: "#ddd",
  },
  colPos: { width: "5%" },
  colDesc: { width: "30%" },
  colQty: { width: "10%", textAlign: "right" },
  colPrice: { width: "15%", textAlign: "right" },
  colDisc: { width: "10%", textAlign: "right" },
  colVat: { width: "10%", textAlign: "right" },
  colTotal: { width: "20%", textAlign: "right" },
  totalsBox: { alignSelf: "flex-end", width: "40%", marginTop: 8 },
  totalsRow: { flexDirection: "row", justifyContent: "space-between", paddingVertical: 2 },
  totalsLabel: { fontSize: 9 },
  totalsValue: { fontSize: 9, fontFamily: "NotoSansJP", fontWeight: 700, textAlign: "right" },
  grandRow: {
    flexDirection: "row",
    justifyContent: "space-between",
    paddingVertical: 4,
    borderTopWidth: 1,
    borderTopColor: "#333",
    marginTop: 2,
  },
  grandLabel: { fontSize: 11, fontFamily: "NotoSansJP", fontWeight: 700 },
  grandValue: { fontSize: 11, fontFamily: "NotoSansJP", fontWeight: 700, textAlign: "right" },
  paymentBox: { marginTop: 16, padding: 8, backgroundColor: "#f5f5f5" },
  paymentTitle: { fontSize: 10, fontFamily: "NotoSansJP", fontWeight: 700, marginBottom: 4 },
  paymentLine: { fontSize: 9, marginBottom: 1 },
  notes: { marginTop: 12, fontSize: 8, color: "#555" },
  footer: { position: "absolute", bottom: 20, left: 40, right: 40, fontSize: 7, color: "#999", textAlign: "center" },
});

/* ------------------------------------------------------------------ */
/*  Helpers                                                            */
/* ------------------------------------------------------------------ */

function typeTitle(type: InvoicePdfData["type"], t: PdfStrings): string {
  switch (type) {
    case "CREDIT_NOTE": return t.creditNote;
    case "PROFORMA": return t.proforma;
    default: return t.invoice;
  }
}

function PartyBlock({ party, label, t }: { party: PdfParty; label: string; t: PdfStrings }) {
  return (
    <View style={s.partyBox}>
      <Text style={s.partyTitle}>{label}</Text>
      <Text style={s.partyLine}>{party.name}</Text>
      {party.street && <Text style={s.partyLine}>{party.street}</Text>}
      {(party.zip || party.city) && (
        <Text style={s.partyLine}>
          {[party.zip, party.city].filter(Boolean).join(" ")}
        </Text>
      )}
      {party.country && <Text style={s.partyLine}>{party.country}</Text>}
      {party.regId && <Text style={s.partyLine}>{t.regId}: {party.regId}</Text>}
      {party.vatId && <Text style={s.partyLine}>{t.vatId}: {party.vatId}</Text>}
    </View>
  );
}

/* ------------------------------------------------------------------ */
/*  Document                                                           */
/* ------------------------------------------------------------------ */

export function InvoicePdf({ data }: { data: InvoicePdfData }) {
  const t = getPdfStrings(data.locale);
  const money = (value: string) => new Intl.NumberFormat(data.locale === "ja" ? "ja-JP" : "en-US", {
    style: "currency", currency: data.currency,
    maximumFractionDigits: data.currency === "JPY" && Number.isInteger(Number(value)) ? 0 : 2,
  }).format(Number(value));
  const date = (value: string) => data.locale === "ja" ? value.replace(/^(\d{4})-(\d{2})-(\d{2})$/, "$1年$2月$3日") : value;

  return (
    <Document>
      <Page size="A4" style={s.page}>
        {/* Header */}
        <View style={s.header}>
          <View>
            <Text style={s.title}>{typeTitle(data.type, t)}</Text>
            <Text style={s.metaValue}>{data.number}</Text>
          </View>
          <View>
            <Text style={s.metaLabel}>{t.issueDate}</Text>
            <Text style={s.metaValue}>{date(data.issueDate)}</Text>
            {data.dueDate && (
              <>
                <Text style={s.metaLabel}>{t.dueDate}</Text>
                <Text style={s.metaValue}>{date(data.dueDate)}</Text>
              </>
            )}
            {data.taxableSupplyDate && (
              <>
                <Text style={s.metaLabel}>{t.taxableSupplyDate}</Text>
                <Text style={s.metaValue}>{date(data.taxableSupplyDate)}</Text>
              </>
            )}
          </View>
        </View>

        {/* Parties */}
        <View style={s.parties}>
          <PartyBlock party={data.supplier} label={t.supplier} t={t} />
          <PartyBlock party={data.customer} label={t.customer} t={t} />
        </View>

        {/* Line items table */}
        <View style={s.table}>
          <View style={s.tableHeader}>
            <Text style={s.colPos}>#</Text>
            <Text style={s.colDesc}>{t.description}</Text>
            <Text style={s.colQty}>{t.qty}</Text>
            <Text style={s.colPrice}>{t.unitPrice}</Text>
            <Text style={s.colDisc}>{t.discount}</Text>
            <Text style={s.colVat}>{t.vat}</Text>
            <Text style={s.colTotal}>{t.lineTotal}</Text>
          </View>
          {data.lineItems.map((li) => (
            <View style={s.tableRow} key={li.position}>
              <Text style={s.colPos}>{li.position}</Text>
              <Text style={s.colDesc}>{li.description}</Text>
              <Text style={s.colQty}>{li.quantity}</Text>
              <Text style={s.colPrice}>{money(li.unitPrice)}</Text>
              <Text style={s.colDisc}>{li.discountPercent}%</Text>
              <Text style={s.colVat}>{li.taxRate}%</Text>
              <Text style={s.colTotal}>{money(li.lineTotal)}</Text>
            </View>
          ))}
        </View>

        {/* Totals */}
        <View style={s.totalsBox}>
          <View style={s.totalsRow}>
            <Text style={s.totalsLabel}>{t.subtotal}</Text>
            <Text style={s.totalsValue}>{money(data.subtotal)}</Text>
          </View>
          {data.vatBreakdown.map((vb) => (
            <View style={s.totalsRow} key={vb.rate}>
              <Text style={s.totalsLabel}>{t.vat} {vb.rate}%</Text>
              <Text style={s.totalsValue}>{money(vb.vat)}</Text>
            </View>
          ))}
          <View style={s.totalsRow}>
            <Text style={s.totalsLabel}>{t.vatTotal}</Text>
            <Text style={s.totalsValue}>{money(data.vatTotal)}</Text>
          </View>
          <View style={s.grandRow}>
            <Text style={s.grandLabel}>{t.grandTotal}</Text>
            <Text style={s.grandValue}>{money(data.grandTotal)}</Text>
          </View>
        </View>

        {/* Payment info */}
        {data.payment && (
          <View style={s.paymentBox}>
            <Text style={s.paymentTitle}>{t.paymentInstructions}</Text>
            {data.payment.bankName && (
              <Text style={s.paymentLine}>{t.bank}: {data.payment.bankName}</Text>
            )}
            {data.payment.iban && (
              <Text style={s.paymentLine}>{t.iban}: {data.payment.iban}</Text>
            )}
            {data.payment.swift && (
              <Text style={s.paymentLine}>{t.swift}: {data.payment.swift}</Text>
            )}
            {data.payment.variableSymbol && (
              <Text style={s.paymentLine}>{t.variableSymbol}: {data.payment.variableSymbol}</Text>
            )}
          </View>
        )}

        {/* Notes */}
        {data.publicNotes && (
          <Text style={s.notes}>{data.publicNotes}</Text>
        )}

        {/* Footer with page numbers */}
        <Text
          style={s.footer}
          render={({ pageNumber, totalPages }) =>
            `${t.page} ${pageNumber} ${t.of} ${totalPages}`
          }
          fixed
        />
      </Page>
    </Document>
  );
}
