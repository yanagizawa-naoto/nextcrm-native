"use client";

import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTrigger,
  DialogTitle,
  DialogDescription,
  DialogFooter,
} from "@/components/ui/dialog";
import { toast } from "sonner";
import { TrashIcon } from "lucide-react";
import { useRouter } from "next/navigation";

import React, { useEffect, useState } from "react";
import { deleteProject } from "@/actions/projects/delete-project";

type Props = {
  boardId: string;
  boardName: string;
};

const DeleteProjectDialog = ({ boardId, boardName }: Props) => {
  const [open, setOpen] = useState(false);
  const [isLoading, setIsLoading] = useState(false);

  const [isMounted, setIsMounted] = useState(false);

  const router = useRouter();

  useEffect(() => {
    setIsMounted(true);
  }, []);

  if (!isMounted) {
    return null;
  }

  //Actions

  const onDelete = async () => {
    setIsLoading(true);
    try {
      const result = await deleteProject(boardId);
      if (result?.error) {
        toast.error(result.error);
      } else {
        toast.success(`Project: ${boardName} deleted successfully`);
      }
    } catch (error) {
      toast.error("プロジェクトを削除できませんでした。もう一度お試しください。");
    } finally {
      setOpen(false);
      setIsLoading(false);
      router.refresh();
      router.push("/projects");
    }
  };

  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogTrigger>
        <Button className="px-2" variant={"destructive"} asChild>
          <div className="px-3 gap-2">
            {"プロジェクトを削除"}<TrashIcon size={15} />
          </div>
        </Button>
      </DialogTrigger>
      <DialogContent className="max-w-md">
        <DialogHeader>
          <DialogTitle>{"プロジェクトを削除"}</DialogTitle>
          <DialogDescription>
            {"このプロジェクトを削除しますか？すべてのタスクも削除され、復元できません。"}</DialogDescription>
        </DialogHeader>
        <DialogFooter>
          <Button
            variant="outline"
            onClick={() => setOpen(false)}
          >
            {"取消"}</Button>
          <Button variant="destructive" onClick={onDelete}>
            {isLoading ? "削除中…" : "削除"}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
};

export default DeleteProjectDialog;
