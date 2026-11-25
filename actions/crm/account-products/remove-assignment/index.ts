"use server";
import { prismadb } from "@/lib/prisma";
import {
  requireAuthenticated,
  assertCanWriteAccount,
  AuthenticationError,
  AuthorizationError,
} from "@/lib/authz";
import { writeAuditLog } from "@/lib/audit-log";
import { revalidatePath } from "next/cache";

export const removeAssignment = async (id: string) => {
  let user;
  try {
    user = await requireAuthenticated();
  } catch (e) {
    if (e instanceof AuthenticationError) return { error: "ログインが必要です" };
    throw e;
  }

  const existing = await prismadb.crm_AccountProducts.findUnique({
    where: { id },
    select: { accountId: true },
  });
  if (!existing) {
    return { error: "見つかりません" };
  }

  try {
    await assertCanWriteAccount(user, existing.accountId);
  } catch (e) {
    if (e instanceof AuthorizationError) return { error: "操作する権限がありません" };
    throw e;
  }

  try {
    const assignment = await prismadb.crm_AccountProducts.update({
      where: { id },
      data: {
        status: "CANCELLED",
        updatedBy: user.id,
        v: { increment: 1 },
      },
    });

    await writeAuditLog({ entityType: "account_product", entityId: id, action: "cancelled", changes: null, userId: user.id });

    revalidatePath("/[locale]/(routes)/crm/accounts/[accountId]", "page");
    revalidatePath("/[locale]/(routes)/crm/products/[productId]", "page");
    return { data: { id: assignment.id } };
  } catch (error) {
    console.log("[REMOVE_ASSIGNMENT]", error);
    return { error: "割り当てを取り消しできませんでした" };
  }
};
