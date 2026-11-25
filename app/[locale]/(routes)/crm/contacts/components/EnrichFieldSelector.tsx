"use client";

import { useState } from "react";
import { Checkbox } from "@/components/ui/checkbox";
import { Label } from "@/components/ui/label";
import { Input } from "@/components/ui/input";
import { Button } from "@/components/ui/button";
import { Plus, X } from "lucide-react";
import type { EnrichmentField } from "@/lib/enrichment/types";

const PRESET_FIELDS: EnrichmentField[] = [
  { name: "position",         displayName: "Position / Job Title",  description: "連絡先の勤務先での役職", type: "string", required: false },
  { name: "website",          displayName: "Company Website",        description: "会社の公式ウェブサイトURL", type: "string", required: false },
  { name: "social_linkedin",  displayName: "LinkedIn URL",           description: "連絡先または会社のLinkedInプロフィールURL", type: "string", required: false },
  { name: "social_twitter",   displayName: "Twitter / X URL",        description: "連絡先または会社のXプロフィールURL", type: "string", required: false },
  { name: "social_facebook",  displayName: "Facebook URL",           description: "連絡先または会社のFacebookページURL", type: "string", required: false },
  { name: "social_instagram", displayName: "Instagram URL",          description: "連絡先または会社のInstagramプロフィールURL", type: "string", required: false },
  { name: "description",      displayName: "Company Description",    description: "会社の事業内容の概要", type: "string", required: false },
  { name: "office_phone",     displayName: "Office Phone",           description: "会社または勤務先の電話番号", type: "string", required: false },
  { name: "mobile_phone",     displayName: "Mobile Phone",           description: "連絡先の携帯電話番号", type: "string", required: false },
];

interface EnrichFieldSelectorProps {
  onStart: (fields: EnrichmentField[]) => void;
  loading?: boolean;
  presetFields?: EnrichmentField[];
  defaultSelected?: string[];
}

export function EnrichFieldSelector({
  onStart,
  loading,
  presetFields = PRESET_FIELDS,
  defaultSelected = ["position", "social_linkedin", "website", "description"],
}: EnrichFieldSelectorProps) {
  const [selected, setSelected] = useState<Set<string>>(new Set(defaultSelected));
  const [customFields, setCustomFields] = useState<EnrichmentField[]>([]);
  const [customName, setCustomName] = useState("");
  const [customDesc, setCustomDesc] = useState("");

  const toggle = (name: string) => {
    setSelected((prev) => {
      const next = new Set(prev);
      next.has(name) ? next.delete(name) : next.add(name);
      return next;
    });
  };

  const addCustom = () => {
    if (!customName.trim()) return;
    const field: EnrichmentField = {
      name: customName.toLowerCase().replace(/\s+/g, "_"),
      displayName: customName.trim(),
      description: customDesc.trim() || `Find the ${customName.trim()} for this contact`,
      type: "string",
      required: false,
    };
    setCustomFields((prev) => [...prev, field]);
    setSelected((prev) => { const next = new Set(prev); next.add(field.name); return next; });
    setCustomName("");
    setCustomDesc("");
  };

  const removeCustom = (name: string) => {
    setCustomFields((prev) => prev.filter((f) => f.name !== name));
    setSelected((prev) => { const next = new Set(prev); next.delete(name); return next; });
  };

  const allFields = [...presetFields, ...customFields];
  const selectedFields = allFields.filter((f) => selected.has(f.name));

  return (
    <div className="space-y-4">
      <p className="text-sm text-muted-foreground">
        {"補完する項目を選択してください。Firecrawlがウェブで情報を探します。"}</p>

      <div className="space-y-2">
        {presetFields.map((field) => (
          <div key={field.name} className="flex items-center gap-2">
            <Checkbox
              id={field.name}
              checked={selected.has(field.name)}
              onCheckedChange={() => toggle(field.name)}
            />
            <Label htmlFor={field.name} className="cursor-pointer font-normal">
              {field.displayName}
            </Label>
          </div>
        ))}

        {customFields.map((field) => (
          <div key={field.name} className="flex items-center gap-2">
            <Checkbox
              id={field.name}
              checked={selected.has(field.name)}
              onCheckedChange={() => toggle(field.name)}
            />
            <Label htmlFor={field.name} className="cursor-pointer font-normal flex-1">
              {field.displayName}
            </Label>
            <Button variant="ghost" size="sm" onClick={() => removeCustom(field.name)}>
              <X className="h-3 w-3" />
            </Button>
          </div>
        ))}
      </div>

      <div className="border rounded-md p-3 space-y-2 bg-muted/30">
        <p className="text-xs font-medium text-muted-foreground">{"任意の項目を追加"}</p>
        <Input
          placeholder="項目名（例：従業員数）"
          value={customName}
          onChange={(e) => setCustomName(e.target.value)}
          className="h-8 text-sm"
        />
        <Input
          placeholder="説明（任意）"
          value={customDesc}
          onChange={(e) => setCustomDesc(e.target.value)}
          className="h-8 text-sm"
        />
        <Button variant="outline" size="sm" onClick={addCustom} disabled={!customName.trim()}>
          <Plus className="h-3 w-3 mr-1" /> {"項目を追加"}</Button>
      </div>

      <Button
        className="w-full"
        disabled={selectedFields.length === 0 || loading}
        onClick={() => onStart(selectedFields)}
      >
        {loading ? "開始中…" : `Start Enrichment (${selectedFields.length} fields)`}
      </Button>
    </div>
  );
}
