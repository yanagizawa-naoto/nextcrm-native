"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createTargetList } from "@/actions/crm/target-lists/create-target-list";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Textarea } from "@/components/ui/textarea";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
  DialogTrigger,
} from "@/components/ui/dialog";
import { Label } from "@/components/ui/label";

const CreateTargetListModal = () => {
  const router = useRouter();
  const [open, setOpen] = useState(false);
  const [isLoading, setIsLoading] = useState(false);
  const [name, setName] = useState("");
  const [description, setDescription] = useState("");

  const handleCreate = async () => {
    if (!name.trim()) {
      toast.error("名称を入力してください。");
      return;
    }

    setIsLoading(true);
    const result = await createTargetList({ name, description });
    setIsLoading(false);
    if (result.error) {
      toast.error(result.error);
      return;
    }
    toast.success("営業対象リストを作成しました");
    setOpen(false);
    setName("");
    setDescription("");
    router.refresh();
  };

  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogTrigger asChild>
        <Button size="sm">{"＋ リストを作成"}</Button>
      </DialogTrigger>
      <DialogContent className="sm:max-w-md">
        <DialogHeader>
          <DialogTitle>{"営業対象リストを作成"}</DialogTitle>
          <DialogDescription>
            {"キャンペーンや営業活動の対象をまとめるリストを作成します。"}</DialogDescription>
        </DialogHeader>
        <div className="space-y-4">
          <div className="space-y-2">
            <Label htmlFor="name">{"名称（必須）"}</Label>
            <Input
              id="name"
              placeholder="第1四半期の営業対象"
              value={name}
              onChange={(e) => setName(e.target.value)}
              disabled={isLoading}
            />
          </div>
          <div className="space-y-2">
            <Label htmlFor="description">{"品名・内容"}</Label>
            <Textarea
              id="description"
              placeholder="第1四半期に連絡する営業対象のリスト"
              value={description}
              onChange={(e) => setDescription(e.target.value)}
              disabled={isLoading}
            />
          </div>
        </div>
        <DialogFooter>
          <Button variant="outline" onClick={() => setOpen(false)} disabled={isLoading}>
            {"取消"}</Button>
          <Button onClick={handleCreate} disabled={isLoading || !name.trim()}>
            {isLoading ? "作成中…" : "作成"}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
};

export default CreateTargetListModal;
