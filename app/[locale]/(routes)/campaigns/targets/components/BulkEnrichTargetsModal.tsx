"use client";

import { useState } from "react";
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogDescription,
} from "@/components/ui/dialog";
import { toast } from "sonner";
import { EnrichFieldSelector } from "./EnrichFieldSelector";
import type { EnrichmentField } from "@/lib/enrichment/types";
import { ALL_TARGET_PRESET_FIELDS } from "@/lib/enrichment/presets/target-fields";
import { NoApiKeyDialog } from "@/app/components/NoApiKeyDialog";


interface BulkEnrichTargetsModalProps {
  targetIds: string[];
  open: boolean;
  onOpenChange: (open: boolean) => void;
}

export function BulkEnrichTargetsModal({ targetIds, open, onOpenChange }: BulkEnrichTargetsModalProps) {
  const [loading, setLoading] = useState(false);
  const [showNoApiKeyDialog, setShowNoApiKeyDialog] = useState(false);

  const handleStart = async (fields: EnrichmentField[]) => {
    setLoading(true);
    try {
      const res = await fetch("/api/campaigns/targets/enrich-bulk", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ targetIds, fields }),
      });
      if (res.ok) {
        toast.success(`Enrichment started for ${targetIds.length} targets. Check the Enrichment Jobs page for progress.`);
        onOpenChange(false);
      } else {
        const err = await res.json();
        if (res.status === 402 || err.error === "NO_API_KEY") {
          setShowNoApiKeyDialog(true);
        } else {
          toast.error(err.error ?? "一括情報補完を開始できませんでした");
        }
      }
    } finally {
      setLoading(false);
    }
  };

  return (
    <>
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="sm:max-w-[480px]">
        <DialogHeader>
          <DialogTitle>{"情報を補完"}{targetIds.length} {"件の営業対象"}</DialogTitle>
          <DialogDescription>
            {"補完する項目を選択してください。バックグラウンドで検索し、未入力の項目だけを補完します。"}</DialogDescription>
        </DialogHeader>
        <EnrichFieldSelector
          onStart={handleStart}
          loading={loading}
          presetFields={ALL_TARGET_PRESET_FIELDS}
          defaultSelected={["position", "company", "social_linkedin", "company_website"]}
        />
      </DialogContent>
    </Dialog>
    <NoApiKeyDialog open={showNoApiKeyDialog} onClose={() => setShowNoApiKeyDialog(false)} />
    </>
  );
}
