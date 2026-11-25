import { Readable } from "node:stream";
import { getLocalObject, putLocalObject, validateLocalObjectUrl } from "@/lib/local-storage";

export const runtime = "nodejs";

export async function GET(request: Request) {
  const key = validateLocalObjectUrl(new URL(request.url), "GET");
  if (!key) return new Response("アクセスできません", { status: 403 });
  try {
    const object = await getLocalObject(key);
    const inline = /^(image\/(png|jpeg|gif|webp))$/.test(object.ContentType);
    return new Response(object.Body.transformToWebStream() as ReadableStream<Uint8Array>, {
      headers: {
        "Content-Type": object.ContentType,
        "Content-Length": String(object.ContentLength),
        "Content-Disposition": `${inline ? "inline" : "attachment"}; filename*=UTF-8''${encodeURIComponent(key.split("/").pop()!)}`,
        "Cache-Control": "private, no-store",
        "X-Content-Type-Options": "nosniff",
        "Content-Security-Policy": "default-src 'none'; sandbox",
      },
    });
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return new Response("ファイルが見つかりません", { status: 404 });
    throw error;
  }
}

export async function PUT(request: Request) {
  const contentType = request.headers.get("content-type") ?? "";
  const key = validateLocalObjectUrl(new URL(request.url), "PUT", contentType);
  if (!key) return new Response("アクセスできません", { status: 403 });
  const body = request.body ? Readable.fromWeb(request.body as Parameters<typeof Readable.fromWeb>[0]) : new Uint8Array();
  const result = await putLocalObject(key, body, contentType);
  return new Response(null, { status: 200, headers: { ETag: result.ETag } });
}
