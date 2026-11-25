"use client";
import { useState } from "react";
import { useRouter } from "next/navigation";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Textarea } from "@/components/ui/textarea";
import { Label } from "@/components/ui/label";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { TipTapEditor } from "@/components/campaigns/TipTapEditor";
import { createTemplate } from "@/actions/campaigns/templates/create-template";
import { updateTemplate } from "@/actions/campaigns/templates/update-template";
import { generateTemplate } from "@/actions/campaigns/templates/generate-template";
import { previewTemplate } from "@/actions/campaigns/templates/preview-template";

type InitialData = {
  name: string;
  description?: string | null;
  subject_default?: string | null;
  content_html?: string | null;
  content_json?: object | null;
};

type Props = {
  initialData?: InitialData;
  templateId?: string;
};

export default function TemplateEditorForm({ initialData, templateId }: Props) {
  const router = useRouter();
  const isEditing = !!templateId;

  const [name, setName] = useState(initialData?.name ?? "");
  const [description, setDescription] = useState(
    initialData?.description ?? ""
  );
  const [subject, setSubject] = useState(initialData?.subject_default ?? "");
  const [contentHtml, setContentHtml] = useState(
    initialData?.content_html ?? ""
  );
  const [contentJson, setContentJson] = useState<object>(
    initialData?.content_json ?? {}
  );

  const [previewHtml, setPreviewHtml] = useState<string | null>(null);
  const [isPreviewLoading, setIsPreviewLoading] = useState(false);

  const [aiPrompt, setAiPrompt] = useState("");
  const [isGenerating, setIsGenerating] = useState(false);
  const [isSaving, setIsSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const handleEditorChange = (html: string, json: object) => {
    setContentHtml(html);
    setContentJson(json);
  };

  const handleGenerate = async () => {
    if (!aiPrompt.trim()) return;
    setIsGenerating(true);
    setError(null);
    try {
      const result = await generateTemplate(aiPrompt);
      setContentHtml(result.html);
      setContentJson(result.json);
      if (result.subject && !subject) {
        setSubject(result.subject);
      }
    } catch (err) {
      setError(err instanceof Error ? err.message : "AI生成に失敗しました");
    } finally {
      setIsGenerating(false);
    }
  };

  const handleBodyTabChange = async (value: string) => {
    if (value !== "preview") return;
    setIsPreviewLoading(true);
    try {
      const res = await previewTemplate({ contentHtml });
      setPreviewHtml(res.html ?? null);
    } catch {
      setPreviewHtml(null);
    } finally {
      setIsPreviewLoading(false);
    }
  };

  const handleSave = async () => {
    if (!name.trim()) {
      setError("テンプレート名を入力してください");
      return;
    }
    if (!subject.trim()) {
      setError("件名を入力してください");
      return;
    }
    setIsSaving(true);
    setError(null);
    try {
      if (isEditing && templateId) {
        await updateTemplate(templateId, {
          name,
          description: description || undefined,
          subject_default: subject,
          content_html: contentHtml,
          content_json: contentJson,
        });
      } else {
        await createTemplate({
          name,
          description: description || undefined,
          subject_default: subject,
          content_html: contentHtml,
          content_json: contentJson,
        });
      }
      router.push("/campaigns/templates");
    } catch (err) {
      setError(err instanceof Error ? err.message : "テンプレートを保存できませんでした");
    } finally {
      setIsSaving(false);
    }
  };

  return (
    <div className="flex flex-col gap-6 max-w-3xl">
      {error && (
        <div className="rounded-md bg-destructive/10 border border-destructive/20 p-3 text-sm text-destructive">
          {error}
        </div>
      )}

      {/* Basic fields */}
      <div className="flex flex-col gap-4">
        <div className="flex flex-col gap-2">
          <Label htmlFor="name">{"テンプレート名（必須）"}</Label>
          <Input
            id="name"
            value={name}
            onChange={(e) => setName(e.target.value)}
            placeholder="例：ご登録のお礼"
            required
          />
        </div>
        <div className="flex flex-col gap-2">
          <Label htmlFor="description">{"品名・内容"}</Label>
          <Textarea
            id="description"
            value={description}
            onChange={(e) => setDescription(e.target.value)}
            placeholder="説明（任意）"
            rows={2}
          />
        </div>
        <div className="flex flex-col gap-2">
          <Label htmlFor="subject">{"件名（必須）"}</Label>
          <Input
            id="subject"
            value={subject}
            onChange={(e) => setSubject(e.target.value)}
            placeholder="例：{{first_name}}様、ご案内です"
            required
          />
        </div>
      </div>

      {/* AI Generation */}
      <div className="flex flex-col gap-3 rounded-md border p-4 bg-muted/30">
        <h3 className="font-semibold text-sm">{"AIで作成"}</h3>
        <div className="flex flex-col gap-2">
          <Label htmlFor="ai-prompt">{"作成したいメールの内容"}</Label>
          <Textarea
            id="ai-prompt"
            value={aiPrompt}
            onChange={(e) => setAiPrompt(e.target.value)}
            placeholder="例：法人の見込み客に、導入効果を伝える丁寧なサービス紹介メール"
            rows={3}
          />
        </div>
        <Button
          type="button"
          variant="secondary"
          onClick={handleGenerate}
          disabled={isGenerating || !aiPrompt.trim()}
        >
          {isGenerating ? "作成中…" : "作成"}
        </Button>
      </div>

      {/* TipTap Editor */}
      <div className="flex flex-col gap-2">
        <Label>{"メール本文"}</Label>
        <Tabs defaultValue="edit" onValueChange={handleBodyTabChange}>
          <TabsList>
            <TabsTrigger value="edit">{"編集"}</TabsTrigger>
            <TabsTrigger value="preview">{"プレビュー"}</TabsTrigger>
          </TabsList>
          <TabsContent value="edit">
            <TipTapEditor content={contentHtml} onChange={handleEditorChange} />
          </TabsContent>
          <TabsContent value="preview">
            {isPreviewLoading ? (
              <div className="rounded-md border p-4 text-sm text-muted-foreground">
                {"プレビューを作成しています…"}</div>
            ) : (
              <iframe
                srcDoc={previewHtml ?? ""}
                sandbox=""
                title="メールのプレビュー"
                className="h-[600px] w-full rounded-md border bg-white"
              />
            )}
          </TabsContent>
        </Tabs>
      </div>

      {/* Actions */}
      <div className="flex gap-3">
        <Button onClick={handleSave} disabled={isSaving}>
          {isSaving ? "保存中…" : isEditing ? "テンプレートを更新" : "テンプレートを保存"}
        </Button>
        <Button
          type="button"
          variant="outline"
          onClick={() => router.push("/campaigns/templates")}
        >
          {"取消"}</Button>
      </div>
    </div>
  );
}
