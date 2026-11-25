"use client";

interface Activity {
  id: string;
  action: string;
  meta: Record<string, unknown> | null;
  createdAt: string;
}

interface ActivityLogProps {
  activities: Activity[];
}

const ACTION_LABELS: Record<string, string> = {
  CREATED: "請求書を作成しました",
  ISSUED: "請求書を発行しました",
  SENT: "請求書をメールで送付しました",
  PAYMENT_ADDED: "入金を登録しました",
  PAYMENT_DELETED: "入金を削除しました",
  CANCELLED: "請求書を取り消しました",
  DUPLICATED: "請求書を複製しました",
  UPDATED: "請求書を更新しました",
  STATUS_CHANGED: "状態を変更しました",
};

export function ActivityLog({ activities }: ActivityLogProps) {
  if (activities.length === 0) {
    return (
      <p className="text-sm text-muted-foreground py-4">{"活動履歴はまだありません"}</p>
    );
  }

  return (
    <div className="space-y-3">
      {activities.map((a) => (
        <div key={a.id} className="flex items-start gap-3">
          <div className="w-2 h-2 mt-2 rounded-full bg-primary flex-shrink-0" />
          <div className="text-sm">
            <p className="font-medium">
              {ACTION_LABELS[a.action] ?? a.action}
            </p>
            <p className="text-muted-foreground text-xs">
              {new Date(a.createdAt).toLocaleString("ja-JP")}
            </p>
          </div>
        </div>
      ))}
    </div>
  );
}
