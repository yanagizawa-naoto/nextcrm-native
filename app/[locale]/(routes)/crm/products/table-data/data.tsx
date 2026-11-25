import {
  BoxIcon,
  WrenchIcon,
  FileEditIcon,
  CheckCircle2Icon,
  ArchiveIcon,
  CalendarIcon,
  CalendarDaysIcon,
  CalendarRangeIcon,
  TimerIcon,
} from "lucide-react";

export const productTypes = [
  {
    value: "PRODUCT",
    label: "商品",
    icon: BoxIcon,
  },
  {
    value: "SERVICE",
    label: "サービス",
    icon: WrenchIcon,
  },
];

export const productStatuses = [
  {
    value: "DRAFT",
    label: "下書き",
    icon: FileEditIcon,
  },
  {
    value: "ACTIVE",
    label: "有効",
    icon: CheckCircle2Icon,
  },
  {
    value: "ARCHIVED",
    label: "アーカイブ済み",
    icon: ArchiveIcon,
  },
];

export const billingPeriods = [
  {
    value: "MONTHLY",
    label: "毎月",
    icon: CalendarIcon,
  },
  {
    value: "QUARTERLY",
    label: "3か月ごと",
    icon: CalendarDaysIcon,
  },
  {
    value: "ANNUALLY",
    label: "毎年",
    icon: CalendarRangeIcon,
  },
  {
    value: "ONE_TIME",
    label: "1回のみ",
    icon: TimerIcon,
  },
];
