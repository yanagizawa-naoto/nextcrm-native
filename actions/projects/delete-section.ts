"use server";
import { prismadb } from "@/lib/prisma";
import { revalidatePath } from "next/cache";
import {
  requireAuthenticated,
  assertCanWriteBoard,
  AuthenticationError,
  AuthorizationError,
} from "@/lib/authz";

export const deleteSection = async (sectionId: string) => {
  let user;
  try {
    user = await requireAuthenticated();
  } catch (e) {
    if (e instanceof AuthenticationError) return { error: "ログインが必要です" };
    throw e;
  }

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
    await prismadb.tasks.deleteMany({
      where: { section: sectionId },
    });

    await prismadb.sections.delete({
      where: { id: sectionId },
    });

    revalidatePath("/[locale]/(routes)/projects", "page");
    return { success: true };
  } catch (error) {
    console.log("[DELETE_SECTION]", error);
    return { error: "セクションを削除できませんでした" };
  }
};
