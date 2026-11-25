import type { InvoicePdfData } from "./templates/default-invoice";

export async function renderInvoicePdf(data: InvoicePdfData): Promise<Buffer> {
  const [{ renderToBuffer }, { InvoicePdf }] = await Promise.all([
    import("@react-pdf/renderer"), import("./templates/default-invoice"),
  ]);
  return renderToBuffer(<InvoicePdf data={data} />);
}
