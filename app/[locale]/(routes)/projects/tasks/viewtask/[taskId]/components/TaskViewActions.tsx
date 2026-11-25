"use client";

import { useRouter } from "next/navigation";

import { Button } from "@/components/ui/button";
import { toast } from "sonner";
import { getTaskDone } from "@/app/[locale]/(routes)/projects/actions/get-task-done";
import { Badge } from "@/components/ui/badge";
import { CheckSquare, Pencil } from "lucide-react";
import { Separator } from "@/components/ui/separator";
import {
  Sheet,
  SheetContent,
  SheetDescription,
  SheetHeader,
  SheetTitle,
  SheetTrigger,
} from "@/components/ui/sheet";
import UpdateTaskDialog from "@/app/[locale]/(routes)/projects/dialogs/UpdateTask";
import { useState } from "react";
import { Icons } from "@/components/ui/icons";

const TaskViewActions = ({
  taskId,
  boards,
  initialData,
}: {
  taskId: string;
  boards: any;
  initialData: any;
}) => {
  const router = useRouter();

  const [openEdit, setOpenEdit] = useState(false);
  const [isLoading, setIsLoading] = useState(false);

  //console.log(initialData, "initialData");
  //console.log(openEdit, "openEdit");

  //Actions
  const onDone = async () => {
    setIsLoading(true);
    try {
      await getTaskDone(taskId);
      toast.success("完了");
    } catch (error) {
      toast.error("エラー");
    } finally {
      setIsLoading(false);
      router.refresh();
    }
  };

  return (
    <div className="space-x-2 pb-2">
      {"タスクの操作："}<Separator className="mb-5" />
      {initialData.taskStatus !== "COMPLETE" && (
        <Badge
          variant={"outline"}
          onClick={onDone}
          className="cursor-pointer"
          aria-disabled={isLoading}
        >
          <CheckSquare className="w-4 h-4 mr-2" />
          {isLoading ? (
            <Icons.spinner className="animate-spin w-4 h-4 mr-2" />
          ) : (
            "完了にする"
          )}
        </Badge>
      )}
      <Badge
        variant={"outline"}
        className="cursor-pointer"
        onClick={() => setOpenEdit(true)}
      >
        <Pencil className="w-4 h-4 mr-2" />
        {"編集"}</Badge>
      <Sheet open={openEdit} onOpenChange={() => setOpenEdit(false)}>
        <SheetContent className="max-w-3xl overflow-y-auto">
          <SheetHeader>
            <SheetTitle>{"タスクを編集"}</SheetTitle>
            <SheetDescription>
              {"タスクの内容・期限・優先度・状態・担当者を更新します"}</SheetDescription>
          </SheetHeader>
          <div className="mt-6 space-y-4">
            <UpdateTaskDialog
              boards={boards}
              initialData={initialData}
              onDone={() => setOpenEdit(false)}
            />
          </div>
        </SheetContent>
      </Sheet>
    </div>
  );
};

export default TaskViewActions;
