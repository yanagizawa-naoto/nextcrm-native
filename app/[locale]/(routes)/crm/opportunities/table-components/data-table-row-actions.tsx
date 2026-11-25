"use client";

import { DotsHorizontalIcon } from "@radix-ui/react-icons";
import { Row } from "@tanstack/react-table";

import { Button } from "@/components/ui/button";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuSeparator,
  DropdownMenuShortcut,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";

import { opportunitySchema } from "../table-data/schema";
import { useRouter } from "next/navigation";
import AlertModal from "@/components/modals/alert-modal";
import { useState } from "react";
import { toast } from "sonner";
import { useTranslations } from "next-intl";
import { UpdateOpportunityForm } from "../components/UpdateOpportunityForm";
import {
  Sheet,
  SheetContent,
  SheetDescription,
  SheetHeader,
  SheetTitle,
} from "@/components/ui/sheet";
import { deleteOpportunity } from "@/actions/crm/opportunities/delete-opportunity";

import type { OpportunityConfig } from "./columns";

interface DataTableRowActionsProps<TData> {
  row: Row<TData>;
  config: OpportunityConfig;
}

export function DataTableRowActions<TData>({
  row,
  config,
}: DataTableRowActionsProps<TData>) {
  const router = useRouter();
  const t = useTranslations("CrmPage");
  const opportunity = opportunitySchema.parse(row.original);

  const [open, setOpen] = useState(false);
  const [loading, setLoading] = useState(false);
  const [updateOpen, setUpdateOpen] = useState(false);


  const onDelete = async () => {
    setLoading(true);
    try {
      const result = await deleteOpportunity(opportunity?.id);
      if (result.error) {
        toast.error(result.error);
      } else {
        toast.success("商談を削除しました");
      }
    } catch (error) {
      toast.error("商談を削除できませんでした。もう一度お試しください。");
    } finally {
      setLoading(false);
      setOpen(false);
      router.refresh();
    }
  };

  return (
    <>
      <AlertModal
        isOpen={open}
        onClose={() => setOpen(false)}
        onConfirm={onDelete}
        loading={loading}
        description={t("softDeleteDescription")}
      />
      <Sheet open={updateOpen} onOpenChange={setUpdateOpen}>
        <SheetContent className="w-full md:max-w-[771px] overflow-y-auto">
          <SheetHeader>
            <SheetTitle>{"商談を編集："}{opportunity?.name}</SheetTitle>
            <SheetDescription>{"商談の詳細を更新します"}</SheetDescription>
          </SheetHeader>
          <div className="mt-6 space-y-4">
            <UpdateOpportunityForm
              initialData={row.original}
              setOpen={setUpdateOpen}
              saleTypes={config.saleTypes}
              saleStages={config.saleStages}
              campaigns={config.campaigns}
              currencies={config.currencies}
            />
          </div>
        </SheetContent>
      </Sheet>
      <DropdownMenu>
        <DropdownMenuTrigger asChild>
          <Button
            variant="ghost"
            className="flex h-8 w-8 p-0 data-[state=open]:bg-muted"
          >
            <DotsHorizontalIcon className="h-4 w-4" />
            <span className="sr-only">{"メニューを開く"}</span>
          </Button>
        </DropdownMenuTrigger>
        <DropdownMenuContent align="end" className="w-[160px]">
          <DropdownMenuItem
            onClick={() => router.push(`/crm/opportunities/${opportunity?.id}`)}
          >
            {"表示"}</DropdownMenuItem>
          <DropdownMenuItem onClick={() => setUpdateOpen(true)}>
            {"更新"}</DropdownMenuItem>
          <DropdownMenuSeparator />
          <DropdownMenuItem onClick={() => setOpen(true)}>
            {"削除"}<DropdownMenuShortcut>⌘⌫</DropdownMenuShortcut>
          </DropdownMenuItem>
        </DropdownMenuContent>
      </DropdownMenu>
    </>
  );
}
