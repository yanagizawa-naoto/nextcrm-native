"use client";

import { DotsHorizontalIcon } from "@radix-ui/react-icons";
import { Row } from "@tanstack/react-table";

import { Button } from "@/components/ui/button";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";

import { useParams } from "next/navigation";
import { taskSchema } from "../data/schema";
import { useRouter } from "next/navigation";
import DocumentViewModal from "@/components/modals/document-view-modal";
import { useState } from "react";
import { toast } from "sonner";
import { disconnectDocumentFromCrmTask } from "@/actions/crm/tasks/assign-document";

interface DataTableRowActionsProps<TData> {
  row: Row<TData>;
}

export function DataTableRowActionsTasks<TData>({
  row,
}: DataTableRowActionsProps<TData>) {
  const [open, setOpen] = useState(false);
  const [loading, setLoading] = useState(false);
  const document = taskSchema.parse(row.original);

  const router = useRouter();
  const params = useParams();

  //console.log(params, "params");


  const onDisconnect = async () => {
    setLoading(true);
    try {
      const result = await disconnectDocumentFromCrmTask({
        documentId: document.id,
        taskId: params?.taskId as string,
      });
      if (result?.error) {
        toast.error(result.error);
      } else {
        toast.success("タスクとの関連を解除しました");
      }
    } catch (error) {
      console.error(error);
      toast.error("タスクとの関連を解除できませんでした");
    } finally {
      router.refresh();
      setLoading(false);
    }
  };

  return (
    <>
      <DocumentViewModal
        isOpen={open}
        onClose={() => setOpen(false)}
        loading={loading}
        document={document}
      />
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
        <DropdownMenuContent align="end" className="w-[260px]">
          <DropdownMenuItem onClick={onDisconnect}>
            {"タスクとの関連を解除"}</DropdownMenuItem>
          <DropdownMenuItem onClick={() => setOpen(true)}>
            {"表示"}</DropdownMenuItem>
        </DropdownMenuContent>
      </DropdownMenu>
    </>
  );
}
