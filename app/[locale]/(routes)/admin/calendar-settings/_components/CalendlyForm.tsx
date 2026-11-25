"use client";

import { useState, useTransition } from "react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { saveCalendlyAction, subscribeCalendlyWebhook } from "../_actions/calendly";

export function CalendlyForm(props: {
  hasToken: boolean;
  hasSigningKey: boolean;
  webhookUri: string | null;
}) {
  const [pending, startTransition] = useTransition();
  const [message, setMessage] = useState<string | null>(null);
  const [savePending, startSaveTransition] = useTransition();

  const handleSave = (event: React.FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    const formData = new FormData(event.currentTarget);
    startSaveTransition(async () => {
      const res = await saveCalendlyAction(formData);
      if (res.ok) {
        toast.success("Calendlyの設定を保存しました。");
      } else {
        toast.error(res.error ?? "予約連携の設定を保存できませんでした。");
      }
    });
  };

  return (
    <div className="max-w-xl space-y-4 rounded-lg border p-4">
      <form onSubmit={handleSave} className="space-y-3">
        <div>
          <label className="text-sm font-medium">
            {"APIトークン"}{props.hasToken ? "（保存済み）" : ""}
          </label>
          <Input name="apiToken" type="password" placeholder="Calendlyの個人アクセストークン" />
        </div>
        <div>
          <label className="text-sm font-medium">
            {"Webhook署名キー"}{props.hasSigningKey ? "（保存済み）" : ""}
          </label>
          <Input name="signingKey" type="password" placeholder="任意（連携登録時に自動生成）" />
        </div>
        <Button type="submit" disabled={savePending}>
          {savePending ? "保存中…" : "保存"}
        </Button>
      </form>

      <div className="border-t pt-4">
        <Button
          variant="secondary"
          disabled={pending || !props.hasToken}
          onClick={() =>
            startTransition(async () => {
              const res = await subscribeCalendlyWebhook();
              setMessage(res.ok ? "通知の受信を設定しました。" : res.error ?? "処理に失敗しました。");
            })
          }
        >
          {props.webhookUri ? "Webhookを再登録" : "Webhookを登録"}
        </Button>
        {props.webhookUri && (
          <p className="mt-2 break-all text-xs text-muted-foreground">
            {"有効な連携："}{props.webhookUri}
          </p>
        )}
        {message && <p className="mt-2 text-sm">{message}</p>}
      </div>
    </div>
  );
}
