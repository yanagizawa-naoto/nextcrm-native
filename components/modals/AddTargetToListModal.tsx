"use client";

import { useEffect, useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { toast } from "sonner";
import { getTargets } from "@/actions/crm/get-targets";
import { addTargetsToList } from "@/actions/crm/target-lists/add-targets-to-list";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Checkbox } from "@/components/ui/checkbox";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { ScrollArea } from "@/components/ui/scroll-area";

interface Target {
  id: string;
  first_name: string | null;
  last_name: string;
  email: string | null;
  company: string | null;
}

interface AddTargetToListModalProps {
  targetListId: string;
  existingTargetIds: string[];
  open: boolean;
  onOpenChange: (open: boolean) => void;
}

const AddTargetToListModal = ({
  targetListId,
  existingTargetIds,
  open,
  onOpenChange,
}: AddTargetToListModalProps) => {
  const router = useRouter();
  const [allTargets, setAllTargets] = useState<Target[]>([]);
  const [search, setSearch] = useState("");
  const [selected, setSelected] = useState<string[]>([]);
  const [isLoading, setIsLoading] = useState(false);
  const [isFetching, startFetching] = useTransition();

  useEffect(() => {
    if (!open) return;
    startFetching(async () => {
      try {
        setAllTargets(await getTargets());
      } catch {
        toast.error("営業対象を読み込めませんでした");
      }
    });
  }, [open]);

  const targets = allTargets.filter((t) => !existingTargetIds.includes(t.id));

  const filtered = targets.filter((t) => {
    const q = search.toLowerCase();
    return (
      t.first_name?.toLowerCase().includes(q) ||
      t.last_name?.toLowerCase().includes(q) ||
      t.email?.toLowerCase().includes(q) ||
      t.company?.toLowerCase().includes(q)
    );
  });

  const toggle = (id: string) => {
    setSelected((prev) =>
      prev.includes(id) ? prev.filter((x) => x !== id) : [...prev, id]
    );
  };

  const allFilteredSelected =
    filtered.length > 0 && filtered.every((t) => selected.includes(t.id));
  const someFilteredSelected = filtered.some((t) => selected.includes(t.id));

  const toggleAll = () => {
    if (allFilteredSelected) {
      setSelected((prev) => prev.filter((id) => !filtered.some((t) => t.id === id)));
    } else {
      const newIds = filtered.map((t) => t.id);
      setSelected((prev) => Array.from(new Set([...prev, ...newIds])));
    }
  };

  const handleSubmit = async () => {
    if (selected.length === 0) return;
    setIsLoading(true);
    const result = await addTargetsToList(targetListId, selected);
    setIsLoading(false);
    if (result.error) {
      toast.error(result.error);
      return;
    }
    toast.success(`Added ${selected.length} target(s) to the list`);
    setSelected([]);
    setSearch("");
    onOpenChange(false);
    router.refresh();
  };

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="sm:max-w-lg">
        <DialogHeader>
          <DialogTitle>{"リストに営業対象を追加"}</DialogTitle>
          <DialogDescription>
            {"リストに追加する営業対象を選択してください。登録済みの対象は表示されません。"}</DialogDescription>
        </DialogHeader>
        <div className="space-y-3">
          <Input
            placeholder="氏名・メールアドレス・会社名で検索…"
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            disabled={isFetching}
          />
          {!isFetching && filtered.length > 0 && (
            <div
              className="flex items-center space-x-3 rounded-md px-2 py-1.5 hover:bg-accent cursor-pointer"
              onClick={toggleAll}
            >
              <Checkbox
                checked={allFilteredSelected ? true : someFilteredSelected ? "indeterminate" : false}
                onCheckedChange={toggleAll}
              />
              <span className="text-sm font-medium">{"すべて選択（"}{filtered.length})</span>
            </div>
          )}
          <ScrollArea className="h-72 rounded-md border p-2">
            {isFetching ? (
              <p className="text-sm text-muted-foreground p-2">{"営業対象を読み込んでいます…"}</p>
            ) : filtered.length === 0 ? (
              <p className="text-sm text-muted-foreground p-2">{"追加できる営業対象はありません。"}</p>
            ) : (
              <div className="space-y-1">
                {filtered.map((t) => (
                  <div
                    key={t.id}
                    className="flex items-center space-x-3 rounded-md px-2 py-1.5 hover:bg-accent cursor-pointer"
                    onClick={() => toggle(t.id)}
                  >
                    <Checkbox
                      checked={selected.includes(t.id)}
                      onCheckedChange={() => toggle(t.id)}
                    />
                    <div className="flex-1 min-w-0">
                      <p className="text-sm font-medium truncate">
                        {t.last_name} {t.first_name}
                      </p>
                      <p className="text-xs text-muted-foreground truncate">
                        {t.email || t.company || "連絡先情報がありません"}
                      </p>
                    </div>
                    {t.company && (
                      <span className="text-xs text-muted-foreground shrink-0">{t.company}</span>
                    )}
                  </div>
                ))}
              </div>
            )}
          </ScrollArea>
          {selected.length > 0 && (
            <p className="text-xs text-muted-foreground">{selected.length} {"件の営業対象を選択"}</p>
          )}
        </div>
        <DialogFooter>
          <Button
            variant="outline"
            onClick={() => onOpenChange(false)}
            disabled={isLoading}
          >
            {"取消"}</Button>
          <Button
            onClick={handleSubmit}
            disabled={isLoading || selected.length === 0}
          >
            {isLoading ? "追加中…" : `Add Selected (${selected.length})`}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
};

export default AddTargetToListModal;
