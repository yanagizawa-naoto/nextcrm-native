"use client";

import { Badge } from "@/components/ui/badge";
import { cn } from "@/lib/utils";

const STATUS_CONFIG = {
  PENDING: { label: "保留中", className: "bg-muted text-muted-foreground" },
  PROCESSING: { label: "処理中", className: "bg-yellow-100 text-yellow-800 dark:bg-yellow-900 dark:text-yellow-200" },
  READY: { label: "保存済み", className: "bg-green-100 text-green-800 dark:bg-green-900 dark:text-green-200" },
  FAILED: { label: "失敗", className: "bg-red-100 text-red-800 dark:bg-red-900 dark:text-red-200" },
} as const;

interface ProcessingStatusBadgeProps {
  status: keyof typeof STATUS_CONFIG;
}

export function ProcessingStatusBadge({ status }: ProcessingStatusBadgeProps) {
  const config = STATUS_CONFIG[status];
  return (
    <Badge variant="outline" className={cn("text-xs", config.className)}>
      {config.label}
    </Badge>
  );
}
