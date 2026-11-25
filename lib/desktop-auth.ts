import { timingSafeEqual } from "node:crypto";
import { APIError, createAuthEndpoint } from "better-auth/api";
import { setSessionCookie } from "better-auth/cookies";
import type { BetterAuthPlugin } from "better-auth";
import { prismaBase } from "./prisma-base";

export function isDesktopRequestAllowed(request: Request, expectedToken: string | undefined): boolean {
  if (!expectedToken || expectedToken.length < 64) return false;
  const url = new URL(request.url);
  if (!["127.0.0.1", "localhost"].includes(url.hostname) || url.port !== "3210" ||
      request.headers.get("host") !== "127.0.0.1:3210") return false;
  const origin = request.headers.get("origin");
  if (origin && origin !== "http://127.0.0.1:3210") return false;
  const token = request.headers.get("authorization")?.replace(/^Bearer /, "") ?? "";
  const received = Buffer.from(token);
  const expected = Buffer.from(expectedToken);
  return received.length === expected.length && timingSafeEqual(received, expected);
}

// Only the local native app reads the private token. It never enters page JS,
// URLs, logs, or the client bundle. Normal web deployments do not enable this.
export const desktopAuth = (): BetterAuthPlugin => ({
  id: "nextcrm-desktop",
  endpoints: {
    desktopSignIn: createAuthEndpoint("/desktop", { method: "POST", requireHeaders: true }, async (ctx) => {
      if (process.env.NEXTCRM_DESKTOP !== "1" || !ctx.request ||
          !isDesktopRequestAllowed(ctx.request, process.env.NEXTCRM_DESKTOP_TOKEN)) {
        throw new APIError("UNAUTHORIZED", { message: "Macアプリからログインしてください。" });
      }
      const existing = await ctx.context.internalAdapter.findUserByEmail("local@nextcrm.local");
      const account = await prismaBase.users.findUnique({
        where: { email: "local@nextcrm.local" },
        select: { banned: true, userStatus: true },
      });
      if (!existing || !account || account.banned || account.userStatus !== "ACTIVE") {
        throw new APIError("FORBIDDEN", { message: "ローカルアカウントを利用できません。" });
      }
      const session = await ctx.context.internalAdapter.createSession(existing.user.id);
      if (!session) throw new APIError("INTERNAL_SERVER_ERROR", { message: "ログインできませんでした。" });
      await setSessionCookie(ctx, { session, user: existing.user });
      return ctx.redirect("/ja");
    }),
  },
});
