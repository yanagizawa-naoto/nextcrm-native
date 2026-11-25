"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { FileCheck2, Loader2 } from "lucide-react";
import { requestApproval } from "@/actions/crm/opportunities/approval";

const RequestApprovalButton = ({ opportunityId }: { opportunityId: string }) => {
  const router = useRouter();
  const [loading, setLoading] = useState(false);

  const submit = async () => {
    setLoading(true);
    try {
      const res = await requestApproval(opportunityId);
      if (res.error) toast.error(res.error);
      else {
        toast.success("承認を申請し、承認担当者に通知しました。");
        router.refresh();
      }
    } finally {
      setLoading(false);
    }
  };

  return (
    <Button variant="outline" size="sm" onClick={submit} disabled={loading}>
      {loading ? (
        <Loader2 className="h-4 w-4 mr-2 animate-spin" />
      ) : (
        <FileCheck2 className="h-4 w-4 mr-2" />
      )}
      {"承認を申請"}</Button>
  );
};

export default RequestApprovalButton;
