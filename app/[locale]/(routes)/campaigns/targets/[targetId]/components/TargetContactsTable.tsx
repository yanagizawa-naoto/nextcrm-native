"use client";

import { useState } from "react";
import { toast } from "sonner";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import {
  Table, TableBody, TableCell, TableHead, TableHeader, TableRow,
} from "@/components/ui/table";
import {
  Dialog, DialogContent, DialogHeader, DialogTitle, DialogTrigger,
} from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";

interface TargetContact {
  id: string;
  name: string | null;
  email: string | null;
  title: string | null;
  phone: string | null;
  linkedinUrl: string | null;
  source: string;
  enrichStatus: string;
}

interface Props {
  targetId: string;
  contacts: TargetContact[];
}

const STATUS_BADGE: Record<string, { label: string; variant: "default" | "secondary" | "destructive" | "outline" }> = {
  COMPLETED: { label: "取得した情報", variant: "default" },
  RUNNING:   { label: "実行中", variant: "secondary" },
  PENDING:   { label: "保留中", variant: "outline" },
  FAILED:    { label: "失敗", variant: "destructive" },
  SKIPPED:   { label: "スキップ", variant: "outline" },
};

export function TargetContactsTable({ targetId, contacts: initialContacts }: Props) {
  const [contacts, setContacts] = useState(initialContacts);
  const [open, setOpen] = useState(false);
  const [form, setForm] = useState({ name: "", email: "", phone: "", linkedinUrl: "" });
  const [saving, setSaving] = useState(false);

  async function handleAddContact(e: React.FormEvent) {
    e.preventDefault();
    setSaving(true);
    try {
      const res = await fetch(`/api/crm/targets/${targetId}/contacts`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(form),
      });
      if (!res.ok) throw new Error(await res.text());
      const created: TargetContact = await res.json();
      setContacts((prev) => [...prev, created]);
      setOpen(false);
      setForm({ name: "", email: "", phone: "", linkedinUrl: "" });
      toast.success("連絡先を追加しました");
    } catch (err) {
      toast.error(err instanceof Error ? err.message : "連絡先を追加できませんでした");
    } finally {
      setSaving(false);
    }
  }

  async function handleEnrichContact(contactId: string) {
    try {
      const res = await fetch(`/api/crm/targets/${targetId}/contacts/${contactId}/enrich`, {
        method: "POST",
      });
      if (!res.ok) throw new Error(await res.text());
      setContacts((prev) =>
        prev.map((c) => c.id === contactId ? { ...c, enrichStatus: "RUNNING" } : c)
      );
      toast.success("情報補完を開始しました。完了時に通知します");
    } catch {
      toast.error("情報補完を開始できませんでした");
    }
  }

  return (
    <div className="space-y-3">
      <div className="flex items-center justify-between">
        <h3 className="text-sm font-medium">{"連絡先"}</h3>
        <Dialog open={open} onOpenChange={setOpen}>
          <DialogTrigger asChild>
            <Button variant="outline" size="sm">{"連絡先を追加"}</Button>
          </DialogTrigger>
          <DialogContent>
            <DialogHeader>
              <DialogTitle>{"連絡先を追加"}</DialogTitle>
            </DialogHeader>
            <form onSubmit={handleAddContact} className="space-y-4">
              <div className="space-y-1">
                <Label htmlFor="name">{"名称"}</Label>
                <Input
                  id="name"
                  value={form.name}
                  onChange={(e) => setForm((f) => ({ ...f, name: e.target.value }))}
                  placeholder="山田 花子"
                />
              </div>
              <div className="space-y-1">
                <Label htmlFor="email">{"メールアドレス"}</Label>
                <Input
                  id="email"
                  type="email"
                  value={form.email}
                  onChange={(e) => setForm((f) => ({ ...f, email: e.target.value }))}
                  placeholder="jane@acme.com"
                />
              </div>
              <div className="space-y-1">
                <Label htmlFor="phone">{"電話番号"}</Label>
                <Input
                  id="phone"
                  value={form.phone}
                  onChange={(e) => setForm((f) => ({ ...f, phone: e.target.value }))}
                  placeholder="+1 415 000 0000"
                />
              </div>
              <div className="space-y-1">
                <Label htmlFor="linkedinUrl">{"LinkedInのURL"}</Label>
                <Input
                  id="linkedinUrl"
                  value={form.linkedinUrl}
                  onChange={(e) => setForm((f) => ({ ...f, linkedinUrl: e.target.value }))}
                  placeholder="https://linkedin.com/in/..."
                />
              </div>
              <Button type="submit" disabled={saving} className="w-full">
                {saving ? "追加中…" : "連絡先を追加"}
              </Button>
            </form>
          </DialogContent>
        </Dialog>
      </div>

      {contacts.length === 0 ? (
        <p className="text-sm text-muted-foreground">
          {"連絡先はまだありません。AIによる情報補完か手動で追加してください。"}</p>
      ) : (
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>{"名称"}</TableHead>
              <TableHead>{"契約名"}</TableHead>
              <TableHead>{"メールアドレス"}</TableHead>
              <TableHead>{"電話番号"}</TableHead>
              <TableHead>LinkedIn</TableHead>
              <TableHead>{"状態"}</TableHead>
              <TableHead></TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {contacts.map((contact) => {
              const badge = STATUS_BADGE[contact.enrichStatus] ?? STATUS_BADGE.PENDING;
              return (
                <TableRow key={contact.id}>
                  <TableCell className="font-medium">{contact.name ?? "—"}</TableCell>
                  <TableCell>{contact.title ?? "—"}</TableCell>
                  <TableCell>{contact.email ?? "—"}</TableCell>
                  <TableCell>{contact.phone ?? "—"}</TableCell>
                  <TableCell>
                    {contact.linkedinUrl ? (
                      <a
                        href={contact.linkedinUrl}
                        target="_blank"
                        rel="noopener noreferrer"
                        className="text-sm text-blue-600 hover:underline"
                      >
                        {"表示"}</a>
                    ) : "—"}
                  </TableCell>
                  <TableCell>
                    <Badge variant={badge.variant}>{badge.label}</Badge>
                  </TableCell>
                  <TableCell>
                    {(contact.enrichStatus === "PENDING" || contact.enrichStatus === "FAILED") && (
                      <Button
                        variant="ghost"
                        size="sm"
                        onClick={() => handleEnrichContact(contact.id)}
                      >
                        {"情報を補完"}</Button>
                    )}
                  </TableCell>
                </TableRow>
              );
            })}
          </TableBody>
        </Table>
      )}
    </div>
  );
}
