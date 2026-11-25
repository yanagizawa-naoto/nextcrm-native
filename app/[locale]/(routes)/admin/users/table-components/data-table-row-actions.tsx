"use client";

import { Row } from "@tanstack/react-table";

import { Button } from "@/components/ui/button";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuLabel,
  DropdownMenuSeparator,
  DropdownMenuSub,
  DropdownMenuSubContent,
  DropdownMenuSubTrigger,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";

import { adminUserSchema } from "../table-data/schema";
import { useRouter } from "next/navigation";
import AlertModal from "@/components/modals/alert-modal";
import { useState } from "react";
import { toast } from "sonner";

import { Building2, Copy, Edit, KeyRound, MoreHorizontal, Shield, Trash, UserCheck, UserX } from "lucide-react";
import { deleteUser } from "@/actions/admin/users/delete-user";
import { activateUser } from "@/actions/admin/users/activate-user";
import { deactivateUser } from "@/actions/admin/users/deactivate-user";
import { setUserRole } from "@/actions/admin/users/set-role";
import { revokeUserApiTokens } from "@/actions/admin/users/revoke-api-tokens";
import type { AppRole } from "@/lib/authz";
import { PartnerAccountDialog } from "../components/partner-account-dialog";

interface DataTableRowActionsProps<TData> {
  row: Row<TData>;
}

export function DataTableRowActions<TData>({
  row,
}: DataTableRowActionsProps<TData>) {
  const router = useRouter();
  const data = adminUserSchema.parse(row.original);

  const [open, setOpen] = useState(false);
  const [partnerAccountOpen, setPartnerAccountOpen] = useState(false);
  const [loading, setLoading] = useState(false);

  const onCopy = (id: string) => {
    navigator.clipboard.writeText(id);
    toast.success("URLをコピーしました。");
  };

  const onDelete = async () => {
    try {
      setLoading(true);
      const result = await deleteUser(data.id);
      if (result.error) {
        toast.error(result.error);
        return;
      }
      router.refresh();
      toast.success("ユーザーを削除しました");
    } catch (error) {
      toast.error("Something went wrong: " + error + ". Please try again.");
    } finally {
      setLoading(false);
      setOpen(false);
    }
  };

  const onActivate = async () => {
    try {
      setLoading(true);
      const result = await activateUser(data.id);
      if (result.error) {
        toast.error(result.error);
        return;
      }
      router.refresh();
      toast.success("ユーザーを有効にしました。");
    } catch (error) {
      toast.error("ユーザーを有効にできませんでした。もう一度お試しください。");
    } finally {
      setLoading(false);
    }
  };

  const onDeactivate = async () => {
    try {
      setLoading(true);
      const result = await deactivateUser(data.id);
      if (result.error) {
        toast.error(result.error);
        return;
      }
      router.refresh();
      toast.success("ユーザーを無効にしました。");
    } catch (error) {
      toast.error("ユーザーを無効にできませんでした。もう一度お試しください。");
    } finally {
      setLoading(false);
    }
  };

  const onRevokeTokens = async () => {
    try {
      setLoading(true);
      const result = await revokeUserApiTokens(data.id);
      if (result.error) {
        toast.error(result.error);
        return;
      }
      toast.success(`Revoked ${result.data?.revoked ?? 0} API token(s).`);
    } catch (error) {
      toast.error("APIトークンを失効できませんでした。もう一度お試しください。");
    } finally {
      setLoading(false);
    }
  };

  const onSetRole = async (role: AppRole) => {
    try {
      setLoading(true);
      const result = await setUserRole(data.id, role);
      if (result.error) {
        toast.error(result.error);
        return;
      }
      router.refresh();
      toast.success(`User role changed to ${role}.`);
    } catch (error) {
      toast.error("権限を変更できませんでした。もう一度お試しください。");
    } finally {
      setLoading(false);
    }
  };

  return (
    <>
      <AlertModal
        isOpen={open}
        onClose={() => setOpen(false)}
        onConfirm={onDelete}
        loading={loading}
      />
      {data.role === "partner" && (
        <PartnerAccountDialog
          userId={data.id}
          partnerAccountId={data.partnerAccountId ?? null}
          open={partnerAccountOpen}
          onOpenChange={setPartnerAccountOpen}
        />
      )}
      <DropdownMenu>
        <DropdownMenuTrigger asChild>
          <Button variant={"ghost"} className="h-8 w-8 p-0">
            <span className="sr-only">{"メニューを開く"}</span>
            <MoreHorizontal className="h-4 w-4" />
          </Button>
        </DropdownMenuTrigger>
        <DropdownMenuContent align="end">
          <DropdownMenuLabel>{"操作"}</DropdownMenuLabel>
          <DropdownMenuItem onClick={() => onCopy(data?.id)}>
            <Copy className="mr-2 w-4 h-4" />
            {"IDをコピー"}</DropdownMenuItem>
          <DropdownMenuSeparator />
          <DropdownMenuItem onClick={() => onActivate()}>
            <UserCheck className="mr-2 w-4 h-4" />
            {"有効にする"}</DropdownMenuItem>
          <DropdownMenuItem onClick={() => onDeactivate()}>
            <UserX className="mr-2 w-4 h-4" />
            {"無効にする"}</DropdownMenuItem>
          <DropdownMenuItem onClick={() => onRevokeTokens()}>
            <KeyRound className="mr-2 w-4 h-4" />
            {"APIトークンを失効"}</DropdownMenuItem>
          <DropdownMenuSeparator />
          <DropdownMenuSub>
            <DropdownMenuSubTrigger>
              <Shield className="mr-2 w-4 h-4" />
              {"権限を変更"}</DropdownMenuSubTrigger>
            <DropdownMenuSubContent>
              <DropdownMenuItem onClick={() => onSetRole("admin")}>
                {"管理者"}</DropdownMenuItem>
              <DropdownMenuItem onClick={() => onSetRole("manager")}>
                {"マネージャー"}</DropdownMenuItem>
              <DropdownMenuItem onClick={() => onSetRole("user")}>
                {"一般ユーザー"}</DropdownMenuItem>
              <DropdownMenuItem onClick={() => onSetRole("partner")}>
                {"パートナー"}</DropdownMenuItem>
            </DropdownMenuSubContent>
          </DropdownMenuSub>
          {data.role === "partner" && (
            <DropdownMenuItem onClick={() => setPartnerAccountOpen(true)}>
              <Building2 className="mr-2 w-4 h-4" />
              {"パートナー企業"}</DropdownMenuItem>
          )}
          <DropdownMenuSeparator />
          <DropdownMenuItem onClick={() => setOpen(true)}>
            <Trash className="mr-2 w-4 h-4" />
            {"削除"}</DropdownMenuItem>
        </DropdownMenuContent>
      </DropdownMenu>
    </>
  );
}
