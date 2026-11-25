"use client";
import { useState } from "react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Textarea } from "@/components/ui/textarea";
import { Label } from "@/components/ui/label";

type Props = {
  initialData: {
    name?: string;
    description?: string;
    from_name?: string;
    reply_to?: string;
  };
  onNext: (data: {
    name: string;
    description?: string;
    from_name?: string;
    reply_to?: string;
  }) => void;
};

export function Step1Details({ initialData, onNext }: Props) {
  const [name, setName] = useState(initialData.name ?? "");
  const [description, setDescription] = useState(
    initialData.description ?? ""
  );
  const [fromName, setFromName] = useState(initialData.from_name ?? "");
  const [replyTo, setReplyTo] = useState(initialData.reply_to ?? "");
  const [error, setError] = useState("");

  const handleNext = () => {
    if (!name.trim()) {
      setError("キャンペーン名を入力してください");
      return;
    }
    onNext({
      name: name.trim(),
      description: description || undefined,
      from_name: fromName || undefined,
      reply_to: replyTo || undefined,
    });
  };

  return (
    <div className="flex flex-col gap-4 max-w-lg">
      <div className="flex flex-col gap-1.5">
        <Label htmlFor="name">{"キャンペーン名（必須）"}</Label>
        <Input
          id="name"
          value={name}
          onChange={(e) => {
            setName(e.target.value);
            setError("");
          }}
          placeholder="例：新商品のご案内"
        />
        {error && <p className="text-sm text-destructive">{error}</p>}
      </div>
      <div className="flex flex-col gap-1.5">
        <Label htmlFor="description">{"品名・内容"}</Label>
        <Textarea
          id="description"
          value={description}
          onChange={(e) => setDescription(e.target.value)}
          placeholder="説明（任意）…"
        />
      </div>
      <div className="flex flex-col gap-1.5">
        <Label htmlFor="fromName">{"差出人名"}</Label>
        <Input
          id="fromName"
          value={fromName}
          onChange={(e) => setFromName(e.target.value)}
          placeholder="例：株式会社サンプル 山田"
        />
      </div>
      <div className="flex flex-col gap-1.5">
        <Label htmlFor="replyTo">{"返信先メールアドレス"}</Label>
        <Input
          id="replyTo"
          value={replyTo}
          onChange={(e) => setReplyTo(e.target.value)}
          placeholder="reply@yourcompany.com"
        />
      </div>
      <div className="flex justify-end">
        <Button onClick={handleNext}>{"次へ →"}</Button>
      </div>
    </div>
  );
}
