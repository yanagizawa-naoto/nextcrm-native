"use client";

import { useState, useTransition } from "react";
import type { ApiKeyProvider } from "@prisma/client";
import type { ProviderStatus } from "../actions/api-keys";
import { upsertSystemApiKey, deleteSystemApiKey } from "../actions/api-keys";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { cn } from "@/lib/utils";
import { toast } from "sonner";

const PROVIDER_META: Record<
  ApiKeyProvider,
  { name: string; subtitle: string; envVar: string }
> = {
  OPENAI: { name: "OpenAI", subtitle: "文章生成・検索用AI", envVar: "OPENAI_API_KEY" },
  FIRECRAWL: { name: "Firecrawl", subtitle: "Web情報の取得", envVar: "FIRECRAWL_API_KEY" },
  ANTHROPIC: { name: "Anthropic", subtitle: "Claudeモデル", envVar: "ANTHROPIC_API_KEY" },
  GROQ: { name: "Groq", subtitle: "高速なAI処理", envVar: "GROQ_API_KEY" },
};

interface ProviderKeyCardProps {
  status: ProviderStatus;
}

export function ProviderKeyCard({ status }: ProviderKeyCardProps) {
  const [editing, setEditing] = useState(false);
  const [keyValue, setKeyValue] = useState("");
  const [isPending, startTransition] = useTransition();

  const meta = PROVIDER_META[status.provider];

  function handleSave() {
    if (!keyValue.trim()) return;
    startTransition(async () => {
      try {
        await upsertSystemApiKey(status.provider, keyValue.trim());
        setKeyValue("");
        setEditing(false);
        toast.success(`${meta.name} key saved`);
      } catch {
        toast.error("APIキーを保存できませんでした");
      }
    });
  }

  function handleRemove() {
    startTransition(async () => {
      try {
        await deleteSystemApiKey(status.provider);
        toast.success(`${meta.name} key removed`);
      } catch {
        toast.error("APIキーを削除できませんでした");
      }
    });
  }

  const isEnv = status.source === "ENV_ACTIVE";
  const isSet = status.source === "SYSTEM_SET";
  const isNotConfigured = status.source === "NOT_CONFIGURED";

  return (
    <Card
      className={cn(
        "w-full",
        isNotConfigured && "border-dashed"
      )}
    >
      <CardHeader className="pb-2">
        <div className="flex items-start justify-between gap-2">
          <div>
            <CardTitle className="text-base">{meta.name}</CardTitle>
            <p className="text-xs text-muted-foreground mt-0.5">{meta.subtitle}</p>
          </div>
          <div className="shrink-0">
            {isEnv && (
              <Badge variant="outline" className="border-amber-500 text-amber-600 bg-amber-500/10">
                {"環境変数で設定済み"}</Badge>
            )}
            {isSet && (
              <Badge variant="outline" className="border-green-500 text-green-600 bg-green-500/10">
                {"システム共通"}</Badge>
            )}
            {isNotConfigured && (
              <Badge variant="outline" className="text-muted-foreground">
                {"未設定"}</Badge>
            )}
          </div>
        </div>
      </CardHeader>

      <CardContent className="space-y-3">
        {/* Masked key display */}
        {status.maskedKey && (
          <p className="font-mono text-sm text-muted-foreground">{status.maskedKey}</p>
        )}

        {/* ENV read-only note */}
        {isEnv && (
          <p className="text-xs text-muted-foreground">
            {"設定元："}<code className="bg-muted px-1 rounded">{meta.envVar}</code> {"— 閲覧のみ"}</p>
        )}

        {/* Edit / Remove for SYSTEM_SET */}
        {isSet && !editing && (
          <div className="flex gap-2">
            <Button
              variant="outline"
              size="sm"
              onClick={() => setEditing(true)}
              disabled={isPending}
            >
              {"編集"}</Button>
            <Button
              variant="ghost"
              size="sm"
              className="text-destructive hover:text-destructive"
              onClick={handleRemove}
              disabled={isPending}
            >
              {"削除"}</Button>
          </div>
        )}

        {/* Add key for NOT_CONFIGURED */}
        {isNotConfigured && !editing && (
          <Button
            variant="outline"
            size="sm"
            className="border-dashed"
            onClick={() => setEditing(true)}
            disabled={isPending}
          >
            {"＋ APIキーを追加"}</Button>
        )}

        {/* Inline edit input */}
        {editing && (
          <div className="flex gap-2">
            <Input
              type="password"
              placeholder="APIキーを貼り付け…"
              value={keyValue}
              onChange={(e) => setKeyValue(e.target.value)}
              className="flex-1 font-mono text-sm"
              autoFocus
              onKeyDown={(e) => {
                if (e.key === "Enter") handleSave();
                if (e.key === "Escape") {
                  setEditing(false);
                  setKeyValue("");
                }
              }}
            />
            <Button size="sm" onClick={handleSave} disabled={isPending || !keyValue.trim()}>
              {"保存"}</Button>
            <Button
              variant="ghost"
              size="sm"
              onClick={() => {
                setEditing(false);
                setKeyValue("");
              }}
              disabled={isPending}
            >
              {"取消"}</Button>
          </div>
        )}
      </CardContent>
    </Card>
  );
}
