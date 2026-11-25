import { getCalendlySettings } from "@/lib/crm/calendar/calendly-settings";
import { CalendlyForm } from "./_components/CalendlyForm";

export default async function CalendarSettingsPage() {
  const settings = await getCalendlySettings();

  return (
    <div className="space-y-6 p-6">
      <div>
        <h1 className="text-2xl font-semibold">{"カレンダー設定"}</h1>
        <p className="text-sm text-muted-foreground">
          {"Calendlyで予約された面談を取り込むための連携設定です。"}</p>
      </div>
      <CalendlyForm
        hasToken={Boolean(settings.apiToken)}
        hasSigningKey={Boolean(settings.signingKey)}
        webhookUri={settings.webhookUri}
      />
    </div>
  );
}
