"use server";
import { prismadb } from "@/lib/prisma";
import { revalidatePath } from "next/cache";
import {
  requireAuthenticated,
  assertCanWriteBoard,
  AuthenticationError,
  AuthorizationError,
} from "@/lib/authz";

export const updateSectionTitle = async (data: {
  sectionId: string;
  newTitle: string;
}) => {
  let user;
  try {
    user = await requireAuthenticated();
  } catch (e) {
    if (e instanceof AuthenticationError) return { error: "ログインが必要です" };
    throw e;
  }

  const { sectionId, newTitle } = data;
  if (!sectionId) return { error: "Missing section ID" };

  const existing = await prismadb.sections.findUnique({
    where: { id: sectionId },
    select: { board: true },
  });
  if (!existing) return { error: "見つかりません" };

  try {
    await assertCanWriteBoard(user, existing.board);
  } catch (e) {
    if (e instanceof AuthorizationError) return { error: "操作する権限がありません" };
    throw e;
  }

  try {
    await prismadb.sections.update({
      where: { id: sectionId },
      data: { title: newTitle },
    });

    revalidatePath("/[locale]/(routes)/projects", "page");
    return { success: true };
  } catch (error) {
    console.log("[UPDATE_SECTION_TITLE]", error);
    return { error: "セクション名を更新できませんでした" };
  }
};
