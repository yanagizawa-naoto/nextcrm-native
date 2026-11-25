"use client";

import Link from "next/link";
import { ColumnDef } from "@tanstack/react-table";

import { Badge } from "@/components/ui/badge";
import { Checkbox } from "@/components/ui/checkbox";

import { Opportunity } from "../table-data/schema";
import { DataTableColumnHeader } from "./data-table-column-header";
import { DataTableRowActions } from "./data-table-row-actions";
import moment from "moment";

type ConfigItem = { id: string; name: string };

export const createColumns = (contactTypes: ConfigItem[] = []): ColumnDef<Opportunity>[] => [
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
        onClick={(e) => e.stopPropagation()}
      />
    ),
    enableSorting: false,
    enableHiding: false,
  },
  {
    accessorKey: "created_on",
    header: ({ column }) => (
      <DataTableColumnHeader column={column} title="作成日" />
    ),
    cell: ({ row }) => (
      <div className="w-[80px]">
        {moment(row.getValue("created_on")).format("YY-MM-DD")}
      </div>
    ),
    enableSorting: false,
    enableHiding: false,
  },
  {
    accessorKey: "assigned_to_user",
    header: ({ column }) => (
      <DataTableColumnHeader column={column} title="担当者" />
    ),
    cell: ({ row }) => (
      <div className="w-[150px]">
        {(row.getValue("assigned_to_user") as { name?: string } | null)?.name ??
          "未割り当て"}
      </div>
    ),
    enableSorting: true,
    enableHiding: true,
  },
  {
    accessorKey: "assigned_account",
    header: ({ column }) => (
      <DataTableColumnHeader column={column} title="取引先" />
    ),
    cell: ({ row }) => (
      <div className="min-w-[150px]">
        {(row.original as any).assigned_accounts?.name ?? "未割り当て"}
      </div>
    ),
    enableSorting: false,
    enableHiding: true,
  },
  {
    accessorKey: "last_name",
    header: ({ column }) => (
      <DataTableColumnHeader column={column} title="姓" />
    ),
    cell: ({ row }) => (
      <Link href={`/crm/contacts/${row.original.id}`} data-testid="contact-row-name">
        <div className="">{row.getValue("last_name")}</div>
      </Link>
    ),
    enableSorting: true,
    enableHiding: true,
  },
  {
    accessorKey: "first_name",
    header: ({ column }) => (
      <DataTableColumnHeader column={column} title="名" />
    ),
    cell: ({ row }) => <div className="">{row.getValue("first_name")}</div>,
    enableSorting: true,
    enableHiding: true,
  },
  {
    accessorKey: "email",
    header: ({ column }) => (
      <DataTableColumnHeader column={column} title="メールアドレス" />
    ),
    cell: ({ row }) => <div className="">{row.getValue("email")}</div>,
    enableSorting: true,
    enableHiding: true,
  },
  {
    accessorKey: "mobile_phone",
    header: ({ column }) => (
      <DataTableColumnHeader column={column} title="携帯電話" />
    ),
    cell: ({ row }) => <div className="">{row.getValue("mobile_phone")}</div>,
    enableSorting: true,
    enableHiding: true,
  },
  {
    accessorKey: "status",
    header: ({ column }) => (
      <DataTableColumnHeader column={column} title="状態" />
    ),
    cell: ({ row }) => (
      <div className="">{row.original.status ? "有効" : "無効"}</div>
    ),
    enableSorting: true,
    enableHiding: true,
  },
  {
    id: "actions",
    cell: ({ row }) => (
      <DataTableRowActions row={row} contactTypes={contactTypes} />
    ),
  },
];
