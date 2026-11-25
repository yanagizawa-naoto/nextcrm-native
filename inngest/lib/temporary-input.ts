import { mkdtemp, rm } from "node:fs/promises";
import { createWriteStream } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { Readable } from "node:stream";
import { pipeline } from "node:stream/promises";

/** Give a filename-based decoder an input without retaining the source in RAM. */
export async function withTemporaryInput<T>(body: AsyncIterable<Uint8Array>, use: (filename: string) => Promise<T>): Promise<T> {
  const directory = await mkdtemp(path.join(tmpdir(), "nextcrm-image-"));
  try {
    const filename = path.join(directory, "input");
    await pipeline(Readable.from(body), createWriteStream(filename, { flags: "wx", mode: 0o600 }));
    return await use(filename);
  } finally { await rm(directory, { recursive: true, force: true }); }
}
