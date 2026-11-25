"use client";

import { useRouter } from "next/navigation";
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogDescription,
  DialogFooter,
} from "@/components/ui/dialog";
import { Button } from "@/components/ui/button";

interface NoApiKeyDialogProps {
  open: boolean;
  onClose: () => void;
}

export function NoApiKeyDialog({ open, onClose }: NoApiKeyDialogProps) {
  const router = useRouter();

  const handleGoToSettings = () => {
    onClose();
    router.push("/profile?tab=llms");
  };

  return (
    <Dialog open={open} onOpenChange={(isOpen) => { if (!isOpen) onClose(); }}>
      <DialogContent className="sm:max-w-[420px]">
        <DialogHeader>
          <DialogTitle>{"APIキーの設定が必要です"}</DialogTitle>
          <DialogDescription>
            {"情報補完にはAPIキーが必要です。プロフィールで設定するか、管理者にシステム共通キーの設定を依頼してください。"}</DialogDescription>
        </DialogHeader>
        <DialogFooter>
          <Button variant="outline" onClick={onClose}>
            {"閉じる"}</Button>
          <Button onClick={handleGoToSettings}>
            {"設定を開く"}</Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
