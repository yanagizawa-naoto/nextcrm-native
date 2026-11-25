"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Textarea } from "@/components/ui/textarea";
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogTrigger,
} from "@/components/ui/dialog";
import { Send } from "lucide-react";
import { sendInvoiceEmail } from "@/actions/invoices/send-invoice-email";

interface SendEmailDialogProps {
  invoiceId: string;
  defaultEmail?: string;
}

export function SendEmailDialog({
  invoiceId,
  defaultEmail,
}: SendEmailDialogProps) {
  const router = useRouter();
  const [open, setOpen] = useState(false);
  const [sending, setSending] = useState(false);
  const [to, setTo] = useState(defaultEmail ?? "");
  const [subject, setSubject] = useState("");
  const [message, setMessage] = useState("");

  const handleSend = async () => {
    if (!to) {
      toast.error("メールアドレスを入力してください");
      return;
    }
    setSending(true);
    try {
      await sendInvoiceEmail({
        invoiceId,
        to,
        subject: subject || undefined,
        message: message || undefined,
      });
      toast.success("請求書をメールで送信しました");
      setOpen(false);
      router.refresh();
    } catch {
      toast.error("メールを送信できませんでした");
    } finally {
      setSending(false);
    }
  };

  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogTrigger asChild>
        <Button variant="outline" size="sm">
          <Send className="mr-2 h-4 w-4" />
          {"メールで送付"}</Button>
      </DialogTrigger>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>{"請求書をメールで送付"}</DialogTitle>
        </DialogHeader>
        <div className="space-y-4">
          <div className="space-y-2">
            <Label>{"終了日"}</Label>
            <Input
              type="email"
              value={to}
              onChange={(e) => setTo(e.target.value)}
              placeholder="recipient@example.com"
            />
          </div>
          <div className="space-y-2">
            <Label>{"件名（任意）"}</Label>
            <Input
              value={subject}
              onChange={(e) => setSubject(e.target.value)}
              placeholder="任意の件名"
            />
          </div>
          <div className="space-y-2">
            <Label>{"本文（任意）"}</Label>
            <Textarea
              value={message}
              onChange={(e) => setMessage(e.target.value)}
              placeholder="添えるメッセージ（任意）"
              rows={3}
            />
          </div>
          <Button onClick={handleSend} disabled={sending || !to}>
            {sending ? "送信中…" : "送信"}
          </Button>
        </div>
      </DialogContent>
    </Dialog>
  );
}
