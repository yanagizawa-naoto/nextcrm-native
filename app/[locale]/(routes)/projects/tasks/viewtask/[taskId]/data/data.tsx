import {
  ArrowDownIcon,
  ArrowRightIcon,
  ArrowUpIcon,
  CircleIcon,
  QuestionMarkCircledIcon,
  StopwatchIcon,
} from "@radix-ui/react-icons";

export const labels = [
  {
    value: "bug",
    label: "不具合",
  },
  {
    value: "feature",
    label: "機能追加",
  },
  {
    value: "documentation",
    label: "資料作成",
  },
];

export const statuses = [
  {
    value: "ACTIVE",
    label: "有効",
    icon: QuestionMarkCircledIcon,
  },
  {
    value: "PENDING",
    label: "保留中",
    icon: CircleIcon,
  },
  {
    value: "COMPLETE",
    label: "完了",
    icon: StopwatchIcon,
  },
];

export const priorities = [
  {
    label: "低",
    value: "low",
    icon: ArrowDownIcon,
  },
  {
    label: "通常",
    value: "normal",
    icon: ArrowRightIcon,
  },
  {
    label: "高",
    value: "high",
    icon: ArrowUpIcon,
  },
  {
    label: "緊急",
    value: "critical",
    icon: ArrowUpIcon,
  },
];
