"use server";
import { prismadb } from "@/lib/prisma";
import { inngest } from "@/inngest/client";
import {
  requireRole,
  assertCanReadCampaign,
  AuthenticationError,
  AuthorizationError,
} from "@/lib/authz";
import { campaignHasFirstStep, NO_FIRST_STEP_MESSAGE } from "@/lib/campaigns/first-step";

export const scheduleCampaign = async (id: string, scheduledAt: Date) => {
  let user;
  try {
    user = await requireRole(["manager", "admin"]);
  } catch (e) {
    if (e instanceof AuthenticationError) return { error: "ログインが必要です" };
    if (e instanceof AuthorizationError) return { error: "操作する権限がありません" };
    throw e;
  }

  try {
    await assertCanReadCampaign(user, id);
  } catch (e) {
    if (e instanceof AuthorizationError) return { error: "見つかりません" };
    throw e;
  }

  if (!(await campaignHasFirstStep(id))) return { error: NO_FIRST_STEP_MESSAGE };

  const campaign = await prismadb.crm_campaigns.update({
    where: { id },
    data: {
      status: "scheduled",
      scheduled_at: scheduledAt,
      steps: {
        updateMany: {
          where: { order: 0 },
          data: { scheduled_at: scheduledAt },
        },
      },
    },
  });

  await inngest.send({
    name: "campaigns/schedule",
    data: { campaignId: id, scheduledAt: scheduledAt.toISOString() },
  });

  return campaign;
};
