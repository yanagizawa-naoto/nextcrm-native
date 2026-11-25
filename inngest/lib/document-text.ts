import { StringDecoder } from "node:string_decoder";

type Body = AsyncIterable<Uint8Array>;
const WORD_TYPES = new Set([
  "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
  "application/msword",
]);

export async function extractDocumentText(mimeType: string, loadBody: () => Promise<Body>): Promise<string | null> {
  // Decide whether there is work before opening or copying the source file.
  if (mimeType !== "text/plain" && mimeType !== "application/pdf" && !WORD_TYPES.has(mimeType)) return null;
  const body = await loadBody();
  if (mimeType === "text/plain") {
    const decoder = new StringDecoder("utf8");
    let text = "";
    for await (const chunk of body) text += decoder.write(Buffer.from(chunk.buffer, chunk.byteOffset, chunk.byteLength));
    text += decoder.end();
    return text || null;
  }
  // These parsers require a complete buffer. Plain text never takes this path.
  const chunks: Uint8Array[] = [];
  for await (const chunk of body) chunks.push(chunk);
  const buffer = Buffer.concat(chunks);
  if (mimeType === "application/pdf") {
    const { PDFParse } = await import("pdf-parse");
    const parser = new PDFParse({ data: buffer });
    try { return (await parser.getText()).text || null; }
    finally { await parser.destroy(); }
  }
  const mammoth = await import("mammoth");
  return (await mammoth.extractRawText({ buffer })).value || null;
}

/** Yield one overlapping window at a time; never retain a list of all windows. */
export function* iterateTextChunks(text: string, size = 2048, overlap = 200): Generator<string> {
  if (!Number.isInteger(size) || !Number.isInteger(overlap) || size <= 0 || overlap < 0 || overlap >= size) {
    throw new RangeError("Invalid text chunk size or overlap");
  }
  for (let start = 0; start < text.length;) {
    const end = Math.min(start + size, text.length);
    yield text.slice(start, end);
    if (end === text.length) break;
    start = end - overlap;
  }
}
