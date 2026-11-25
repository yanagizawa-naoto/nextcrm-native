"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { toast } from "sonner";
import { saveInvoiceSettings } from "../_actions/invoice-settings";
import type { InvoiceSettingsInput, FieldErrors } from "../_actions/invoice-settings";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Textarea } from "@/components/ui/textarea";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";

interface Currency {
  code: string;
  name: string;
}

interface Series {
  id: string;
  name: string;
}

interface TaxRate {
  id: string;
  name: string;
  rate: string;
}

interface Settings {
  id: string;
  baseCurrency: string;
  defaultSeriesId: string | null;
  defaultTaxRateId: string | null;
  defaultDueDays: number;
  bankName: string | null;
  bankAccount: string | null;
  iban: string | null;
  swift: string | null;
  footerText: string | null;
  companyName: string | null;
  companyAddress: string | null;
  companyCity: string | null;
  companyZip: string | null;
  companyCountry: string | null;
  companyVatId: string | null;
  companyTaxId: string | null;
  companyRegNo: string | null;
  companyEmail: string | null;
  companyPhone: string | null;
  companyWebsite: string | null;
}

interface Props {
  settings: Settings | null;
  currencies: Currency[];
  series: Series[];
  taxRates: TaxRate[];
}

export function InvoiceSettingsForm({
  settings,
  currencies,
  series,
  taxRates,
}: Props) {
  const router = useRouter();
  const [isPending, startTransition] = useTransition();
  const [errors, setErrors] = useState<FieldErrors>({});
  const clearError = (field: string) =>
    setErrors((prev) => {
      if (!prev[field]) return prev;
      const { [field]: _, ...rest } = prev;
      return rest;
    });

  const [baseCurrency, setBaseCurrency] = useState(
    settings?.baseCurrency ?? "CZK"
  );
  const [defaultSeriesId, setDefaultSeriesId] = useState(
    settings?.defaultSeriesId ?? ""
  );
  const [defaultTaxRateId, setDefaultTaxRateId] = useState(
    settings?.defaultTaxRateId ?? ""
  );
  const [defaultDueDays, setDefaultDueDays] = useState(
    settings?.defaultDueDays?.toString() ?? "14"
  );
  const [bankName, setBankName] = useState(settings?.bankName ?? "");
  const [bankAccount, setBankAccount] = useState(
    settings?.bankAccount ?? ""
  );
  const [iban, setIban] = useState(settings?.iban ?? "");
  const [swift, setSwift] = useState(settings?.swift ?? "");
  const [footerText, setFooterText] = useState(settings?.footerText ?? "");
  const [companyName, setCompanyName] = useState(settings?.companyName ?? "");
  const [companyAddress, setCompanyAddress] = useState(settings?.companyAddress ?? "");
  const [companyCity, setCompanyCity] = useState(settings?.companyCity ?? "");
  const [companyZip, setCompanyZip] = useState(settings?.companyZip ?? "");
  const [companyCountry, setCompanyCountry] = useState(settings?.companyCountry ?? "");
  const [companyVatId, setCompanyVatId] = useState(settings?.companyVatId ?? "");
  const [companyTaxId, setCompanyTaxId] = useState(settings?.companyTaxId ?? "");
  const [companyRegNo, setCompanyRegNo] = useState(settings?.companyRegNo ?? "");
  const [companyEmail, setCompanyEmail] = useState(settings?.companyEmail ?? "");
  const [companyPhone, setCompanyPhone] = useState(settings?.companyPhone ?? "");
  const [companyWebsite, setCompanyWebsite] = useState(settings?.companyWebsite ?? "");

  const handleSave = () => {
    const payload: InvoiceSettingsInput = {
      baseCurrency,
      defaultSeriesId: defaultSeriesId || null,
      defaultTaxRateId: defaultTaxRateId || null,
      defaultDueDays: parseInt(defaultDueDays) || 14,
      bankName: bankName || null,
      bankAccount: bankAccount || null,
      iban: iban || null,
      swift: swift || null,
      footerText: footerText || null,
      companyName,
      companyAddress,
      companyCity,
      companyZip,
      companyCountry,
      companyRegNo,
      companyVatId: companyVatId || null,
      companyTaxId: companyTaxId || null,
      companyEmail: companyEmail || null,
      companyPhone: companyPhone || null,
      companyWebsite: companyWebsite || null,
    };

    setErrors({});
    startTransition(async () => {
      const res = await saveInvoiceSettings(payload);
      if (res.ok) {
        toast.success("設定を保存しました");
        router.refresh();
      } else {
        toast.error(res.error);
        if (res.fieldErrors) setErrors(res.fieldErrors);
      }
    });
  };

  return (
    <div className="space-y-6 max-w-2xl">
      <div className="space-y-4">
        <h3 className="text-sm font-semibold text-muted-foreground uppercase tracking-wide">
          {"自社情報"}</h3>
        <div className="space-y-2">
          <Label>{"会社名"}<span className="text-destructive">*</span></Label>
          <Input
            value={companyName}
            onChange={(e) => {
              setCompanyName(e.target.value);
              clearError("companyName");
            }}
            placeholder="例：株式会社サンプル"
            aria-invalid={!!errors.companyName}
          />
          {errors.companyName && (
            <p className="text-xs text-destructive">{errors.companyName}</p>
          )}
        </div>
        <div className="space-y-2">
          <Label>{"町名・番地・建物名"}<span className="text-destructive">*</span></Label>
          <Input
            value={companyAddress}
            onChange={(e) => {
              setCompanyAddress(e.target.value);
              clearError("companyAddress");
            }}
            placeholder="例：丸の内1丁目1番1号"
            aria-invalid={!!errors.companyAddress}
          />
          {errors.companyAddress && (
            <p className="text-xs text-destructive">{errors.companyAddress}</p>
          )}
        </div>
        <div className="grid grid-cols-3 gap-4">
          <div className="space-y-2">
            <Label>{"市区町村"}<span className="text-destructive">*</span></Label>
            <Input
              value={companyCity}
              onChange={(e) => {
                setCompanyCity(e.target.value);
                clearError("companyCity");
              }}
              aria-invalid={!!errors.companyCity}
            />
            {errors.companyCity && (
              <p className="text-xs text-destructive">{errors.companyCity}</p>
            )}
          </div>
          <div className="space-y-2">
            <Label>{"郵便番号"}<span className="text-destructive">*</span></Label>
            <Input
              value={companyZip}
              onChange={(e) => {
                setCompanyZip(e.target.value);
                clearError("companyZip");
              }}
              aria-invalid={!!errors.companyZip}
            />
            {errors.companyZip && (
              <p className="text-xs text-destructive">{errors.companyZip}</p>
            )}
          </div>
          <div className="space-y-2">
            <Label>{"国"}<span className="text-destructive">*</span></Label>
            <Input
              value={companyCountry}
              onChange={(e) => {
                setCompanyCountry(e.target.value);
                clearError("companyCountry");
              }}
              placeholder="例：日本"
              aria-invalid={!!errors.companyCountry}
            />
            {errors.companyCountry && (
              <p className="text-xs text-destructive">{errors.companyCountry}</p>
            )}
          </div>
        </div>
        <div className="grid grid-cols-3 gap-4">
          <div className="space-y-2">
            <Label>{"税務登録番号"}</Label>
            <Input
              value={companyVatId}
              onChange={(e) => setCompanyVatId(e.target.value)}
              placeholder="税務登録番号を入力"
            />
          </div>
          <div className="space-y-2">
            <Label>{"税務番号"}</Label>
            <Input
              value={companyTaxId}
              onChange={(e) => setCompanyTaxId(e.target.value)}
            />
          </div>
          <div className="space-y-2">
            <Label>{"法人番号・登録番号"}<span className="text-destructive">*</span></Label>
            <Input
              value={companyRegNo}
              onChange={(e) => {
                setCompanyRegNo(e.target.value);
                clearError("companyRegNo");
              }}
              placeholder="e.g. 12345678"
              aria-invalid={!!errors.companyRegNo}
            />
            {errors.companyRegNo && (
              <p className="text-xs text-destructive">{errors.companyRegNo}</p>
            )}
          </div>
        </div>
        <div className="grid grid-cols-3 gap-4">
          <div className="space-y-2">
            <Label>{"メールアドレス"}</Label>
            <Input
              type="email"
              value={companyEmail}
              onChange={(e) => {
                setCompanyEmail(e.target.value);
                clearError("companyEmail");
              }}
              aria-invalid={!!errors.companyEmail}
            />
            {errors.companyEmail && (
              <p className="text-xs text-destructive">{errors.companyEmail}</p>
            )}
          </div>
          <div className="space-y-2">
            <Label>{"電話番号"}</Label>
            <Input
              value={companyPhone}
              onChange={(e) => setCompanyPhone(e.target.value)}
            />
          </div>
          <div className="space-y-2">
            <Label>{"ウェブサイト"}</Label>
            <Input
              value={companyWebsite}
              onChange={(e) => setCompanyWebsite(e.target.value)}
              placeholder="例：https://example.jp"
            />
          </div>
        </div>
      </div>

      <div className="space-y-4 pt-4 border-t">
        <h3 className="text-sm font-semibold text-muted-foreground uppercase tracking-wide">
          {"請求書の初期値"}</h3>
      <div className="grid grid-cols-2 gap-4">
        <div className="space-y-2">
          <Label>{"基本通貨"}</Label>
          <Select value={baseCurrency} onValueChange={setBaseCurrency}>
            <SelectTrigger>
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              {currencies.map((c) => (
                <SelectItem key={c.code} value={c.code}>
                  {c.code} - {c.name}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        </div>

        <div className="space-y-2">
          <Label>{"支払期限までの日数"}</Label>
          <Input
            type="number"
            value={defaultDueDays}
            onChange={(e) => setDefaultDueDays(e.target.value)}
            min={1}
          />
        </div>
      </div>

      <div className="grid grid-cols-2 gap-4">
        <div className="space-y-2">
          <Label>{"既定の採番系列"}</Label>
          <Select value={defaultSeriesId} onValueChange={setDefaultSeriesId}>
            <SelectTrigger>
              <SelectValue placeholder="採番系列を選択…" />
            </SelectTrigger>
            <SelectContent>
              {series.map((s) => (
                <SelectItem key={s.id} value={s.id}>
                  {s.name}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        </div>

        <div className="space-y-2">
          <Label>{"既定の税率"}</Label>
          <Select value={defaultTaxRateId} onValueChange={setDefaultTaxRateId}>
            <SelectTrigger>
              <SelectValue placeholder="税率を選択…" />
            </SelectTrigger>
            <SelectContent>
              {taxRates.map((t) => (
                <SelectItem key={t.id} value={t.id}>
                  {t.name} ({t.rate}%)
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        </div>
      </div>

      <div className="grid grid-cols-2 gap-4">
        <div className="space-y-2">
          <Label>{"金融機関名"}</Label>
          <Input
            value={bankName}
            onChange={(e) => setBankName(e.target.value)}
            placeholder="例：○○銀行 ○○支店"
          />
        </div>
        <div className="space-y-2">
          <Label>{"銀行口座"}</Label>
          <Input
            value={bankAccount}
            onChange={(e) => setBankAccount(e.target.value)}
            placeholder="e.g. 123456789/0100"
          />
        </div>
      </div>

      <div className="grid grid-cols-2 gap-4">
        <div className="space-y-2">
          <Label>{"IBAN（国際銀行口座番号）"}</Label>
          <Input
            value={iban}
            onChange={(e) => setIban(e.target.value)}
            placeholder="海外口座の場合に入力"
          />
        </div>
        <div className="space-y-2">
          <Label>{"SWIFTコード"}</Label>
          <Input
            value={swift}
            onChange={(e) => setSwift(e.target.value)}
            placeholder="海外送金の場合に入力"
          />
        </div>
      </div>

      <div className="space-y-2">
        <Label>{"フッターの文言"}</Label>
        <Textarea
          value={footerText}
          onChange={(e) => setFooterText(e.target.value)}
          placeholder="請求書の下部に表示する文言"
          rows={3}
        />
      </div>

      </div>

      <Button onClick={handleSave} disabled={isPending}>
        {isPending ? "保存中…" : "設定を保存"}
      </Button>
    </div>
  );
}
