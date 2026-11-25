"use client";

import { ColumnDef } from "@tanstack/react-table";
import { Badge } from "@/components/ui/badge";
import { Checkbox } from "@/components/ui/checkbox";
import { DocumentRow } from "../data/schema";
import { DataTableColumnHeader } from "./data-table-column-header";
import { DataTableRowActions } from "./data-table-row-actions";
import { ProcessingStatusBadge } from "./processing-status-badge";
import moment from "moment";

const MIME_LABELS: Record<string, { label: string; className: string }> = {
  "application/pdf": { label: "PDF", className: "bg-blue-100 text-blue-800 dark:bg-blue-900 dark:text-blue-200" },
  "image/": { label: "IMG", className: "bg-purple-100 text-purple-800 dark:bg-purple-900 dark:text-purple-200" },
  "application/vnd.openxmlformats": { label: "DOCX", className: "bg-indigo-100 text-indigo-800 dark:bg-indigo-900 dark:text-indigo-200" },
  "application/msword": { label: "DOC", className: "bg-indigo-100 text-indigo-800 dark:bg-indigo-900 dark:text-indigo-200" },
  "text/plain": { label: "TXT", className: "bg-gray-100 text-gray-800 dark:bg-gray-900 dark:text-gray-200" },
};

function getMimeLabel(mimeType: string) {
  for (const [key, value] of Object.entries(MIME_LABELS)) {
    if (mimeType.startsWith(key)) return value;
  }
  return { label: "ファイル", className: "bg-gray-100 text-gray-800 dark:bg-gray-900 dark:text-gray-200" };
}

const TYPE_LABELS: Record<string, string> = { RECEIPT: "請求・領収書", CONTRACT: "契約書", OFFER: "見積・提案書", OTHER: "その他" };

const TYPE_COLORS: Record<string, string> = {
  RECEIPT: "bg-yellow-100 text-yellow-800 dark:bg-yellow-900 dark:text-yellow-200",
  CONTRACT: "bg-green-100 text-green-800 dark:bg-green-900 dark:text-green-200",
  OFFER: "bg-blue-100 text-blue-800 dark:bg-blue-900 dark:text-blue-200",
  OTHER: "bg-gray-100 text-gray-800 dark:bg-gray-900 dark:text-gray-200",
};

export const columns: ColumnDef<DocumentRow>[] = [
  {
    id: "select",
    header: ({ table }) => (
      <Checkbox
        checked={table.getIsAllPageRowsSelected()}
        onCheckedChange={(value) => table.toggleAllPageRowsSelected(!!value)}
        aria-label="すべて選択"
      />
    ),
    cell: ({ row }) => (
      <Checkbox
        checked={row.getIsSelected()}
        onCheckedChange={(value) => row.toggleSelected(!!value)}
        aria-label="この行を選択"
      />
    ),
    enableSorting: false,
    enableHiding: false,
  },
  {
    accessorKey: "createdAt",
    header: ({ column }) => (
      <DataTableColumnHeader column={column} title="日付" />
    ),
    cell: ({ row }) => (
      <div className="w-[80px] text-muted-foreground text-sm">
        {moment(row.getValue("createdAt")).format("YY-MM-DD")}
      </div>
    ),
    enableSorting: true,
  },
  {
    accessorKey: "document_name",
    header: ({ column }) => (
      <DataTableColumnHeader column={column} title="文書" />
    ),
    cell: ({ row }) => {
      const mimeLabel = getMimeLabel(row.original.document_file_mimeType);
      const summary = row.original.summary;
      const isProcessing = row.original.processing_status === "PROCESSING" || row.original.processing_status === "PENDING";
      return (
        <div className="flex items-start gap-3">
          <Badge variant="outline" className={`text-xs shrink-0 ${mimeLabel.className}`}>
            {mimeLabel.label}
          </Badge>
          <div className="min-w-0">
            <span className="font-medium truncate block">
              {row.getValue("document_name")}
            </span>
            {isProcessing ? (
              <span className="text-xs text-muted-foreground italic">
                {"要約を作成しています…"}</span>
            ) : summary ? (
              <span className="text-xs text-muted-foreground line-clamp-1">
                {summary}
              </span>
            ) : null}
          </div>
        </div>
      );
    },
  },
  {
    accessorKey: "document_system_type",
    header: ({ column }) => (
      <DataTableColumnHeader column={column} title="種別" />
    ),
    cell: ({ row }) => {
      const type = row.getValue("document_system_type") as string | null;
      if (!type) return <span className="text-muted-foreground">—</span>;
      return (
        <Badge variant="outline" className={`text-xs ${TYPE_COLORS[type] ?? ""}`}>
          {TYPE_LABELS[type] ?? type}
        </Badge>
      );
    },
    filterFn: (row, id, value) => value.includes(row.getValue(id)),
  },
  {
    id: "account",
    header: ({ column }) => (
      <DataTableColumnHeader column={column} title="取引先" />
    ),
    cell: ({ row }) => {
      const accounts = row.original.accounts;
      const accountName = accounts?.[0]?.account?.name;
      return accountName ? (
        <span className="text-sm text-primary">{accountName}</span>
      ) : (
        <span className="text-muted-foreground">—</span>
      );
    },
  },
  {
    accessorKey: "processing_status",
    header: ({ column }) => (
      <DataTableColumnHeader column={column} title="状態" />
    ),
    cell: ({ row }) => (
      <ProcessingStatusBadge status={row.getValue("processing_status")} />
    ),
    filterFn: (row, id, value) => value.includes(row.getValue(id)),
  },
  {
    accessorKey: "assigned_to_user",
    header: ({ column }) => (
      <DataTableColumnHeader column={column} title="担当者" />
    ),
    cell: ({ row }) => (
      <div className="w-[120px] text-sm">
        {(row.getValue("assigned_to_user") as { name: string | null } | null)?.name ?? "未割り当て"}
      </div>
    ),
    enableSorting: false,
  },
  {
    id: "actions",
    cell: ({ row }) => <DataTableRowActions row={row} />,
  },
];
