"use client";
import { useState } from "react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";

type FollowUpStep = {
  order: number;
  template_id: string;
  subject: string;
  delay_days: number;
  send_to: "all" | "non_openers";
};

type Template = { id: string; name: string };

type Props = {
  initialData: {
    send_now?: boolean;
    scheduled_at?: Date;
    followUpSteps?: FollowUpStep[];
  };
  templates: Template[];
  onSubmit: (data: {
    send_now: boolean;
    scheduled_at?: Date;
    followUpSteps: FollowUpStep[];
  }) => Promise<void>;
  onBack: () => void;
  isSubmitting: boolean;
};

export function Step4Schedule({
  initialData,
  templates,
  onSubmit,
  onBack,
  isSubmitting,
}: Props) {
  const [sendNow, setSendNow] = useState(initialData.send_now ?? false);
  const [scheduledAt, setScheduledAt] = useState<string>(() => {
    if (initialData.scheduled_at) {
      return new Date(initialData.scheduled_at).toISOString().slice(0, 16);
    }
    return "";
  });
  const [followUps, setFollowUps] = useState<FollowUpStep[]>(
    initialData.followUpSteps ?? []
  );
  const [error, setError] = useState("");

  const addFollowUp = () => {
    setFollowUps((prev) => [
      ...prev,
      {
        order: prev.length + 1,
        template_id: templates[0]?.id ?? "",
        subject: "",
        delay_days: 3,
        send_to: "all",
      },
    ]);
  };

  const removeFollowUp = (i: number) =>
    setFollowUps((prev) =>
      prev
        .filter((_, idx) => idx !== i)
        .map((s, idx) => ({ ...s, order: idx + 1 }))
    );

  const updateFollowUp = (i: number, patch: Partial<FollowUpStep>) => {
    setFollowUps((prev) =>
      prev.map((s, idx) => (idx === i ? { ...s, ...patch } : s))
    );
  };

  const handleSubmit = async () => {
    if (!sendNow && !scheduledAt) {
      setError("配信日時を指定するか、今すぐ送信を選択してください");
      return;
    }
    await onSubmit({
      send_now: sendNow,
      scheduled_at: sendNow ? undefined : new Date(scheduledAt),
      followUpSteps: followUps,
    });
  };

  return (
    <div className="flex flex-col gap-6 max-w-lg">
      {/* Send timing */}
      <div className="flex flex-col gap-3">
        <Label>{"配信日時"}</Label>
        <div className="flex gap-4">
          <label className="flex items-center gap-2 cursor-pointer">
            <input
              type="radio"
              checked={sendNow}
              onChange={() => {
                setSendNow(true);
                setError("");
              }}
            />
            <span className="text-sm">{"今すぐ送信"}</span>
          </label>
          <label className="flex items-center gap-2 cursor-pointer">
            <input
              type="radio"
              checked={!sendNow}
              onChange={() => {
                setSendNow(false);
                setError("");
              }}
            />
            <span className="text-sm">{"日時を指定して送信"}</span>
          </label>
        </div>
        {!sendNow && (
          <Input
            type="datetime-local"
            value={scheduledAt}
            onChange={(e) => setScheduledAt(e.target.value)}
          />
        )}
      </div>

      {/* Follow-ups */}
      <div className="flex flex-col gap-3">
        <Label>{"フォローアップのステップ"}</Label>
        {followUps.length === 0 && (
          <p className="text-sm text-muted-foreground">
            {"フォローアップは未設定です。下から追加できます。"}</p>
        )}
        {followUps.map((fu, i) => (
          <div key={i} className="border rounded-md p-3 flex flex-col gap-2">
            <div className="flex justify-between items-center">
              <span className="text-sm font-medium">{"フォローアップ"}{i + 1}</span>
              <Button
                type="button"
                variant="ghost"
                size="sm"
                onClick={() => removeFollowUp(i)}
              >
                {"削除"}</Button>
            </div>
            <div className="grid grid-cols-2 gap-2">
              <div>
                <Label className="text-xs">{"前回の配信からの日数"}</Label>
                <Input
                  type="number"
                  min={1}
                  value={fu.delay_days}
                  onChange={(e) =>
                    updateFollowUp(i, {
                      delay_days: parseInt(e.target.value) || 1,
                    })
                  }
                />
              </div>
              <div>
                <Label className="text-xs">{"送信先"}</Label>
                <select
                  className="w-full h-9 rounded-md border border-input bg-background px-3 py-1 text-sm"
                  value={fu.send_to}
                  onChange={(e) =>
                    updateFollowUp(i, {
                      send_to: e.target.value as "all" | "non_openers",
                    })
                  }
                >
                  <option value="all">{"すべての送信先"}</option>
                  <option value="non_openers">{"未開封の送信先のみ"}</option>
                </select>
              </div>
            </div>
            <div>
              <Label className="text-xs">{"番号テンプレート"}</Label>
              <select
                className="w-full h-9 rounded-md border border-input bg-background px-3 py-1 text-sm"
                value={fu.template_id}
                onChange={(e) =>
                  updateFollowUp(i, { template_id: e.target.value })
                }
              >
                {templates.map((t) => (
                  <option key={t.id} value={t.id}>
                    {t.name}
                  </option>
                ))}
              </select>
            </div>
            <div>
              <Label className="text-xs">{"件名"}</Label>
              <Input
                value={fu.subject}
                onChange={(e) => updateFollowUp(i, { subject: e.target.value })}
                placeholder="フォローアップの件名…"
              />
            </div>
          </div>
        ))}
        <Button type="button" variant="outline" onClick={addFollowUp}>
          {"＋ フォローアップを追加"}</Button>
      </div>

      {error && <p className="text-sm text-destructive">{error}</p>}

      <div className="flex justify-between">
        <Button variant="outline" onClick={onBack}>
          {"← 戻る"}</Button>
        <Button onClick={handleSubmit} disabled={isSubmitting}>
          {isSubmitting ? "送信中…" : "キャンペーンを確定"}
        </Button>
      </div>
    </div>
  );
}
