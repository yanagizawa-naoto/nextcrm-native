import { StopIcon, PauseIcon, PlayIcon } from "@radix-ui/react-icons";

export const statuses = [
  {
    value: "ACTIVE",
    label: "有効",
    icon: PlayIcon,
  },
  {
    value: "INACTIVE",
    label: "無効",
    icon: StopIcon,
  },
  {
    value: "PENDING",
    label: "保留中",
    icon: PauseIcon,
  },
];
export const roles = [
  {
    value: "admin",
    label: "管理者",
    icon: PlayIcon,
  },
  {
    value: "manager",
    label: "マネージャー",
    icon: PauseIcon,
  },
  {
    value: "user",
    label: "一般ユーザー",
    icon: StopIcon,
  },
  {
    value: "partner",
    label: "パートナー",
    icon: StopIcon,
  },
];
