"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { removeTargetFromList } from "@/actions/crm/target-lists/remove-target-from-list";
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { toast } from "sonner";
import { CalendarDays, Trash2, User, Users } from "lucide-react";
import moment from "moment";
import Link from "next/link";
import AddTargetToListModal from "@/components/modals/AddTargetToListModal";
import ExportTargetsButton from "@/components/campaigns/ExportTargetsButton";

interface TargetListBasicViewProps {
  data: any;
}

export function BasicView({ data }: TargetListBasicViewProps) {
  const router = useRouter();
  const [addOpen, setAddOpen] = useState(false);
  const [removingId, setRemovingId] = useState<string | null>(null);

  if (!data) return <div>{"営業対象リストが見つかりません"}</div>;

  const existingTargetIds: string[] = (data.targets ?? []).map((t: any) => t.target_id);

  const handleRemove = async (targetId: string) => {
    setRemovingId(targetId);
    const result = await removeTargetFromList(data.id, targetId);
    setRemovingId(null);
    if (result.error) {
      toast.error(result.error);
      return;
    }
    toast.success("リストから営業対象を外しました");
    router.refresh();
  };

  return (
    <div className="pb-3 space-y-5">
      <Card>
        <CardHeader className="pb-3">
          <div className="flex w-full justify-between">
            <div>
              <CardTitle>{data.name}</CardTitle>
              <CardDescription>{"ID："}{data.id}</CardDescription>
            </div>
          </div>
        </CardHeader>
        <CardContent>
          <div className="grid grid-cols-2 w-full">
            <div>
              <div className="-mx-2 flex items-start space-x-4 rounded-md p-2 transition-all hover:bg-accent hover:text-accent-foreground">
                <Users className="mt-px h-5 w-5" />
                <div className="space-y-1">
                  <p className="text-sm font-medium leading-none">{"品名・内容"}</p>
                  <p className="text-sm text-muted-foreground">
                    {data.description || "N/A"}
                  </p>
                </div>
              </div>
              <div className="-mx-2 flex items-start space-x-4 rounded-md p-2 transition-all hover:bg-accent hover:text-accent-foreground">
                <Users className="mt-px h-5 w-5" />
                <div className="space-y-1">
                  <p className="text-sm font-medium leading-none">{"状態"}</p>
                  <p className="text-sm text-muted-foreground">
                    {data.status ? "有効" : "無効"}
                  </p>
                </div>
              </div>
            </div>
            <div>
              <div className="-mx-2 flex items-start space-x-4 rounded-md p-2 transition-all hover:bg-accent hover:text-accent-foreground">
                <User className="mt-px h-5 w-5" />
                <div className="space-y-1">
                  <p className="text-sm font-medium leading-none">{"作成者"}</p>
                  <p className="text-sm text-muted-foreground">
                    {data.crate_by_user?.name || "N/A"}
                  </p>
                </div>
              </div>
              <div className="-mx-2 flex items-start space-x-4 rounded-md p-2 transition-all hover:bg-accent hover:text-accent-foreground">
                <CalendarDays className="mt-px h-5 w-5" />
                <div className="space-y-1">
                  <p className="text-sm font-medium leading-none">{"作成日"}</p>
                  <p className="text-sm text-muted-foreground">
                    {data.created_on
                      ? moment(data.created_on).format("YYYY年M月D日")
                      : "N/A"}
                  </p>
                </div>
              </div>
            </div>
          </div>
        </CardContent>
      </Card>

      <Card>
        <CardHeader className="pb-3">
          <div className="flex items-center justify-between">
            <CardTitle>{"営業対象（"}{data.targets?.length || 0})</CardTitle>
            <div className="flex items-center gap-2">
              <ExportTargetsButton
                getTargets={() =>
                  (data.targets ?? [])
                    .map((t: any) => t.target)
                    .filter(Boolean)
                }
                filenameBase={`${(data.name || "target-list")
                  .replace(/[^a-z0-9-_]+/gi, "-")
                  .toLowerCase()}-targets`}
                disabled={!data.targets || data.targets.length === 0}
              />
              <Button size="sm" variant="outline" onClick={() => setAddOpen(true)}>
                {"＋ 営業対象を追加"}</Button>
            </div>
          </div>
        </CardHeader>
        <CardContent>
          {!data.targets || data.targets.length === 0 ? (
            <p className="text-sm text-muted-foreground">{"このリストに営業対象はまだありません。"}</p>
          ) : (
            <div className="space-y-2">
              {data.targets.map((t: any) => (
                <div
                  key={t.target_id}
                  className="-mx-2 flex items-center space-x-4 rounded-md p-2 transition-all hover:bg-accent hover:text-accent-foreground"
                >
                  <User className="h-4 w-4 shrink-0" />
                  <div className="flex-1 min-w-0">
                    <Link
                      href={`/campaigns/targets/${t.target?.id}`}
                      className="text-sm font-medium hover:underline"
                    >
                      {t.target?.last_name} {t.target?.first_name}
                    </Link>
                    <p className="text-xs text-muted-foreground">
                      {t.target?.email || t.target?.mobile_phone || "連絡先情報がありません"}
                    </p>
                  </div>
                  {t.target?.company && (
                    <Badge variant="outline">{t.target.company}</Badge>
                  )}
                  <Button
                    size="icon"
                    variant="ghost"
                    className="h-7 w-7 shrink-0 text-muted-foreground hover:text-destructive"
                    disabled={removingId === t.target_id}
                    onClick={() => handleRemove(t.target_id)}
                  >
                    <Trash2 className="h-4 w-4" />
                  </Button>
                </div>
              ))}
            </div>
          )}
        </CardContent>
      </Card>

      <AddTargetToListModal
        targetListId={data.id}
        existingTargetIds={existingTargetIds}
        open={addOpen}
        onOpenChange={setAddOpen}
      />
    </div>
  );
}
