import { getSession } from "@/lib/auth-server";
import { getLocalObject, usesLocalStorage } from "@/lib/local-storage";

export async function GET(_request: Request, { params }: { params: Promise<{ filename: string }> }) {
  if (!usesLocalStorage()) return new Response(null, { status: 404 });
  if (!await getSession()) return new Response(null, { status: 401 });
  const { filename } = await params;
  if (!/^[a-f0-9-]{36}\.(png|jpg|gif|webp)$/.test(filename)) return new Response(null, { status: 404 });
  try {
    const object = await getLocalObject(`avatars/${filename}`);
    if (!/^image\/(png|jpeg|gif|webp)$/.test(object.ContentType)) {
      object.Body.destroy();
      return new Response(null, { status: 404 });
    }
    return new Response(object.Body.transformToWebStream() as ReadableStream<Uint8Array>, { headers: {
      "Content-Type": object.ContentType, "Content-Length": String(object.ContentLength),
      "Cache-Control": "private, no-store", "X-Content-Type-Options": "nosniff",
    } });
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return new Response(null, { status: 404 });
    throw error;
  }
}
