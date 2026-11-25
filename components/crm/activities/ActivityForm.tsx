"use client";
import { useState } from "react";
import { toast } from "sonner";
import {
  Sheet,
  SheetContent,
  SheetHeader,
  SheetTitle,
} from "@/components/ui/sheet";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Textarea } from "@/components/ui/textarea";
import { Label } from "@/components/ui/label";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { createActivity } from "@/actions/crm/activities/create-activity";
import { updateActivity } from "@/actions/crm/activities/update-activity";
import type { ActivityWithLinks } from "@/actions/crm/activities/get-activities-by-entity";

type ActivityType = "call" | "meeting" | "note" | "email" | "visit";
type ActivityStatus = "scheduled" | "completed" | "cancelled";

const DEFAULT_STATUS: Record<ActivityType, ActivityStatus> = {
  call: "scheduled",
  meeting: "scheduled",
  note: "completed",
  email: "completed",
  visit: "scheduled",
};

interface Props {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  entityType: string;
  entityId: string;
  activity?: ActivityWithLinks; // if provided: edit mode
  onSaved: (activity: ActivityWithLinks) => void;
}

export function ActivityForm({ open, onOpenChange, entityType, entityId, activity, onSaved }: Props) {
  const isEdit = !!activity;

  const [type, setType] = useState<ActivityType>(activity?.type ?? "call");
  const [title, setTitle] = useState(activity?.title ?? "");
  const [description, setDescription] = useState(activity?.description ?? "");
  const [date, setDate] = useState(
    activity ? new Date(activity.date).toISOString().slice(0, 16) : ""
  );
  const [status, setStatus] = useState<ActivityStatus>(activity?.status ?? "scheduled");
  const [duration, setDuration] = useState(activity?.duration?.toString() ?? "");
  const [outcome, setOutcome] = useState(activity?.outcome ?? "");
  const [emailSubject, setEmailSubject] = useState(
    (activity?.metadata as Record<string, string> | null)?.subject ?? ""
  );
  const [saving, setSaving] = useState(false);

  // Auto-set status when type changes (only in create mode)
  const handleTypeChange = (newType: ActivityType) => {
    setType(newType);
    if (!isEdit) {
      setStatus(DEFAULT_STATUS[newType]);
    }
  };

  const showDuration = type === "call" || type === "meeting" || type === "visit";
  const showOutcome = type === "call" || type === "meeting" || type === "visit";
  const showEmailSubject = type === "email";

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!title.trim()) {
      toast.error("件名を入力してください");
      return;
    }
    if (!date) {
      toast.error("日付を入力してください");
      return;
    }

    setSaving(true);

    const metadata: Record<string, unknown> = {};
    if (showEmailSubject && emailSubject) metadata.subject = emailSubject;

    const payload = {
      type,
      title: title.trim(),
      description: description.trim() || undefined,
      date: new Date(date),
      duration: showDuration && duration ? parseInt(duration, 10) : undefined,
      outcome: showOutcome && outcome.trim() ? outcome.trim() : undefined,
      status,
      metadata: Object.keys(metadata).length > 0 ? metadata : undefined,
      links: [{ entityType, entityId }],
    };

    let result: { data?: ActivityWithLinks; error?: string };

    if (isEdit) {
      result = await updateActivity({ id: activity.id, ...payload });
    } else {
      result = await createActivity(payload);
    }

    setSaving(false);

    if (result.error) {
      toast.error(result.error);
    } else if (result.data) {
      toast.success(isEdit ? "活動を更新しました" : "活動を記録しました");
      onSaved(result.data as ActivityWithLinks);
      onOpenChange(false);
    }
  };

  return (
    <Sheet open={open} onOpenChange={onOpenChange}>
      <SheetContent className="sm:max-w-[480px] overflow-y-auto">
        <SheetHeader>
          <SheetTitle>{isEdit ? "活動を編集" : "活動を記録"}</SheetTitle>
        </SheetHeader>
        <form onSubmit={handleSubmit} className="space-y-4 mt-4">
          <div className="space-y-1">
            <Label htmlFor="activity-type">{"種別"}</Label>
            <Select value={type} onValueChange={(v) => handleTypeChange(v as ActivityType)}>
              <SelectTrigger id="activity-type">
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value="call">{"電話"}</SelectItem>
                <SelectItem value="meeting">{"面談"}</SelectItem>
                <SelectItem value="visit">{"訪問"}</SelectItem>
                <SelectItem value="note">{"備考"}</SelectItem>
                <SelectItem value="email">{"メールアドレス"}</SelectItem>
              </SelectContent>
            </Select>
          </div>

          <div className="space-y-1">
            <Label htmlFor="activity-title">{"件名（必須）"}</Label>
            <Input
              id="activity-title"
              value={title}
              onChange={(e) => setTitle(e.target.value)}
              placeholder="概要を入力"
              required
            />
          </div>

          <div className="space-y-1">
            <Label htmlFor="activity-date">{"日時（必須）"}</Label>
            <Input
              id="activity-date"
              type="datetime-local"
              value={date}
              onChange={(e) => setDate(e.target.value)}
              required
            />
          </div>

          <div className="space-y-1">
            <Label htmlFor="activity-status">{"状態"}</Label>
            <Select value={status} onValueChange={(v) => setStatus(v as ActivityStatus)}>
              <SelectTrigger id="activity-status">
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value="scheduled">{"予約済み"}</SelectItem>
                <SelectItem value="completed">{"完了"}</SelectItem>
                <SelectItem value="cancelled">{"取消済み"}</SelectItem>
              </SelectContent>
            </Select>
          </div>

          {showDuration && (
            <div className="space-y-1">
              <Label htmlFor="activity-duration">{"所要時間（分）"}</Label>
              <Input
                id="activity-duration"
                type="number"
                min="1"
                value={duration}
                onChange={(e) => setDuration(e.target.value)}
                placeholder="e.g. 30"
              />
            </div>
          )}

          {showOutcome && (
            <div className="space-y-1">
              <Label htmlFor="activity-outcome">{"結果"}</Label>
              <Input
                id="activity-outcome"
                value={outcome}
                onChange={(e) => setOutcome(e.target.value)}
                placeholder="電話・面談の結果"
              />
            </div>
          )}

          {showEmailSubject && (
            <div className="space-y-1">
              <Label htmlFor="activity-email-subject">{"メールの件名"}</Label>
              <Input
                id="activity-email-subject"
                value={emailSubject}
                onChange={(e) => setEmailSubject(e.target.value)}
                placeholder="件名"
              />
            </div>
          )}

          <div className="space-y-1">
            <Label htmlFor="activity-description">{"メモ"}</Label>
            <Textarea
              id="activity-description"
              value={description}
              onChange={(e) => setDescription(e.target.value)}
              placeholder="補足メモ…"
              rows={4}
            />
          </div>

          <div className="flex justify-end gap-2 pt-2">
            <Button type="button" variant="outline" onClick={() => onOpenChange(false)}>
              {"取消"}</Button>
            <Button type="submit" disabled={saving}>
              {saving ? "保存中…" : isEdit ? "変更を保存" : "活動を記録"}
            </Button>
          </div>
        </form>
      </SheetContent>
    </Sheet>
  );
}
