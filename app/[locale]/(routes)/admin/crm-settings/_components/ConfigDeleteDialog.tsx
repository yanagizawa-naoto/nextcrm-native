"use client";
import { useState } from "react";
import { Button } from "@/components/ui/button";
import { Dialog, DialogContent, DialogHeader, DialogTitle, DialogDescription } from "@/components/ui/dialog";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { deleteConfigValue, type CrmConfigType, type ConfigValue } from "../_actions/crm-settings";
import { toast } from "sonner";

interface Props {
  configType: CrmConfigType;
  item: ConfigValue;
  allValues: ConfigValue[];
  open: boolean;
  onOpenChange: (v: boolean) => void;
}

export function ConfigDeleteDialog({ configType, item, allValues, open, onOpenChange }: Props) {
  const others = allValues.filter((v) => v.id !== item.id);
  const [replacementId, setReplacementId] = useState<string>("");
  const [loading, setLoading] = useState(false);

  async function handleDelete() {
    if (item.usageCount > 0 && !replacementId) {
      toast.error("削除前に置き換え先を選択してください");
      return;
    }
    setLoading(true);
    try {
      await deleteConfigValue(configType, item.id, item.usageCount > 0 ? replacementId : undefined);
      toast.success("削除");
      onOpenChange(false);
    } catch (err: any) {
      toast.error(err.message ?? "削除できませんでした");
    } finally {
      setLoading(false);
    }
  }

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>{"削除：「"}{item.name}&quot;</DialogTitle>
          {item.usageCount > 0 && (
            <DialogDescription>
              {item.usageCount} {"件のデータ"}{item.usageCount !== 1 ? "s" : ""} {"で使用中です。削除前に置き換え先を選択してください。"}</DialogDescription>
          )}
        </DialogHeader>
        {item.usageCount > 0 && (
          <div className="py-2">
            <Select onValueChange={setReplacementId}>
              <SelectTrigger><SelectValue placeholder="置き換え先を選択…" /></SelectTrigger>
              <SelectContent>
                {others.map((o) => (
                  <SelectItem key={o.id} value={o.id}>{o.name}</SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>
        )}
        <div className="flex gap-2 justify-end pt-2">
          <Button variant="outline" onClick={() => onOpenChange(false)}>{"取消"}</Button>
          <Button
            variant="destructive"
            onClick={handleDelete}
            disabled={loading || (item.usageCount > 0 && !replacementId)}
          >
            {loading ? "削除中…" : item.usageCount > 0 ? "割り当てを変更して削除" : "削除"}
          </Button>
        </div>
      </DialogContent>
    </Dialog>
  );
}
