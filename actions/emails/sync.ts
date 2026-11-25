"use server";
import { getSession } from "@/lib/auth-server";

import { prismadb } from "@/lib/prisma";
import { inngest } from "@/inngest/client";

async function requireSession() {
  const session = await getSession();
  if (!session?.user?.id) throw new Error("ログインが必要です");
  return session.user.id as string;
}

export async function triggerSync(accountId: string) {
  const userId = await requireSession();

  const account = await prismadb.emailAccount.findFirst({
    where: { id: accountId, userId },
    select: { id: true },
  });
  if (!account) throw new Error("取引先が見つかりません");

  await inngest.send({ name: "email/sync-account", data: { accountId } });
}
