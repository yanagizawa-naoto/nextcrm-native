"use client";
import { useState } from "react";
import { ja } from "date-fns/locale";
import { formatDistanceToNow } from "date-fns";
import { Phone, Users, FileText, Mail, MapPin, Pencil, Trash2 } from "lucide-react";
import { toast } from "sonner";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
  AlertDialogTrigger,
} from "@/components/ui/alert-dialog";
import {
  Tooltip,
  TooltipContent,
  TooltipTrigger,
} from "@/components/ui/tooltip";
import { deleteActivity } from "@/actions/crm/activities/delete-activity";
import { ActivityForm } from "./ActivityForm";
import type { ActivityWithLinks } from "@/actions/crm/activities/get-activities-by-entity";

const TYPE_ICONS = {
  call: Phone,
  meeting: Users,
  note: FileText,
  email: Mail,
  visit: MapPin,
} as const;

const TYPE_LABELS = {
  call: "Call",
  meeting: "Meeting",
  note: "Note",
  email: "Email",
  visit: "Visit",
} as const;

const STATUS_VARIANTS = {
  scheduled: "outline",
  completed: "default",
  cancelled: "secondary",
} as const;

interface Props {
  activity: ActivityWithLinks;
  onDeleted: (id: string) => void;
  onUpdated: (activity: ActivityWithLinks) => void;
  entityType: string;
  entityId: string;
}

export function ActivityEntry({ activity, onDeleted, onUpdated, entityType, entityId }: Props) {
  const [editOpen, setEditOpen] = useState(false);
  const [deleting, setDeleting] = useState(false);

  const Icon = TYPE_ICONS[activity.type];

  const handleDelete = async () => {
    setDeleting(true);
    const result = await deleteActivity(activity.id);
    setDeleting(false);
    if (result.error) {
      toast.error(result.error);
    } else {
      toast.success("活動を削除しました");
      onDeleted(activity.id);
    }
  };

  return (
    <div className="flex gap-3 py-3 border-b last:border-0">
      <div className="mt-1 flex-shrink-0 text-muted-foreground">
        <Icon className="h-4 w-4" />
      </div>
      <div className="flex-1 min-w-0">
        <div className="flex items-start justify-between gap-2">
          <div className="flex-1 min-w-0">
            <p className="font-medium text-sm truncate">{activity.title}</p>
            <div className="flex items-center gap-2 mt-1 flex-wrap">
              <Badge variant="outline" className="text-xs">
                {TYPE_LABELS[activity.type]}
              </Badge>
              <Badge variant={STATUS_VARIANTS[activity.status]} className="text-xs">
                {activity.status}
              </Badge>
            </div>
          </div>
          <div className="flex items-center gap-1 flex-shrink-0">
            <Tooltip>
              <TooltipTrigger asChild>
                <span className="text-xs text-muted-foreground cursor-default">
                  {formatDistanceToNow(new Date(activity.date), { addSuffix: true, locale: ja })}
                </span>
              </TooltipTrigger>
              <TooltipContent>
                {new Date(activity.date).toLocaleString("ja-JP")}
              </TooltipContent>
            </Tooltip>
            <Button
              variant="ghost"
              size="icon"
              className="h-7 w-7"
              onClick={() => setEditOpen(true)}
            >
              <Pencil className="h-3.5 w-3.5" />
            </Button>
            <AlertDialog>
              <AlertDialogTrigger asChild>
                <Button variant="ghost" size="icon" className="h-7 w-7" disabled={deleting}>
                  <Trash2 className="h-3.5 w-3.5" />
                </Button>
              </AlertDialogTrigger>
              <AlertDialogContent>
                <AlertDialogHeader>
                  <AlertDialogTitle>{"この活動を削除しますか？"}</AlertDialogTitle>
                  <AlertDialogDescription>
                    {"次の内容を完全に削除します：「"}{activity.title}{"」。この操作は取り消せません。"}</AlertDialogDescription>
                </AlertDialogHeader>
                <AlertDialogFooter>
                  <AlertDialogCancel>{"取消"}</AlertDialogCancel>
                  <AlertDialogAction onClick={handleDelete}>{"削除"}</AlertDialogAction>
                </AlertDialogFooter>
              </AlertDialogContent>
            </AlertDialog>
          </div>
        </div>
        {activity.description && (
          <p className="text-sm text-muted-foreground mt-1 line-clamp-2">
            {activity.description}
          </p>
        )}
        {activity.outcome && (
          <p className="text-xs text-muted-foreground mt-1">
            <span className="font-medium">{"結果："}</span> {activity.outcome}
          </p>
        )}
      </div>

      <ActivityForm
        open={editOpen}
        onOpenChange={setEditOpen}
        entityType={entityType}
        entityId={entityId}
        activity={activity}
        onSaved={onUpdated}
      />
    </div>
  );
}
