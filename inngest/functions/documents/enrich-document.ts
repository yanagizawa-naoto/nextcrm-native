import { inngest } from "@/inngest/client";
import { prismadb } from "@/lib/prisma";
import {
  generateEmbedding,
  toVectorLiteral,
  computeContentHash,
} from "@/inngest/lib/embedding-utils";
import { GetObjectCommand } from "@aws-sdk/client-s3";
import { minioClient, MINIO_BUCKET } from "@/lib/minio";
import { extractDocumentText, iterateTextChunks } from "@/inngest/lib/document-text";
const MAX_SINGLE_EMBED_CHARS = 8000 * 4; // ~8000 tokens

async function fetchFileBody(key: string): Promise<AsyncIterable<Uint8Array>> {
  const response = await minioClient.send(
    new GetObjectCommand({ Bucket: MINIO_BUCKET, Key: key })
  );
  return response.Body as AsyncIterable<Uint8Array>;
}

function classifyByFilename(name: string): "RECEIPT" | "CONTRACT" | "OFFER" | "OTHER" {
  const lower = name.toLowerCase();
  if (/invoice|receipt|bill|payment|請求|領収|支払/.test(lower)) return "RECEIPT";
  if (/contract|agreement|nda|terms|契約|規約/.test(lower)) return "CONTRACT";
  if (/offer|quote|proposal|estimate|見積|提案/.test(lower)) return "OFFER";
  return "OTHER";
}

export const enrichDocument = inngest.createFunction(
  {
    id: "document-enrich",
    name: "Enrich Document",
    triggers: [{ event: "document/uploaded" }],
    retries: 3,
    ...(process.env.NEXTCRM_DESKTOP === "1" ? { concurrency: { limit: 1 } } : {}),
  },
  async ({ event, step }) => {
    const { documentId } = event.data as { documentId: string };

    const document = await step.run("load-document", async () => {
      const doc = await prismadb.documents.findUnique({
        where: { id: documentId },
        select: {
          id: true,
          key: true,
          document_name: true,
          document_file_mimeType: true,
          document_system_type: true,
        },
      });
      if (!doc) throw new Error(`Document ${documentId} not found`);
      return doc;
    });

    // Step 1: Extract text
    const contentText = await step.run("extract-text", async () => {
      if (!document.key) return null;

      const text = await extractDocumentText(document.document_file_mimeType, () => fetchFileBody(document.key!));

      await prismadb.documents.update({
        where: { id: documentId },
        data: {
          content_text: text,
          processing_status: "PROCESSING",
        },
      });

      return text;
    });

    if (!contentText || !process.env.OPENAI_API_KEY) {
      // Images and unsupported types — apply filename-based classification only
      await step.run("classify-by-filename", async () => {
        const systemType = classifyByFilename(document.document_name);
        await prismadb.documents.update({
          where: { id: documentId },
          data: {
            document_system_type: systemType,
            processing_status: "READY",
          },
        });
      });
      return { documentId, status: "ready", enriched: false };
    }

    const { default: OpenAI } = await import("openai");
    const openai = new OpenAI({ apiKey: process.env.OPENAI_API_KEY });

    // Step 2: Generate embeddings
    await step.run("generate-embedding", async () => {
      if (contentText.length <= MAX_SINGLE_EMBED_CHARS) {
        // Single embedding on the document
        const embedding = await generateEmbedding(contentText);
        const vector = toVectorLiteral(embedding);
        const hash = computeContentHash(contentText);

        await prismadb.$executeRaw`
          INSERT INTO "crm_Embeddings_Documents" ("id", "document_id", "embedding", "content_hash", "embedded_at")
          VALUES (gen_random_uuid(), ${documentId}::uuid, ${vector}::vector, ${hash}, NOW())
          ON CONFLICT ("document_id")
          DO UPDATE SET "embedding" = EXCLUDED."embedding",
                        "content_hash" = EXCLUDED."content_hash",
                        "embedded_at" = NOW()
        `;
      } else {
        // Chunked embeddings
        // Delete old chunks if re-processing
        await prismadb.crm_Document_Chunks.deleteMany({
          where: { document_id: documentId },
        });

        let i = 0;
        const chunks = iterateTextChunks(contentText);
        for (let next = chunks.next(); !next.done; next = chunks.next()) {
          const chunk = next.value;
          const embedding = await generateEmbedding(chunk);
          const vector = toVectorLiteral(embedding);

          await prismadb.$executeRaw`
            INSERT INTO "crm_Document_Chunks" ("id", "document_id", "chunk_index", "chunk_text", "embedding", "embedded_at")
            VALUES (gen_random_uuid(), ${documentId}::uuid, ${i}, ${chunk}, ${vector}::vector, NOW())
          `;
          i++;
        }
      }
    });

    // Step 3: Generate summary
    const summary = await step.run("generate-summary", async () => {
      const truncated = contentText.slice(0, 12000); // ~3000 tokens for summary input
      const response = await openai.chat.completions.create({
        model: "gpt-4o-mini",
        messages: [
          {
            role: "system",
            content: "次の文書の目的と主な内容を、日本語で簡潔な2〜3文に要約してください。",
          },
          { role: "user", content: truncated },
        ],
        max_tokens: 200,
      });

      const summaryText = response.choices[0]?.message?.content ?? null;
      await prismadb.documents.update({
        where: { id: documentId },
        data: { summary: summaryText },
      });
      return summaryText;
    });

    // Step 4: AI classification
    await step.run("ai-classify", async () => {
      const truncated = contentText.slice(0, 4000);
      const response = await openai.chat.completions.create({
        model: "gpt-4o-mini",
        messages: [
          {
            role: "system",
            content:
              "Classify this document into exactly one of these categories: RECEIPT, CONTRACT, OFFER, OTHER. Respond with only the category name, nothing else.",
          },
          {
            role: "user",
            content: `Document name: ${document.document_name}\n\nSummary: ${summary}\n\nContent excerpt:\n${truncated}`,
          },
        ],
        max_tokens: 10,
      });

      const raw = response.choices[0]?.message?.content?.trim().toUpperCase() ?? "OTHER";
      const systemType = ["RECEIPT", "CONTRACT", "OFFER", "OTHER"].includes(raw)
        ? (raw as "RECEIPT" | "CONTRACT" | "OFFER" | "OTHER")
        : "OTHER";

      await prismadb.documents.update({
        where: { id: documentId },
        data: {
          document_system_type: systemType,
          processing_status: "READY",
        },
      });
    });

    return { documentId, status: "ready", enriched: true };
  }
);
