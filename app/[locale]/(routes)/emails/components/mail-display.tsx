"use client";

import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { addDays, nextSaturday } from "date-fns";
import { format, addHours } from "date-fns";

import {
  Archive,
  ArchiveX,
  Clock,
  Forward,
  MoreVertical,
  Reply,
  ReplyAll,
  Trash2,
} from "lucide-react";

import {
  DropdownMenuContent,
  DropdownMenuItem,
} from "@/components/ui/dropdown-menu";
import { Avatar, AvatarFallback, AvatarImage } from "@/components/ui/avatar";
import { Button } from "@/components/ui/button";
import { Calendar } from "@/components/ui/calendar";
import {
  DropdownMenu,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { Label } from "@/components/ui/label";
import {
  Popover,
  PopoverContent,
  PopoverTrigger,
} from "@/components/ui/popover";
import { Separator } from "@/components/ui/separator";
import { Switch } from "@/components/ui/switch";
import { Textarea } from "@/components/ui/textarea";
import {
  Tooltip,
  TooltipContent,
  TooltipTrigger,
} from "@/components/ui/tooltip";
import type { Mail } from "@/app/[locale]/(routes)/emails/data";
import { getEmail, deleteEmail } from "@/actions/emails/messages";
import { ComposeModal } from "@/app/[locale]/(routes)/emails/components/ComposeModal";

interface MailDisplayProps {
  mail: Mail | null;
  activeAccountId: string | null;
}

export function MailDisplay({ mail, activeAccountId }: MailDisplayProps) {
  const today = new Date();
  const router = useRouter();

  const [fetchedEmail, setFullEmail] = useState<Awaited<ReturnType<typeof getEmail>> | null>(null);
  const fullEmail = mail?.id ? fetchedEmail : null;

  useEffect(() => {
    if (!mail?.id) return;
    let cancelled = false;
    getEmail(mail.id)
      .then((data) => { if (!cancelled) setFullEmail(data); })
      .catch(() => { if (!cancelled) setFullEmail(null); });
    return () => { cancelled = true; };
  }, [mail?.id]);

  const senderName = fullEmail?.fromName ?? fullEmail?.fromEmail ?? "?";
  const senderInitials = senderName
    .split(" ")
    .map((c) => c[0])
    .join("")
    .toUpperCase();

  async function handleDelete() {
    if (!mail?.id) return;
    try {
      await deleteEmail(mail.id);
      router.refresh();
    } catch (e) {
      console.error("Failed to delete email", e);
    }
  }

  return (
    <div className="flex h-full flex-col">
      <div className="flex items-center p-2">
        <div className="flex items-center gap-2">
          <Tooltip>
            <TooltipTrigger asChild>
              <Button variant="ghost" size="icon" disabled={!mail}>
                <Archive className="h-4 w-4" />
                <span className="sr-only">{"アーカイブ"}</span>
              </Button>
            </TooltipTrigger>
            <TooltipContent>{"アーカイブ"}</TooltipContent>
          </Tooltip>
          <Tooltip>
            <TooltipTrigger asChild>
              <Button variant="ghost" size="icon" disabled={!mail}>
                <ArchiveX className="h-4 w-4" />
                <span className="sr-only">{"迷惑メールに移動"}</span>
              </Button>
            </TooltipTrigger>
            <TooltipContent>{"迷惑メールに移動"}</TooltipContent>
          </Tooltip>
          <Tooltip>
            <TooltipTrigger asChild>
              <Button
                variant="ghost"
                size="icon"
                disabled={!mail}
                onClick={handleDelete}
              >
                <Trash2 className="h-4 w-4" />
                <span className="sr-only">{"ゴミ箱に移動"}</span>
              </Button>
            </TooltipTrigger>
            <TooltipContent>{"ゴミ箱に移動"}</TooltipContent>
          </Tooltip>
          <Separator orientation="vertical" className="mx-1 h-6" />
          <Tooltip>
            <Popover>
              <PopoverTrigger asChild>
                <TooltipTrigger asChild>
                  <Button variant="ghost" size="icon" disabled={!mail}>
                    <Clock className="h-4 w-4" />
                    <span className="sr-only">{"後で通知"}</span>
                  </Button>
                </TooltipTrigger>
              </PopoverTrigger>
              <PopoverContent className="flex w-[535px] p-0">
                <div className="flex flex-col gap-2 border-r px-2 py-4">
                  <div className="px-4 text-sm font-medium">{"再通知の日時"}</div>
                  <div className="grid min-w-[250px] gap-1">
                    <Button
                      variant="ghost"
                      className="justify-start font-normal"
                    >
                      {"今日の後ほど"}{" "}
                      <span className="ml-auto text-muted-foreground">
                        {format(addHours(today, 4), "E, h:m b")}
                      </span>
                    </Button>
                    <Button
                      variant="ghost"
                      className="justify-start font-normal"
                    >
                      {"明日"}<span className="ml-auto text-muted-foreground">
                        {format(addDays(today, 1), "E, h:m b")}
                      </span>
                    </Button>
                    <Button
                      variant="ghost"
                      className="justify-start font-normal"
                    >
                      {"今週末"}<span className="ml-auto text-muted-foreground">
                        {format(nextSaturday(today), "E, h:m b")}
                      </span>
                    </Button>
                    <Button
                      variant="ghost"
                      className="justify-start font-normal"
                    >
                      {"来週"}<span className="ml-auto text-muted-foreground">
                        {format(addDays(today, 7), "E, h:m b")}
                      </span>
                    </Button>
                  </div>
                </div>
                <div className="p-2">
                  <Calendar />
                </div>
              </PopoverContent>
            </Popover>
            <TooltipContent>{"後で通知"}</TooltipContent>
          </Tooltip>
        </div>
        <div className="ml-auto flex items-center gap-2">
          <Tooltip>
            <TooltipTrigger asChild>
              <ComposeModal
                accountId={activeAccountId ?? ""}
                mode="reply"
                replyTo={fullEmail ? (fullEmail as unknown as Mail) : undefined}
                trigger={
                  <Button variant="ghost" size="icon" disabled={!mail}>
                    <Reply className="h-4 w-4" />
                    <span className="sr-only">{"返信"}</span>
                  </Button>
                }
              />
            </TooltipTrigger>
            <TooltipContent>{"返信"}</TooltipContent>
          </Tooltip>
          <Tooltip>
            <TooltipTrigger asChild>
              <Button variant="ghost" size="icon" disabled={!mail}>
                <ReplyAll className="h-4 w-4" />
                <span className="sr-only">{"全員に返信"}</span>
              </Button>
            </TooltipTrigger>
            <TooltipContent>{"全員に返信"}</TooltipContent>
          </Tooltip>
          <Tooltip>
            <TooltipTrigger asChild>
              <ComposeModal
                accountId={activeAccountId ?? ""}
                mode="forward"
                replyTo={fullEmail ? (fullEmail as unknown as Mail) : undefined}
                trigger={
                  <Button variant="ghost" size="icon" disabled={!mail}>
                    <Forward className="h-4 w-4" />
                    <span className="sr-only">{"転送"}</span>
                  </Button>
                }
              />
            </TooltipTrigger>
            <TooltipContent>{"転送"}</TooltipContent>
          </Tooltip>
        </div>
        <Separator orientation="vertical" className="mx-2 h-6" />
        <DropdownMenu>
          <DropdownMenuTrigger asChild>
            <Button variant="ghost" size="icon" disabled={!mail}>
              <MoreVertical className="h-4 w-4" />
              <span className="sr-only">{"その他"}</span>
            </Button>
          </DropdownMenuTrigger>
          <DropdownMenuContent align="end">
            <DropdownMenuItem>{"未読にする"}</DropdownMenuItem>
            <DropdownMenuItem>{"スターを付ける"}</DropdownMenuItem>
            <DropdownMenuItem>{"ラベルを追加"}</DropdownMenuItem>
            <DropdownMenuItem>{"通知を停止"}</DropdownMenuItem>
          </DropdownMenuContent>
        </DropdownMenu>
      </div>
      <Separator />
      {mail ? (
        <div className="flex flex-1 flex-col">
          <div className="flex items-start p-4">
            <div className="flex items-start gap-4 text-sm">
              <Avatar>
                <AvatarImage alt={senderName} />
                <AvatarFallback>{senderInitials}</AvatarFallback>
              </Avatar>
              <div className="grid gap-1">
                <div className="font-semibold">
                  {fullEmail?.fromName ?? fullEmail?.fromEmail ?? "（不明）"}
                </div>
                <div className="line-clamp-1 text-xs">
                  {fullEmail?.subject ?? "（件名なし）"}
                </div>
                <div className="line-clamp-1 text-xs">
                  <span className="font-medium">{"差出人："}</span>{" "}
                  {fullEmail?.fromEmail ?? ""}
                </div>
                {Array.isArray(fullEmail?.toRecipients) && fullEmail.toRecipients.length > 0 && (
                  <div className="line-clamp-1 text-xs">
                    <span className="font-medium">{"宛先："}</span>{" "}
                    {(fullEmail.toRecipients as { name?: string; email: string }[])
                      .map((r) => r.name ?? r.email).join(", ")}
                  </div>
                )}
                {Array.isArray(fullEmail?.ccRecipients) && fullEmail.ccRecipients.length > 0 && (
                  <div className="line-clamp-1 text-xs">
                    <span className="font-medium">{"CC："}</span>{" "}
                    {(fullEmail.ccRecipients as { name?: string; email: string }[])
                      .map((r) => r.name ?? r.email).join(", ")}
                  </div>
                )}
              </div>
            </div>
            {fullEmail?.sentAt && (
              <div className="ml-auto text-xs text-muted-foreground">
                {format(new Date(fullEmail.sentAt), "PPpp")}
              </div>
            )}
          </div>
          <Separator />
          <div className="flex-1 overflow-auto">
            {fullEmail?.bodyHtml ? (
              <iframe
                srcDoc={fullEmail.bodyHtml}
                sandbox="allow-popups allow-popups-to-escape-sandbox"
                referrerPolicy="no-referrer"
                className="w-full border-0"
                style={{ height: "600px", maxHeight: "600px" }}
                title="メール本文"
              />
            ) : (
              <pre className="whitespace-pre-wrap p-4 text-sm font-sans">
                {fullEmail?.bodyText ?? (fullEmail ? "（本文なし）" : "読み込み中…")}
              </pre>
            )}
          </div>
          <Separator className="mt-auto" />
          <div className="p-4">
            <form>
              <div className="grid gap-4">
                <Textarea
                  className="p-4"
                  placeholder={`Reply to ${fullEmail?.fromName ?? fullEmail?.fromEmail ?? "..."}...`}
                />
                <div className="flex items-center">
                  <Label
                    htmlFor="mute"
                    className="flex items-center gap-2 text-xs font-normal"
                  >
                    <Switch id="mute" aria-label="通知を停止" /> {"このスレッドの通知を停止"}</Label>
                  <Button size="sm" className="ml-auto">
                    {"送信"}</Button>
                </div>
              </div>
            </form>
          </div>
        </div>
      ) : (
        <div className="p-8 text-center text-muted-foreground">
          {"メールを選択してください"}</div>
      )}
    </div>
  );
}
