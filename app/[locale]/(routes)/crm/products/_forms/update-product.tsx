"use client";

import { toast } from "sonner";
import { Loader2 } from "lucide-react";
import { useState } from "react";
import { useRouter } from "next/navigation";

import { crm_ProductCategories } from "@prisma/client";

import { useAction } from "@/hooks/use-action";
import { updateProduct } from "@/actions/crm/products/update-product";

import { FormInput } from "@/components/form/form-input";
import FormSheetNoTrigger from "@/components/sheets/form-sheet-no-trigger";
import { FormSubmit } from "@/components/form/form-submit";
import { FormTextarea } from "@/components/form/form-textarea";
import { FormSelect } from "@/components/form/from-select";

import { Checkbox } from "@/components/ui/checkbox";
import { Label } from "@/components/ui/label";

interface UpdateProductFormProps {
  onOpen: boolean;
  setOpen: (open: boolean) => void;
  product: {
    id: string;
    name: string;
    description: string | null;
    sku: string | null;
    type: string;
    status: string;
    unit_price: number;
    unit_cost: number | null;
    currency: string;
    tax_rate: number | null;
    unit: string | null;
    is_recurring: boolean;
    billing_period: string | null;
    category: { id: string; name: string } | null;
  };
  categories: crm_ProductCategories[];
  currencies?: { code: string; name: string; symbol: string }[];
}

const UpdateProductForm = ({
  onOpen,
  setOpen,
  product,
  categories,
  currencies = [],
}: UpdateProductFormProps) => {
  const router = useRouter();
  const [isRecurring, setIsRecurring] = useState(product.is_recurring);

  const { execute, fieldErrors, isLoading } = useAction(updateProduct, {
    onSuccess: () => {
      toast.success("商品を更新しました");
      setOpen(false);
      router.refresh();
    },
    onError: (error) => {
      toast.error(error);
    },
  });

  const onAction = async (formData: FormData) => {
    const name = formData.get("name") as string;
    const sku = (formData.get("sku") as string) || undefined;
    const type = formData.get("type") as "PRODUCT" | "SERVICE" | undefined;
    const status = formData.get("status") as
      | "DRAFT"
      | "ACTIVE"
      | "ARCHIVED"
      | undefined;
    const unit_price = (formData.get("unit_price") as string) || undefined;
    const unit_cost = (formData.get("unit_cost") as string) || undefined;
    const currency = (formData.get("currency") as string) || undefined;
    const tax_rate = (formData.get("tax_rate") as string) || undefined;
    const unit = (formData.get("unit") as string) || undefined;
    const categoryId = (formData.get("categoryId") as string) || null;
    const description = (formData.get("description") as string) || undefined;
    const billing_period = isRecurring
      ? ((formData.get("billing_period") as string) as
          | "MONTHLY"
          | "QUARTERLY"
          | "ANNUALLY"
          | "ONE_TIME"
          | undefined)
      : null;

    await execute({
      id: product.id,
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

  if (!onOpen) return null;

  return (
    <FormSheetNoTrigger
      title="商品を更新"
      description="商品の詳細を更新します"
      open={onOpen}
      setOpen={setOpen}
    >
      <form action={onAction} className="space-y-4">
        <FormInput
          id="name"
          label="名称"
          type="text"
          errors={fieldErrors}
          defaultValue={product.name}
        />
        <FormInput
          id="sku"
          label="SKU"
          type="text"
          errors={fieldErrors}
          defaultValue={product.sku ?? ""}
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
          defaultValue={product.type}
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
          defaultValue={product.status}
        />
        <div className="grid grid-cols-2 gap-4">
          <FormInput
            id="unit_price"
            label="単価"
            type="text"
            errors={fieldErrors}
            defaultValue={String(product.unit_price)}
          />
          <FormInput
            id="unit_cost"
            label="単位原価"
            type="text"
            errors={fieldErrors}
            defaultValue={product.unit_cost != null ? String(product.unit_cost) : ""}
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
          defaultValue={product.currency}
        />
        <div className="grid grid-cols-2 gap-4">
          <FormInput
            id="tax_rate"
            label="税率（%）"
            type="text"
            errors={fieldErrors}
            defaultValue={product.tax_rate != null ? String(product.tax_rate) : ""}
          />
          <FormInput
            id="unit"
            label="単位"
            type="text"
            errors={fieldErrors}
            defaultValue={product.unit ?? ""}
          />
        </div>
        <FormSelect
          id="categoryId"
          label="カテゴリ"
          type="hidden"
          data={categories.map((c) => ({ id: c.id, name: c.name }))}
          errors={fieldErrors}
          defaultValue={product.category?.id ?? ""}
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
            defaultValue={product.billing_period ?? ""}
          />
        )}
        <FormTextarea
          id="description"
          label="品名・内容"
          errors={fieldErrors}
          defaultValue={product.description ?? ""}
        />
        <FormSubmit className="w-full">
          {isLoading ? (
            <Loader2 className="h-6 w-6 animate-spin" />
          ) : (
            "更新"
          )}
        </FormSubmit>
      </form>
    </FormSheetNoTrigger>
  );
};

export default UpdateProductForm;
