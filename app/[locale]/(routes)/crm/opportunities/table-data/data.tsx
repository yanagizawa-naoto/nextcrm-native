import {
  CircleIcon,
  QuestionMarkCircledIcon,
  StopwatchIcon,
} from "@radix-ui/react-icons";

export const statuses = [
  {
    value: "ACTIVE",
    label: "有効",
    icon: QuestionMarkCircledIcon,
  },
  {
    value: "INACTIVE",
    label: "無効",
    icon: CircleIcon,
  },
  {
    value: "PENDING",
    label: "保留中",
    icon: CircleIcon,
  },
  {
    value: "CLOSED",
    label: "終了",
    icon: StopwatchIcon,
  },
];
