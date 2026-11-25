import ResendCard from "../_components/ResendCard";
import { getSession } from "@/lib/auth-server";
import Container from "../../components/ui/Container";
import { getTranslations } from "next-intl/server";

export default async function ServicesPage() {
  const session = await getSession();
  const t = await getTranslations("AdminPage");

  // The admin layout already gates on requireRole(["admin"]); this page-level
  // check mirrors the other admin pages as defense-in-depth. The Resend key
  // write itself is authorized in the setResendKey server action.
  if (session?.user?.role !== "admin") {
    return (
      <Container title="外部サービス" description="外部サービス連携">
        <div className="flex w-full h-full items-center justify-center">
          {t("accessNotAllowed")}
        </div>
      </Container>
    );
  }

  return (
    <Container
      title="外部サービス"
      description="外部サービスの接続設定です。環境変数をシステム共通設定より優先します。"
    >
      <div className="space-y-6 max-w-2xl">
        <ResendCard />
      </div>
    </Container>
  );
}
