import {
  CheckCircledIcon,
  CircleIcon,
  CrossCircledIcon,
  StopwatchIcon,
} from "@radix-ui/react-icons";

export const labels = [
  { value: "bug", label: "不具合" },
  { value: "feature", label: "機能追加" },
  { value: "documentation", label: "資料作成" },
];

export const documentSystemTypes = [
  { value: "RECEIPT", label: "領収書" },
  { value: "CONTRACT", label: "契約書" },
  { value: "OFFER", label: "見積書" },
  { value: "OTHER", label: "その他" },
];

export const processingStatuses = [
  { value: "PENDING", label: "保留中", icon: CircleIcon },
  { value: "PROCESSING", label: "処理中", icon: StopwatchIcon },
  { value: "READY", label: "手配可能", icon: CheckCircledIcon },
  { value: "FAILED", label: "失敗", icon: CrossCircledIcon },
];

// Keep legacy exports for any remaining references
export const statuses = processingStatuses;
export const priorities = [
  { label: "低", value: "low" },
  { label: "通常", value: "normal" },
  { label: "高", value: "high" },
  { label: "緊急", value: "critical" },
];
