// Desktop object storage. One atomically replaced file contains metadata and
// content; keys are hashed so object names can never become filesystem paths.
import { createHash, createHmac, randomUUID, timingSafeEqual } from "node:crypto";
import { createWriteStream } from "node:fs";
import { mkdir, open, rename, unlink } from "node:fs/promises";
import path from "node:path";
import { Readable } from "node:stream";
import { pipeline } from "node:stream/promises";

export function usesLocalStorage() {
  return process.env.NEXTCRM_DESKTOP === "1" && process.env.NEXTCRM_STORAGE_MODE === "local";
}

function validateKey(key: string) {
  if (!key || Buffer.byteLength(key) > 1024 || key.includes("\0")) throw new Error("保存キーが不正です");
}

function objectPath(key: string) {
  validateKey(key);
  const directory = process.env.NEXTCRM_STORAGE_DIR;
  if (!directory || !path.isAbsolute(directory)) throw new Error("ローカル保存先が未設定です");
  const hash = createHash("sha256").update(`${process.env.MINIO_BUCKET}\0${key}`).digest("hex");
  return path.join(directory, hash.slice(0, 2), `${hash}.object`);
}

type ObjectBody = string | Uint8Array | AsyncIterable<Uint8Array>;

export async function putLocalObject(key: string, body: ObjectBody, contentType = "application/octet-stream") {
  if (contentType.length > 256 || /[\r\n]/.test(contentType)) throw new Error("ファイル形式が不正です");
  const destination = objectPath(key);
  await mkdir(path.dirname(destination), { recursive: true, mode: 0o700 });
  const temporary = `${destination}.${randomUUID()}.tmp`;
  const hash = createHash("sha256");
  const chunks = typeof body === "string" || body instanceof Uint8Array ? [Buffer.from(body)] : body;
  async function* contents() {
    yield Buffer.from(JSON.stringify({ key, contentType }) + "\n");
    for await (const chunk of chunks) { hash.update(chunk); yield chunk; }
  }
  try {
    await pipeline(Readable.from(contents()), createWriteStream(temporary, { flags: "wx", mode: 0o600 }));
    // Flush before publishing, so a successful upload survives an app restart.
    const handle = await open(temporary, "r+");
    try { await handle.sync(); } finally { await handle.close(); }
    await rename(temporary, destination);
    return { ETag: `"${hash.digest("hex")}"` };
  } finally {
    await unlink(temporary).catch((error: NodeJS.ErrnoException) => { if (error.code !== "ENOENT") throw error; });
  }
}

export async function getLocalObject(key: string) {
  const filename = objectPath(key);
  const handle = await open(filename, "r");
  try {
    const header = Buffer.alloc(16 * 1024);
    const { bytesRead } = await handle.read(header, 0, header.length, 0);
    const end = header.subarray(0, bytesRead).indexOf(10);
    if (end < 0) throw new Error("保存ファイルのヘッダーが不正です");
    const metadata = JSON.parse(header.subarray(0, end).toString("utf8"));
    if (metadata.key !== key) throw new Error("保存キーが一致しません");
    const stat = await handle.stat();
    // Keep this exact inode open, even if the same key is concurrently replaced.
    const stream = handle.createReadStream({ start: end + 1, autoClose: true });
    return {
      Body: Object.assign(stream, {
        async transformToByteArray() {
          const chunks: Buffer[] = [];
          for await (const chunk of stream) chunks.push(Buffer.from(chunk));
          return Buffer.concat(chunks);
        },
        transformToWebStream: () => Readable.toWeb(stream),
      }),
      ContentType: metadata.contentType as string,
      ContentLength: stat.size - end - 1,
      LastModified: stat.mtime,
    };
  } catch (error) { await handle.close(); throw error; }
}

export async function deleteLocalObject(key: string) {
  await unlink(objectPath(key)).catch((error: NodeJS.ErrnoException) => { if (error.code !== "ENOENT") throw error; });
}

function signature(key: string, method: string, expires: string, contentType: string) {
  const secret = process.env.NEXTCRM_DESKTOP_TOKEN;
  if (!secret) throw new Error("ローカル保存用の認証設定がありません");
  return createHmac("sha256", secret).update(JSON.stringify(["storage-v1", key, method, expires, contentType])).digest("hex");
}

export function localObjectUrl(key: string, method: "GET" | "PUT", expiresIn: number, contentType = "") {
  validateKey(key);
  const expires = String(Math.floor(Date.now() / 1000) + Math.min(Math.max(expiresIn, 1), 604800));
  const url = new URL("/api/storage/local", process.env.NEXT_PUBLIC_APP_URL);
  url.search = new URLSearchParams({ key, method, expires, contentType, signature: signature(key, method, expires, contentType) }).toString();
  return url.toString();
}

export function validateLocalObjectUrl(url: URL, method: string, contentType = "") {
  const params = url.searchParams;
  const key = params.get("key") ?? "";
  const expires = params.get("expires") ?? "";
  const expectedType = params.get("contentType") ?? "";
  const supplied = params.get("signature") ?? "";
  if (!usesLocalStorage() || params.get("method") !== method || !/^\d+$/.test(expires) ||
      Number(expires) <= Math.floor(Date.now() / 1000) || !/^[a-f0-9]{64}$/.test(supplied) ||
      (method === "PUT" && expectedType !== contentType)) return null;
  try { validateKey(key); } catch { return null; }
  const expected = signature(key, method, expires, expectedType);
  return timingSafeEqual(Buffer.from(supplied), Buffer.from(expected)) ? key : null;
}

// This adapter implements the three S3 commands used by the CRM. The cloud
// implementation remains available when NEXTCRM_STORAGE_MODE is not local.
export const localStorageClient = {
  async send(command: { constructor: { name: string }; input: { Bucket?: string; Key?: string; Body?: unknown; ContentType?: string } }) {
    const { Bucket, Key, Body, ContentType } = command.input;
    if (Bucket !== process.env.MINIO_BUCKET || !Key) throw new Error("保存先が不正です");
    switch (command.constructor.name) {
      case "GetObjectCommand": return getLocalObject(Key);
      case "PutObjectCommand": return putLocalObject(Key, (Body ?? new Uint8Array()) as ObjectBody, ContentType);
      case "DeleteObjectCommand": await deleteLocalObject(Key); return {};
      default: throw new Error(`未対応の保存操作: ${command.constructor.name}`);
    }
  },
};
