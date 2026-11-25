"use server";
import { prismadb } from "@/lib/prisma";
import { revalidatePath } from "next/cache";
import {
  requireAuthenticated,
  assertCanWriteTargetList,
  AuthenticationError,
  AuthorizationError,
} from "@/lib/authz";

export const removeTargetFromList = async (targetListId: string, targetId: string) => {
  if (!targetId) return { error: "対象顧客IDを入力してください" };

  let user;
  try {
    user = await requireAuthenticated();
  } catch (e) {
    if (e instanceof AuthenticationError) return { error: "ログインが必要です" };
    throw e;
  }
  try {
    await assertCanWriteTargetList(user, targetListId);
  } catch (e) {
    if (e instanceof AuthorizationError) return { error: "操作する権限がありません" };
    throw e;
  }

  try {
    await prismadb.targetsToTargetLists.delete({
      where: {
        target_id_target_list_id: {
          target_id: targetId,
          target_list_id: targetListId,
        },
      },
    });
    revalidatePath("/[locale]/(routes)/campaigns/target-lists", "page");
    return { success: true };
  } catch (error) {
    return { error: "Failed to remove target from list" };
  }
};
