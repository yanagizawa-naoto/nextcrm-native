"use server";
import { getSession } from "@/lib/auth-server";
import { prismadb } from "@/lib/prisma";
import { revalidatePath } from "next/cache";
import { Language } from "@prisma/client";

export const setLanguage = async (data: {
  userId: string;
  language: string;
}) => {
  const session = await getSession({ partner: true });
  if (!session) return { error: "ログインが必要です" };

  const { userId, language } = data;

  if (!userId) return { error: "ユーザーIDを入力してください" };
  if (!language) return { error: "言語を入力してください" };

  // Ensure user can only update their own language unless admin
  if (session.user.id !== userId && session.user.role !== "admin") {
    return { error: "操作する権限がありません" };
  }

  try {
    await prismadb.users.update({
      data: { userLanguage: language as Language },
      where: { id: userId },
    });
    revalidatePath("/[locale]/(routes)/profile", "page");
    return { language };
  } catch (error) {
    console.log("[SET_LANGUAGE]", error);
    return { error: "言語を設定できませんでした" };
  }
};
