"use client";

import { useRouter } from "next/navigation";

import { Button } from "@/components/ui/button";

const TryAgain = () => {
  const router = useRouter();
  return <Button onClick={() => router.refresh()}>{"再試行"}</Button>;
};

export default TryAgain;
