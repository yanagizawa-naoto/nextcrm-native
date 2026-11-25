import {
  CircleIcon,
  QuestionMarkCircledIcon,
  StopwatchIcon,
} from "@radix-ui/react-icons";

export const statuses = [
  {
    value: "NEW",
    label: "新規",
    icon: QuestionMarkCircledIcon,
  },
  {
    value: "IN_PROGRESS",
    label: "進行中",
    icon: StopwatchIcon,
  },
  {
    value: "COMPLETED",
    label: "完了",
    icon: StopwatchIcon,
  },
];
