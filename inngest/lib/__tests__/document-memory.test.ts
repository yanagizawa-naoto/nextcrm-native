import { extractDocumentText, iterateTextChunks } from "../document-text";
import { withTemporaryInput } from "../temporary-input";
import { readFile, stat } from "node:fs/promises";
import sharp from "sharp";
import { PDFParse } from "pdf-parse";

jest.mock("pdf-parse", () => ({ PDFParse: jest.fn() }));

async function* bytes(buffer: Buffer, size = 1) {
  for (let offset = 0; offset < buffer.length; offset += size) yield buffer.subarray(offset, offset + size);
}

test("unsupported binary files are classified without reading their bodies", async () => {
  const load = jest.fn().mockRejectedValue(new Error("must not open"));
  for (const type of ["image/png", "image/jpeg", "video/mp4", "application/zip"]) {
    expect(await extractDocumentText(type, load)).toBeNull();
  }
  expect(load).not.toHaveBeenCalled();
});

test("streamed UTF-8 preserves Japanese, emoji, BOM and malformed trailing bytes", async () => {
  const input = Buffer.concat([Buffer.from("\ufeff日本語\n👨‍👩‍👧‍👦\n".repeat(300)), Buffer.from([0xe3, 0x81])]);
  for (const size of [1, 2, 7, 4096]) {
    expect(await extractDocumentText("text/plain", async () => bytes(input, size))).toBe(input.toString("utf8"));
  }
  expect(await extractDocumentText("text/plain", async () => bytes(Buffer.alloc(0)))).toBeNull();
});

test("PDF parser resources are released even if extraction fails", async () => {
  const destroy = jest.fn().mockResolvedValue(undefined);
  (PDFParse as unknown as jest.Mock).mockImplementation(() => ({ getText: jest.fn().mockRejectedValue(new Error("broken PDF")), destroy }));
  await expect(extractDocumentText("application/pdf", async () => bytes(Buffer.from("%PDF-broken")))).rejects.toThrow("broken PDF");
  expect(destroy).toHaveBeenCalledTimes(1);
});

test("lazy chunk windows preserve overlap and terminal boundary semantics", () => {
  expect(Array.from(iterateTextChunks("abcdefghij", 4, 1))).toEqual(["abcd", "defg", "ghij"]);
  expect(Array.from(iterateTextChunks("abcdefgh", 4, 0))).toEqual(["abcd", "efgh"]);
  expect(Array.from(iterateTextChunks("", 4, 1))).toEqual([]);
  expect(Array.from(iterateTextChunks("短文"))).toEqual(["短文"]);
  expect(() => Array.from(iterateTextChunks("a", 4, 4))).toThrow(RangeError);
});

test("disk-backed image decoding produces the same thumbnail and removes its private input", async () => {
  const source = await sharp({ create: { width: 640, height: 480, channels: 3, background: "#9070d8" } }).png().toBuffer();
  const expected = await sharp(source).resize(200, 200, { fit: "cover" }).png().toBuffer();
  let path = "";
  const actual = await withTemporaryInput(bytes(source, 13), async filename => {
    path = filename;
    expect((await stat(filename)).mode & 0o777).toBe(0o600);
    expect(await readFile(filename)).toEqual(source);
    return sharp(filename, { sequentialRead: true }).resize(200, 200, { fit: "cover" }).png().toBuffer();
  });
  expect(actual).toEqual(expected);
  await expect(stat(path)).rejects.toMatchObject({ code: "ENOENT" });
});

test("temporary image input is removed when decoding fails", async () => {
  let path = "";
  await expect(withTemporaryInput(bytes(Buffer.from("bad image")), async filename => {
    path = filename;
    throw new Error("decode failed");
  })).rejects.toThrow("decode failed");
  await expect(stat(path)).rejects.toMatchObject({ code: "ENOENT" });
});
