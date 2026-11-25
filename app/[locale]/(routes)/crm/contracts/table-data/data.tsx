import {
  CircleIcon,
  QuestionMarkCircledIcon,
  StopwatchIcon,
} from "@radix-ui/react-icons";
import { PenLineIcon, Rotate3D } from "lucide-react";

export const statuses = [
  {
    value: "NOTSTARTED",
    label: "未開始",
    icon: QuestionMarkCircledIcon,
  },
  {
    value: "INPROGRESS",
    label: "進行中",
    icon: Rotate3D,
  },
  {
    value: "SIGNED",
    label: "署名済み",
    icon: PenLineIcon,
  },
];
