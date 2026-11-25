"use server";
import { prismadb } from "@/lib/prisma";
import { writeAuditLog } from "@/lib/audit-log";
import { revalidatePath } from "next/cache";
import { requireRole, AuthenticationError, AuthorizationError } from "@/lib/authz";

export const deleteProduct = async (id: string) => {
  let actor;
  try {
    actor = await requireRole(["manager", "admin"]);
  } catch (e) {
    if (e instanceof AuthenticationError) return { error: "ログインが必要です" };
    if (e instanceof AuthorizationError) return { error: "操作する権限がありません" };
    throw e;
  }

  try {
    const existing = await prismadb.crm_Products.findUnique({ where: { id } });
    if (existing?.source === "EXTERNAL") return { error: "外部システムで管理されています" };
    await prismadb.crm_Products.update({
      where: { id },
      data: {
        deletedAt: new Date(),
        deletedBy: actor.id,
      },
    });

    await writeAuditLog({
      entityType: "product",
      entityId: id,
      action: "deleted",
      changes: null,
      userId: actor.id,
    });

    revalidatePath("/[locale]/(routes)/crm/products", "page");
    return { data: { id } };
  } catch (error) {
    console.log("[DELETE_PRODUCT]", error);
    return { error: "商品を削除できませんでした" };
  }
};
