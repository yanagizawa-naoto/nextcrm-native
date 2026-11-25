"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Switch } from "@/components/ui/switch";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogTrigger,
} from "@/components/ui/dialog";
import { Pencil, Trash2 } from "lucide-react";

interface TaxRate {
  id: string;
  name: string;
  rate: string;
  isDefault: boolean;
  active: boolean;
}

interface TaxRatesTableProps {
  rates: TaxRate[];
}

export function TaxRatesTable({ rates }: TaxRatesTableProps) {
  const router = useRouter();
  const [open, setOpen] = useState(false);
  const [editId, setEditId] = useState<string | null>(null);
  const [name, setName] = useState("");
  const [rate, setRate] = useState("");
  const [isDefault, setIsDefault] = useState(false);
  const [active, setActive] = useState(true);

  const resetForm = () => {
    setEditId(null);
    setName("");
    setRate("");
    setIsDefault(false);
    setActive(true);
  };

  const openEdit = (r: TaxRate) => {
    setEditId(r.id);
    setName(r.name);
    setRate(r.rate);
    setIsDefault(r.isDefault);
    setActive(r.active);
    setOpen(true);
  };

  const handleSave = async () => {
    const body = { name, rate: parseFloat(rate), isDefault, active };
    try {
      const url = editId
        ? `/api/admin/invoices/tax-rates/${editId}`
        : "/api/admin/invoices/tax-rates";
      const method = editId ? "PATCH" : "POST";
      const res = await fetch(url, {
        method,
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body),
      });
      if (!res.ok) throw new Error(await res.text());
      toast.success(editId ? "税率を更新しました" : "税率を作成しました");
      setOpen(false);
      resetForm();
      router.refresh();
    } catch {
      toast.error("税率を保存できませんでした");
    }
  };

  const handleDelete = async (id: string) => {
    if (!confirm("この税率を削除しますか？")) return;
    try {
      const res = await fetch(`/api/admin/invoices/tax-rates/${id}`, {
        method: "DELETE",
      });
      if (!res.ok) throw new Error(await res.text());
      toast.success("税率を削除しました");
      router.refresh();
    } catch {
      toast.error("税率を削除できませんでした");
    }
  };

  return (
    <div>
      <Table>
        <TableHeader>
          <TableRow>
            <TableHead>{"名称"}</TableHead>
            <TableHead>{"税率（%）"}</TableHead>
            <TableHead>{"既定"}</TableHead>
            <TableHead>{"有効"}</TableHead>
            <TableHead className="w-20">{"操作"}</TableHead>
          </TableRow>
        </TableHeader>
        <TableBody>
          {rates.map((r) => (
            <TableRow key={r.id} className={!r.active ? "opacity-50" : ""}>
              <TableCell className="font-medium">{r.name}</TableCell>
              <TableCell>{r.rate}%</TableCell>
              <TableCell>{r.isDefault ? "はい" : "いいえ"}</TableCell>
              <TableCell>{r.active ? "有効" : "無効"}</TableCell>
              <TableCell>
                <div className="flex gap-1">
                  <Button
                    variant="ghost"
                    size="icon"
                    onClick={() => openEdit(r)}
                  >
                    <Pencil className="h-4 w-4" />
                  </Button>
                  <Button
                    variant="ghost"
                    size="icon"
                    onClick={() => handleDelete(r.id)}
                    disabled={r.isDefault}
                  >
                    <Trash2 className="h-4 w-4" />
                  </Button>
                </div>
              </TableCell>
            </TableRow>
          ))}
          {rates.length === 0 && (
            <TableRow>
              <TableCell colSpan={5} className="text-center text-muted-foreground">
                {"税率が設定されていません"}</TableCell>
            </TableRow>
          )}
        </TableBody>
      </Table>

      <Dialog
        open={open}
        onOpenChange={(v) => {
          setOpen(v);
          if (!v) resetForm();
        }}
      >
        <DialogTrigger asChild>
          <Button variant="outline" size="sm" className="mt-4">
            {"＋ 税率を追加"}</Button>
        </DialogTrigger>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>
              {editId ? "税率を編集" : "税率を追加"}
            </DialogTitle>
          </DialogHeader>
          <div className="space-y-4">
            <div className="space-y-2">
              <Label>{"名称"}</Label>
              <Input
                placeholder="例：標準税率"
                value={name}
                onChange={(e) => setName(e.target.value)}
              />
            </div>
            <div className="space-y-2">
              <Label>{"税率（%）"}</Label>
              <Input
                type="number"
                step="0.01"
                placeholder="e.g. 21"
                value={rate}
                onChange={(e) => setRate(e.target.value)}
              />
            </div>
            <div className="flex items-center gap-2">
              <Switch checked={isDefault} onCheckedChange={setIsDefault} />
              <Label>{"既定"}</Label>
            </div>
            <div className="flex items-center gap-2">
              <Switch checked={active} onCheckedChange={setActive} />
              <Label>{"有効"}</Label>
            </div>
            <Button
              onClick={handleSave}
              disabled={!name || !rate}
            >
              {editId ? "更新" : "作成"}
            </Button>
          </div>
        </DialogContent>
      </Dialog>
    </div>
  );
}
