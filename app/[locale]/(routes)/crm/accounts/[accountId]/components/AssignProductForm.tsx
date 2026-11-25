"use client";

import { toast } from "sonner";
import { Loader2 } from "lucide-react";
import { useRef } from "react";
import { useRouter } from "next/navigation";

import { useAction } from "@/hooks/use-action";
import { assignProduct } from "@/actions/crm/account-products/assign-product";

import { FormInput } from "@/components/form/form-input";
import FormSheet from "@/components/sheets/form-sheet";
import { FormSubmit } from "@/components/form/form-submit";
import { FormTextarea } from "@/components/form/form-textarea";
import { FormSelect } from "@/components/form/from-select";
import { FormDatePicker } from "@/components/form/form-datepicker";

interface AssignProductFormProps {
  accountId: string;
  products: { id: string; name: string; currency: string }[];
  currencies: { code: string; name: string; symbol: string }[];
}

const AssignProductForm = ({
  accountId,
  products,
  currencies,
}: AssignProductFormProps) => {
  const router = useRouter();
  const closeRef = useRef<HTMLButtonElement>(null);

  const { execute, fieldErrors, isLoading } = useAction(assignProduct, {
    onSuccess: () => {
      toast.success("商品を割り当てました");
      closeRef.current?.click();
      router.refresh();
    },
    onError: (error) => {
      toast.error(error);
    },
  });

  const onAction = async (formData: FormData) => {
    const productId = formData.get("productId") as string;
    const quantity = parseInt((formData.get("quantity") as string) || "1", 10);
    const custom_price =
      (formData.get("custom_price") as string) || undefined;
    const currency = formData.get("currency") as string;
    const status = (formData.get("status") as "ACTIVE" | "PENDING") || "ACTIVE";
    const start_date = new Date(formData.get("start_date") as string);
    const end_date_raw = formData.get("end_date") as string;
    const end_date = end_date_raw ? new Date(end_date_raw) : undefined;
    const renewal_date_raw = formData.get("renewal_date") as string;
    const renewal_date = renewal_date_raw
      ? new Date(renewal_date_raw)
      : undefined;
    const notes = (formData.get("notes") as string) || undefined;

    await execute({
      accountId,
      productId,
      quantity,
      custom_price,
      currency,
      status,
      start_date,
      end_date,
      renewal_date,
      notes,
    });
  };

  return (
    <FormSheet
      trigger={"+"}
      title="商品を割り当て"
      description="取引先に商品・サービスを割り当てます"
      onClose={closeRef}
    >
      <form action={onAction} className="space-y-4">
        <FormSelect
          id="productId"
          label="商品"
          type="hidden"
          data={products.map((p) => ({ id: p.id, name: p.name }))}
          errors={fieldErrors}
        />
        <FormInput
          id="quantity"
          label="数量"
          type="number"
          defaultValue="1"
          errors={fieldErrors}
        />
        <FormInput
          id="custom_price"
          label="個別価格（任意）"
          type="text"
          errors={fieldErrors}
        />
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
        <FormSelect
          id="status"
          label="状態"
          type="hidden"
          data={[
            { id: "ACTIVE", name: "Active" },
            { id: "PENDING", name: "Pending" },
          ]}
          errors={fieldErrors}
          defaultValue="ACTIVE"
        />
        <FormDatePicker
          id="start_date"
          label="開始日"
          errors={fieldErrors}
        />
        <FormDatePicker
          id="end_date"
          label="終了日（任意）"
          errors={fieldErrors}
        />
        <FormDatePicker
          id="renewal_date"
          label="更新日（任意）"
          errors={fieldErrors}
        />
        <FormTextarea id="notes" label="メモ" errors={fieldErrors} />
        <FormSubmit className="w-full">
          {isLoading ? (
            <Loader2 className="h-6 w-6 animate-spin" />
          ) : (
            "割り当て"
          )}
        </FormSubmit>
      </form>
    </FormSheet>
  );
};

export default AssignProductForm;
