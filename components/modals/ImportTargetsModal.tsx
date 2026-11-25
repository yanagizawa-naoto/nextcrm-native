"use client";

import { useState, useRef, useCallback } from "react";
import { useRouter } from "next/navigation";
import { importTargets } from "@/actions/crm/targets/import-targets";
import { suggestMapping } from "@/actions/crm/targets/suggest-mapping";
import { parseSpreadsheetFile } from "@/lib/spreadsheet/parse";
import { TARGET_FIELDS } from "@/lib/spreadsheet/target-fields";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
  DialogTrigger,
} from "@/components/ui/dialog";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { Upload, Loader2 } from "lucide-react";

type Step = "upload" | "mapping" | "preview";

const SKIP_VALUE = "__skip__";

const ImportTargetsModal = () => {
  const router = useRouter();
  const fileInputRef = useRef<HTMLInputElement>(null);

  const [open, setOpen] = useState(false);
  const [step, setStep] = useState<Step>("upload");
  const [isLoading, setIsLoading] = useState(false);
  const [isSuggesting, setIsSuggesting] = useState(false);

  const [selectedFile, setSelectedFile] = useState<File | null>(null);
  const [csvHeaders, setCsvHeaders] = useState<string[]>([]);
  const [csvRows, setCsvRows] = useState<Record<string, string>[]>([]);
  // mapping: targetField -> csvHeader (or SKIP_VALUE)
  const [mapping, setMapping] = useState<Record<string, string>>({});

  const resetState = () => {
    setStep("upload");
    setSelectedFile(null);
    setCsvHeaders([]);
    setCsvRows([]);
    setMapping({});
    setIsLoading(false);
    setIsSuggesting(false);
    if (fileInputRef.current) fileInputRef.current.value = "";
  };

  const handleOpenChange = (val: boolean) => {
    setOpen(val);
    if (!val) resetState();
  };

  const handleFileChange = async (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0];
    if (!file) return;
    setSelectedFile(file);
    try {
      const rows = await parseSpreadsheetFile(file);
      const headers = rows.length > 0 ? Object.keys(rows[0]) : [];
      setCsvHeaders(headers);
      setCsvRows(rows);
      fetchSuggestedMapping(headers);
    } catch {
      toast.error("選択したファイルを読み取れませんでした。");
    }
  };

  const fetchSuggestedMapping = useCallback(async (headers: string[]) => {
    setIsSuggesting(true);
    setStep("mapping");
    try {
      const res = await suggestMapping(headers);
      const suggested: Record<string, string | null> = res.mapping ?? {};
      // Convert from { csvHeader -> targetField } to { targetField -> csvHeader }
      const newMapping: Record<string, string> = {};
      for (const field of TARGET_FIELDS) {
        newMapping[field.key] = SKIP_VALUE;
      }
      for (const [csvHeader, targetField] of Object.entries(suggested)) {
        if (targetField && newMapping[targetField] === SKIP_VALUE) {
          newMapping[targetField] = csvHeader;
        }
      }
      setMapping(newMapping);
    } catch {
      // Set all to skip on error
      const newMapping: Record<string, string> = {};
      for (const field of TARGET_FIELDS) {
        newMapping[field.key] = SKIP_VALUE;
      }
      setMapping(newMapping);
    } finally {
      setIsSuggesting(false);
    }
  }, []);

  const computePreview = () => {
    let valid = 0;
    let skipped = 0;
    const skipReasons: string[] = [];

    for (let i = 0; i < csvRows.length; i++) {
      const raw = csvRows[i];
      const row: Record<string, string> = {};
      for (const field of TARGET_FIELDS) {
        const csvCol = mapping[field.key];
        if (csvCol && csvCol !== SKIP_VALUE) {
          row[field.key] = raw[csvCol] ?? "";
        }
      }

      if (!row.last_name && !row.company) {
        skipped++;
        if (skipReasons.length < 3) skipReasons.push(`Row ${i + 2}: missing Last Name or Company`);
        continue;
      }
      valid++;
    }

    return { valid, skipped, skipReasons };
  };

  const handleImport = async () => {
    if (!selectedFile) return;
    setIsLoading(true);

    // Build mapping as { csvHeader -> targetField } for the API
    const apiMapping: Record<string, string> = {};
    for (const [targetField, csvCol] of Object.entries(mapping)) {
      if (csvCol && csvCol !== SKIP_VALUE) {
        apiMapping[csvCol] = targetField;
      }
    }

    const formData = new FormData();
    formData.append("file", selectedFile);
    formData.append("mapping", JSON.stringify(apiMapping));

    try {
      const { imported, skipped, errors } = await importTargets(formData);
      toast.success(`Imported: ${imported}, Skipped: ${skipped}${errors.length > 0 ? `. Errors: ${errors.slice(0, 3).join("; ")}` : ""}`);
      setOpen(false);
      resetState();
      router.refresh();
    } catch (error: any) {
      toast.error(error?.message || "処理に失敗しました");
    } finally {
      setIsLoading(false);
    }
  };

  const preview = step === "preview" ? computePreview() : null;

  return (
    <Dialog open={open} onOpenChange={handleOpenChange}>
      <DialogTrigger asChild>
        <Button variant="outline" size="sm">
          <Upload className="h-4 w-4 mr-2" />
          {"CSV・Excelを読み込む"}</Button>
      </DialogTrigger>
      <DialogContent className="sm:max-w-2xl max-h-[90vh] overflow-y-auto">
        <DialogHeader>
          <DialogTitle>
            {"営業対象を読み込む"}<span className="ml-2 text-sm font-normal text-muted-foreground">
              {"手順"}{step === "upload" ? 1 : step === "mapping" ? 2 : 3} {"／3"}</span>
          </DialogTitle>
          <DialogDescription>
            {step === "upload" && "Select a CSV or Excel (.xlsx) file to import targets."}
            {step === "mapping" && "Map your CSV columns to target fields. AI has pre-filled suggestions — adjust as needed."}
            {step === "preview" && "Review the import summary before proceeding."}
          </DialogDescription>
        </DialogHeader>

        {/* Step 1: Upload */}
        {step === "upload" && (
          <div className="space-y-4 py-2">
            <div className="border-2 border-dashed rounded-md p-8 text-center">
              <input
                ref={fileInputRef}
                type="file"
                accept=".csv,.xlsx"
                onChange={handleFileChange}
                className="hidden"
              />
              <Button
                variant="outline"
                onClick={() => fileInputRef.current?.click()}
              >
                {"ファイルを選択"}</Button>
              {selectedFile && (
                <p className="mt-2 text-sm text-muted-foreground">
                  {"選択中："}{selectedFile.name}
                </p>
              )}
            </div>
          </div>
        )}

        {/* Step 2: Map Columns */}
        {step === "mapping" && (
          <div className="space-y-3 py-2">
            {isSuggesting ? (
              <div className="flex items-center gap-2 text-muted-foreground py-8 justify-center">
                <Loader2 className="h-5 w-5 animate-spin" />
                <span>{"AIが列の対応を提案しています…"}</span>
              </div>
            ) : (
              <div className="space-y-1">
                <div className="grid grid-cols-2 gap-2 text-xs font-medium text-muted-foreground px-1 pb-1">
                  <span>{"CRMの項目"}</span>
                  <span>{"CSVの列"}</span>
                </div>
                {TARGET_FIELDS.map((field) => (
                  <div key={field.key} className="grid grid-cols-2 gap-2 items-center">
                    <span className="text-sm">
                      {field.label}
                      {field.required && (
                        <span className="text-destructive ml-1">*</span>
                      )}
                    </span>
                    <Select
                      value={mapping[field.key] ?? SKIP_VALUE}
                      onValueChange={(val) =>
                        setMapping((prev) => ({ ...prev, [field.key]: val }))
                      }
                    >
                      <SelectTrigger className="h-8 text-sm">
                        <SelectValue placeholder="— 読み込まない —" />
                      </SelectTrigger>
                      <SelectContent>
                        <SelectItem value={SKIP_VALUE}>{"— 読み込まない —"}</SelectItem>
                        {csvHeaders.map((h) => (
                          <SelectItem key={h} value={h}>
                            {h}
                          </SelectItem>
                        ))}
                      </SelectContent>
                    </Select>
                  </div>
                ))}
                <p className="text-xs text-muted-foreground pt-1">
                  <span className="text-destructive">*</span> {"各行に姓または会社名が必要です。"}</p>
              </div>
            )}
          </div>
        )}

        {/* Step 3: Preview */}
        {step === "preview" && preview && (
          <div className="space-y-4 py-2">
            <div className="rounded-md border p-4 space-y-1">
              <p className="text-sm font-medium">
                {"読み込みの準備ができました"}{" "}
                <span className="text-green-600 dark:text-green-400">
                  {preview.valid} {"行"}{preview.valid !== 1 ? "s" : ""}
                </span>
                {preview.skipped > 0 && (
                  <>
                    {" "}— {" "}
                    <span className="text-yellow-600 dark:text-yellow-400">
                      {preview.skipped} {"行"}{preview.skipped !== 1 ? "s" : ""} {"は読み込みません"}</span>
                  </>
                )}
                .
              </p>
              {preview.skipReasons.length > 0 && (
                <ul className="text-xs text-muted-foreground list-disc list-inside space-y-0.5 pt-1">
                  {preview.skipReasons.map((r, i) => (
                    <li key={i}>{r}</li>
                  ))}
                  {preview.skipped > preview.skipReasons.length && (
                    <li>{"…ほか"}{preview.skipped - preview.skipReasons.length} {"件"}</li>
                  )}
                </ul>
              )}
            </div>
            {preview.valid === 0 && (
              <p className="text-sm text-destructive">
                {"読み込める行がありません。戻って列の対応を確認してください。"}</p>
            )}
          </div>
        )}

        <DialogFooter className="flex gap-2 sm:gap-0">
          {step === "upload" && (
            <Button variant="outline" onClick={() => handleOpenChange(false)}>
              {"取消"}</Button>
          )}

          {step === "mapping" && (
            <>
              <Button variant="outline" onClick={() => setStep("upload")}>
                {"戻る"}</Button>
              <Button
                onClick={() => setStep("preview")}
                disabled={isSuggesting}
              >
                {"次へ"}</Button>
            </>
          )}

          {step === "preview" && (
            <>
              <Button variant="outline" onClick={() => setStep("mapping")} disabled={isLoading}>
                {"戻る"}</Button>
              <Button
                onClick={handleImport}
                disabled={isLoading || !preview || preview.valid === 0}
              >
                {isLoading ? (
                  <>
                    <Loader2 className="h-4 w-4 mr-2 animate-spin" />
                    {"読み込んでいます…"}</>
                ) : (
                  "読み込み"
                )}
              </Button>
            </>
          )}
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
};

export default ImportTargetsModal;
