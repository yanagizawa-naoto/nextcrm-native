"use client";

import { useState } from "react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import type { FunnelTimingSettings } from "@/lib/crm/funnel-timers";
import { updateFunnelSettings } from "../_actions/funnel-settings";

const FIELDS: Array<{ key: keyof FunnelTimingSettings; label: string; group: string }> = [
  { key: "killAfterDays", label: "顧客から返信がない場合に商談を終了するまでの日数", group: "Kill rule" },
  { key: "recycleAfterDays", label: "営業ステップ終了後に営業対象を再開するまでの日数", group: "Recycle" },
  { key: "cadenceTouch1BusinessDays", label: "1回目の連絡：見積もり送付後の営業日数", group: "Follow-up cadence" },
  { key: "cadenceTouch2OffsetDays", label: "2回目の連絡：1回目からの日数", group: "Follow-up cadence" },
  { key: "cadenceTouch3OffsetDays", label: "3回目の連絡：2回目からの日数", group: "Follow-up cadence" },
  { key: "cadenceTouch4OffsetDays", label: "4回目の連絡：3回目からの日数", group: "Follow-up cadence" },
  { key: "cadenceTouch5OffsetDays", label: "5回目（最終）の連絡：3回目からの日数", group: "Follow-up cadence" },
  { key: "careCheckinDays", label: "フォロー連絡までの日数", group: "Care & renewals" },
  { key: "careReferralDays", label: "紹介依頼までの日数", group: "Care & renewals" },
  { key: "careQuarterIntervalDays", label: "定期フォローの間隔（日）", group: "Care & renewals" },
  { key: "careQuarterCount", label: "定期フォローの回数", group: "Care & renewals" },
  { key: "renewalWindowDays", label: "更新予定を表示するまでの残り日数", group: "Care & renewals" },
];

const FunnelSettingsForm = ({ initial }: { initial: FunnelTimingSettings }) => {
  const [values, setValues] = useState<FunnelTimingSettings>(initial);
  const [saving, setSaving] = useState(false);

  const save = async () => {
    setSaving(true);
    try {
      const res = await updateFunnelSettings(values);
      if (res.error) toast.error(res.error);
      else toast.success("営業フローの設定を保存しました");
    } catch {
      toast.error("営業フローの設定を保存できませんでした");
    } finally {
      setSaving(false);
    }
  };

  const groups = Array.from(new Set(FIELDS.map((f) => f.group)));

  return (
    <Card>
      <CardHeader>
        <CardTitle>{"営業フローの実行タイミング"}</CardTitle>
        <p className="text-sm text-muted-foreground">
          {"変更は今後の段階変更と次回の定期処理に適用されます。予約済みの連絡は元の予定を維持します。"}</p>
      </CardHeader>
      <CardContent className="space-y-6">
        {groups.map((group) => (
          <div key={group} className="space-y-2">
            <h3 className="text-sm font-semibold">{group}</h3>
            <div className="grid gap-3 md:grid-cols-2">
              {FIELDS.filter((f) => f.group === group).map((f) => (
                <label key={f.key} className="space-y-1 text-sm">
                  <span>{f.label}</span>
                  <Input
                    type="number"
                    min={0}
                    value={values[f.key]}
                    onChange={(e) =>
                      setValues((prev) => ({ ...prev, [f.key]: Number(e.target.value) }))
                    }
                  />
                </label>
              ))}
            </div>
          </div>
        ))}
        <Button onClick={save} disabled={saving}>
          {saving ? "保存中…" : "設定を保存"}
        </Button>
      </CardContent>
    </Card>
  );
};

export default FunnelSettingsForm;
