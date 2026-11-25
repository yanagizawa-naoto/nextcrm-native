"use client";
import { useRouter, usePathname, useSearchParams } from "next/navigation";
import { Input } from "@/components/ui/input";
import { Button } from "@/components/ui/button";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";

interface AdminFiltersProps {
  entityType?: string;
  action?: string;
  dateFrom?: string;
  dateTo?: string;
}

export function AdminFilters({
  entityType,
  action,
  dateFrom,
  dateTo,
}: AdminFiltersProps) {
  const router = useRouter();
  const pathname = usePathname();
  const searchParams = useSearchParams();

  const apply = (overrides: Record<string, string>) => {
    // Start from current URL params so we don't drop unknown params
    const params = new URLSearchParams(searchParams.toString());
    params.set("page", "1"); // reset page on filter change
    Object.entries(overrides).forEach(([k, v]) => {
      if (v) params.set(k, v);
      else params.delete(k);
    });
    router.push(`${pathname}?${params.toString()}`);
  };

  const clear = () => router.push(pathname);

  return (
    <div className="flex flex-wrap gap-3 items-end">
      <Select
        value={entityType ?? "all"}
        onValueChange={(v) => apply({ entityType: v === "all" ? "" : v })}
      >
        <SelectTrigger className="w-40">
          <SelectValue placeholder="データの種別" />
        </SelectTrigger>
        <SelectContent>
          <SelectItem value="all">{"すべての種別"}</SelectItem>
          <SelectItem value="account">{"取引先"}</SelectItem>
          <SelectItem value="contact">{"連絡先"}</SelectItem>
          <SelectItem value="lead">{"見込み客"}</SelectItem>
          <SelectItem value="opportunity">{"商談"}</SelectItem>
          <SelectItem value="contract">{"契約書"}</SelectItem>
        </SelectContent>
      </Select>

      <Select
        value={action ?? "all"}
        onValueChange={(v) => apply({ action: v === "all" ? "" : v })}
      >
        <SelectTrigger className="w-40">
          <SelectValue placeholder="操作" />
        </SelectTrigger>
        <SelectContent>
          <SelectItem value="all">{"すべての操作"}</SelectItem>
          <SelectItem value="created">{"作成"}</SelectItem>
          <SelectItem value="updated">{"更新日"}</SelectItem>
          <SelectItem value="deleted">{"削除"}</SelectItem>
          <SelectItem value="restored">{"復元"}</SelectItem>
          <SelectItem value="relation_added">{"関連を追加"}</SelectItem>
          <SelectItem value="relation_removed">{"関連を解除"}</SelectItem>
        </SelectContent>
      </Select>

      <div className="flex items-center gap-2">
        <Input
          type="date"
          className="w-36"
          value={dateFrom ?? ""}
          onChange={(e) => apply({ dateFrom: e.target.value })}
          placeholder="開始日"
        />
        <span className="text-muted-foreground text-sm">{"〜"}</span>
        <Input
          type="date"
          className="w-36"
          value={dateTo ?? ""}
          onChange={(e) => apply({ dateTo: e.target.value })}
          placeholder="終了日"
        />
      </div>

      {(entityType || action || dateFrom || dateTo) && (
        <Button variant="ghost" size="sm" onClick={clear}>
          {"絞り込みを解除"}</Button>
      )}
    </div>
  );
}
