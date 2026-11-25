"use server";
import { getSession } from "@/lib/auth-server";
import {
  generateApiToken,
  listApiTokens,
  revokeApiToken,
} from "@/lib/api-tokens";

export async function createApiToken(data: {
  name: string;
  expiresAt?: Date;
}) {
  const session = await getSession();
  if (!session) return { error: "ログインが必要です" };
  // No API tokens for partners (partner-role spec, decision 6).
  if (session.user.role === "partner") return { error: "操作する権限がありません" };

  try {
    const result = await generateApiToken(
      session.user.id,
      data.name,
      data.expiresAt
    );
    return { data: result };
  } catch (error: any) {
    return { error: error.message ?? "Failed to create token" };
  }
}

export async function getApiTokens() {
  const session = await getSession();
  if (!session) return { error: "ログインが必要です" };

  try {
    const tokens = await listApiTokens(session.user.id);
    return { data: tokens };
  } catch {
    return { error: "トークンを取得できませんでした" };
  }
}

export async function deleteApiToken(tokenId: string) {
  const session = await getSession();
  if (!session) return { error: "ログインが必要です" };

  try {
    await revokeApiToken(tokenId, session.user.id);
    return { data: "ok" };
  } catch {
    return { error: "対象が見つからないか、アクセス権限がありません" };
  }
}
