import { getConfigValues } from "./_actions/crm-settings";
import { CrmSettingsTabs } from "./_components/CrmSettingsTabs";

export default async function CrmSettingsPage() {
  const [
    industries,
    contactTypes,
    leadSources,
    leadStatuses,
    leadTypes,
    opportunityTypes,
    salesStages,
  ] = await Promise.all([
    getConfigValues("industry"),
    getConfigValues("contactType"),
    getConfigValues("leadSource"),
    getConfigValues("leadStatus"),
    getConfigValues("leadType"),
    getConfigValues("opportunityType"),
    getConfigValues("salesStage"),
  ]);

  const tabs = [
    { key: "industry" as const,        label: "業種",        values: industries },
    { key: "contactType" as const,     label: "連絡先の種別",     values: contactTypes },
    { key: "leadSource" as const,      label: "見込み客の獲得経路",      values: leadSources },
    { key: "leadStatus" as const,      label: "見込み客の状態",     values: leadStatuses },
    { key: "leadType" as const,        label: "見込み客の種別",        values: leadTypes },
    { key: "opportunityType" as const, label: "商談の種別", values: opportunityTypes },
    { key: "salesStage" as const,      label: "商談段階",      values: salesStages },
  ];

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-bold tracking-tight">{"営業管理の設定"}</h1>
        <p className="text-muted-foreground text-sm mt-1">
          {"営業管理で使う選択肢と初期値を管理します。"}</p>
      </div>
      <CrmSettingsTabs tabs={tabs} />
    </div>
  );
}
