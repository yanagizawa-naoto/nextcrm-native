"use server";
import { revalidatePath } from "next/cache";
import { revokeAllApiTokens } from "@/lib/api-tokens";
import {
  requireRole,
  AuthenticationError,
  AuthorizationError,
} from "@/lib/authz";

export const revokeUserApiTokens = async (userId: string) => {
  try {
    await requireRole(["admin"]);
  } catch (e) {
    if (e instanceof AuthenticationError) return { error: "ログインが必要です" };
    if (e instanceof AuthorizationError) return { error: "操作する権限がありません" };
    throw e;
  }

  if (!userId) return { error: "ユーザーIDを入力してください" };

  try {
    const revoked = await revokeAllApiTokens(userId);
    revalidatePath("/[locale]/(routes)/admin", "page");
    return { data: { revoked } };
  } catch (error) {
    console.log("[REVOKE_USER_API_TOKENS]", error);
    return { error: "APIトークンを失効できませんでした" };
  }
};
