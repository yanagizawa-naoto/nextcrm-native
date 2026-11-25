"use client";

import { useState, useTransition } from "react";
import { toast } from "sonner";
import { Input } from "@/components/ui/input";
import { Button } from "@/components/ui/button";
import { ApiKeyProvider } from "@prisma/client";
import type { UserProviderStatus } from "../../actions/api-keys";
import {
  upsertUserApiKey,
  deleteUserApiKey,
} from "../../actions/api-keys";

type Props = {
  initialKeys: UserProviderStatus[];
};

const PROVIDER_META: Record<
  ApiKeyProvider,
  { label: string; description: string }
> = {
  OPENAI: {
    label: "OpenAI",
    description: "AIによる情報補完と検索用データの生成",
  },
  FIRECRAWL: {
    label: "Firecrawl",
    description: "情報補完でのウェブ検索・情報取得",
  },
  ANTHROPIC: {
    label: "Anthropic",
    description: "Claudeモデル",
  },
  GROQ: {
    label: "Groq",
    description: "高速なAI処理",
  },
};

function ProviderRow({ status }: { status: UserProviderStatus }) {
  const [value, setValue] = useState("");
  const [isPending, startTransition] = useTransition();
  const meta = PROVIDER_META[status.provider];

  const handleSave = () => {
    if (!value.trim()) {
      toast.error("APIキーを入力してください。");
      return;
    }
    startTransition(async () => {
      try {
        await upsertUserApiKey(status.provider, value.trim());
        toast.success(`${meta.label} API key saved.`);
        setValue("");
      } catch {
        toast.error(`Failed to save ${meta.label} API key.`);
      }
    });
  };

  const handleRemove = () => {
    startTransition(async () => {
      try {
        await deleteUserApiKey(status.provider);
        toast.success(`${meta.label} API key removed.`);
      } catch {
        toast.error(`Failed to remove ${meta.label} API key.`);
      }
    });
  };

  return (
    <div className="rounded-lg border border-border bg-card p-5">
      <div className="mb-4">
        <h3 className="text-sm font-semibold text-card-foreground">
          {meta.label}
        </h3>
        <p className="text-xs text-muted-foreground mt-0.5">
          {meta.description}
        </p>
      </div>

      {status.higherTierActive && (
        <p className="text-xs text-muted-foreground mb-3 italic">
          {"システム共通キーが有効なため、個人のキーは使用されていません。"}{status.maskedKey && (
            <span className="ml-1 font-mono">{status.maskedKey}</span>
          )}
        </p>
      )}

      {!status.higherTierActive && status.maskedKey && (
        <p className="text-xs text-muted-foreground mb-3">
          {"現在のキー："}{" "}
          <span className="font-mono">{status.maskedKey}</span>
        </p>
      )}

      <div className="flex items-center gap-3">
        <Input
          type="password"
          placeholder={`Enter ${meta.label} API key`}
          value={value}
          onChange={(e) => setValue(e.target.value)}
          disabled={isPending}
          className="max-w-sm"
        />
        <Button
          size="sm"
          onClick={handleSave}
          disabled={isPending}
        >
          {"保存"}</Button>
        {status.source === "USER_SET" && (
          <Button
            size="sm"
            variant="outline"
            onClick={handleRemove}
            disabled={isPending}
          >
            {"削除"}</Button>
        )}
      </div>
    </div>
  );
}

export function LlmsTabContent({ initialKeys }: Props) {
  return (
    <div className="space-y-4">
      {initialKeys.map((status) => (
        <ProviderRow key={status.provider} status={status} />
      ))}
    </div>
  );
}
