"use client";

import { useState } from "react";
import { Button } from "@/components/ui/button";
import { Sparkles } from "lucide-react";
import { toast } from "sonner";

interface EnrichButtonProps {
  targetId: string;
}

export function EnrichButton({ targetId }: EnrichButtonProps) {
  const [loading, setLoading] = useState(false);

  async function handleEnrich() {
    setLoading(true);
    try {
      const res = await fetch(`/api/crm/targets/${targetId}/enrich`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ force: true }),
      });
      if (!res.ok) throw new Error(await res.text());
      toast.success("情報補完を開始しました。完了時に通知します");
    } catch {
      toast.error("情報補完を開始できませんでした");
    } finally {
      setLoading(false);
    }
  }

  return (
    <Button
      variant="outline"
      size="sm"
      onClick={handleEnrich}
      disabled={loading}
      title="AIで情報を補完"
    >
      <Sparkles className="h-4 w-4 mr-1 text-orange-500" />
      {loading ? "開始中…" : "AIで情報を補完"}
    </Button>
  );
}
