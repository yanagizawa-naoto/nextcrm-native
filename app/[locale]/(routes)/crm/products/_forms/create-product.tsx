"use client";

import { toast } from "sonner";
import { Loader2 } from "lucide-react";
import { useRef, useState } from "react";
import { useRouter } from "next/navigation";

import { crm_ProductCategories } from "@prisma/client";

import { useAction } from "@/hooks/use-action";
import { createProduct } from "@/actions/crm/products/create-product";

import { FormInput } from "@/components/form/form-input";
import FormSheet from "@/components/sheets/form-sheet";
import { FormSubmit } from "@/components/form/form-submit";
import { FormTextarea } from "@/components/form/form-textarea";
import { FormSelect } from "@/components/form/from-select";

import { Checkbox } from "@/components/ui/checkbox";
import { Label } from "@/components/ui/label";

const CreateProductForm = ({
  categories,
  currencies = [],
}: {
  categories: crm_ProductCategories[];
  currencies?: { code: string; name: string; symbol: string }[];
}) => {
  const router = useRouter();
  const closeRef = useRef<HTMLButtonElement>(null);
  const [isRecurring, setIsRecurring] = useState(false);

  const { execute, fieldErrors, isLoading } = useAction(createProduct, {
    onSuccess: () => {
      toast.success("商品を作成しました");
      closeRef.current?.click();
      router.refresh();
    },
    onError: (error) => {
      toast.error(error);
    },
  });

  const onAction = async (formData: FormData) => {
    const name = formData.get("name") as string;
    const sku = (formData.get("sku") as string) || undefined;
    const type = formData.get("type") as "PRODUCT" | "SERVICE";
    const status = formData.get("status") as "DRAFT" | "ACTIVE" | "ARCHIVED";
    const unit_price = formData.get("unit_price") as string;
    const unit_cost = (formData.get("unit_cost") as string) || undefined;
    const currency = formData.get("currency") as string;
    const tax_rate = (formData.get("tax_rate") as string) || undefined;
    const unit = (formData.get("unit") as string) || undefined;
    const categoryId = (formData.get("categoryId") as string) || undefined;
    const description = (formData.get("description") as string) || undefined;
    const billing_period = isRecurring
      ? ((formData.get("billing_period") as string) as
          | "MONTHLY"
          | "QUARTERLY"
          | "ANNUALLY"
          | "ONE_TIME"
          | undefined)
      : undefined;

    await execute({
      name,
      sku,
      type,
      status,
      unit_price,
      unit_cost,
      currency,
      tax_rate,
      unit,
      is_recurring: isRecurring,
      billing_period,
      categoryId,
      description,
    });
  };

  return (
    <FormSheet
      trigger={"+"}
      title="商品を作成"
      description="商品・サービスを一覧に追加します"
      onClose={closeRef}
    >
      <form action={onAction} className="space-y-4">
        <FormInput
          id="name"
          label="名称"
          type="text"
          errors={fieldErrors}
        />
        <FormInput
          id="sku"
          label="SKU"
          type="text"
          errors={fieldErrors}
        />
        <FormSelect
          id="type"
          label="種別"
          type="hidden"
          data={[
            { id: "PRODUCT", name: "Product" },
            { id: "SERVICE", name: "Service" },
          ]}
          errors={fieldErrors}
        />
        <FormSelect
          id="status"
          label="状態"
          type="hidden"
          data={[
            { id: "DRAFT", name: "Draft" },
            { id: "ACTIVE", name: "Active" },
            { id: "ARCHIVED", name: "Archived" },
          ]}
          errors={fieldErrors}
          defaultValue="DRAFT"
        />
        <div className="grid grid-cols-2 gap-4">
          <FormInput
            id="unit_price"
            label="単価"
            type="text"
            errors={fieldErrors}
          />
          <FormInput
            id="unit_cost"
            label="単位原価"
            type="text"
            errors={fieldErrors}
          />
        </div>
        <FormSelect
          id="currency"
          label="通貨"
          type="hidden"
          data={currencies.map((c) => ({
            id: c.code,
            name: `${c.symbol} ${c.code} — ${c.name}`,
          }))}
          errors={fieldErrors}
        />
        <div className="grid grid-cols-2 gap-4">
          <FormInput
            id="tax_rate"
            label="税率（%）"
            type="text"
            errors={fieldErrors}
          />
          <FormInput
            id="unit"
            label="単位"
            type="text"
            errors={fieldErrors}
          />
        </div>
        <FormSelect
          id="categoryId"
          label="カテゴリ"
          type="hidden"
          data={categories.map((c) => ({ id: c.id, name: c.name }))}
          errors={fieldErrors}
        />
        <div className="flex items-center space-x-2">
          <Checkbox
            id="is_recurring"
            checked={isRecurring}
            onCheckedChange={(checked) => setIsRecurring(checked === true)}
          />
          <Label htmlFor="is_recurring">{"定期請求"}</Label>
        </div>
        {isRecurring && (
          <FormSelect
            id="billing_period"
            label="請求周期"
            type="hidden"
            data={[
              { id: "MONTHLY", name: "Monthly" },
              { id: "QUARTERLY", name: "Quarterly" },
              { id: "ANNUALLY", name: "Annually" },
              { id: "ONE_TIME", name: "One Time" },
            ]}
            errors={fieldErrors}
          />
        )}
        <FormTextarea
          id="description"
          label="品名・内容"
          errors={fieldErrors}
        />
        <FormSubmit className="w-full">
          {isLoading ? (
            <Loader2 className="h-6 w-6 animate-spin" />
          ) : (
            "作成"
          )}
        </FormSubmit>
      </form>
    </FormSheet>
  );
};

export default CreateProductForm;
