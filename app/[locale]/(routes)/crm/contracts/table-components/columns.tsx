"use client";

import { ColumnDef } from "@tanstack/react-table";

import { Badge } from "@/components/ui/badge";
import { Checkbox } from "@/components/ui/checkbox";

import { statuses } from "../table-data/data";
import { Lead } from "../table-data/schema";
import { DataTableColumnHeader } from "./data-table-column-header";
import { DataTableRowActions } from "./data-table-row-actions";
import moment from "moment";

export const columns: ColumnDef<Lead>[] = [
  {
    accessorKey: "createdAt",
    header: ({ column }) => (
      <DataTableColumnHeader column={column} title="作成" />
    ),
    cell: ({ row }) => (
      <div className="w-[80px]">
        {row.getValue("createdAt")
          ? moment(row.getValue("createdAt")).format("YY-MM-DD")
          : "—"}
      </div>
    ),
    enableSorting: false,
    enableHiding: false,
  },
  {
    accessorKey: "updatedAt",
    header: ({ column }) => (
      <DataTableColumnHeader column={column} title="最終更新日" />
    ),
    cell: ({ row }) => (
      <div className="w-[80px]">
        {row.getValue("updatedAt")
          ? moment(row.getValue("updatedAt")).format("YY-MM-DD")
          : "—"}
      </div>
    ),
    enableSorting: false,
    enableHiding: false,
  },
  {
    accessorKey: "customerSignedDate",
    header: ({ column }) => (
      <DataTableColumnHeader column={column} title="顧客署名済み" />
    ),
    cell: ({ row }) => (
      <div className="w-[150px]">
        {row.getValue("customerSignedDate")
          ? moment(row.getValue("customerSignedDate")).format("YY-MM-DD")
          : "未署名"}
      </div>
    ),
    enableSorting: false,
    enableHiding: false,
  },
  {
    accessorKey: "title",
    header: ({ column }) => (
      <DataTableColumnHeader column={column} title="契約名" />
    ),

    cell: ({ row }) => <div className="w-[150px]">{row.getValue("title")}</div>,
    enableSorting: true,
    enableHiding: true,
  },
  {
    accessorKey: "assigned_to_user",
    header: ({ column }) => (
      <DataTableColumnHeader column={column} title="担当者" />
    ),

    cell: ({ row }) => (
      <div className="w-[150px]">
        {row.original.assigned_to_user
          ? row.original.assigned_to_user.name
          : "未割り当て"}
      </div>
    ),
    enableSorting: true,
    enableHiding: true,
  },
  {
    accessorKey: "company",
    header: ({ column }) => (
      <DataTableColumnHeader column={column} title="会社名" />
    ),

    cell: ({ row }) => (
      <div className="">
        {row.original.assigned_account
          ? row.original.assigned_account.name
          : "未割り当て"}
      </div>
    ),
    enableSorting: false,
    enableHiding: true,
  },
  {
    accessorKey: "status",
    header: ({ column }) => (
      <DataTableColumnHeader column={column} title="状態" />
    ),
    cell: ({ row }) => {
      const status = statuses.find(
        (status) => status.value === row.getValue("status")
      );
      if (!status) {
        return null;
      }
      return (
        <div className="flex w-[100px] items-center">
          {status.icon && (
            <status.icon className="mr-2 h-4 w-4 text-muted-foreground" />
          )}
          <span>{status.label}</span>
        </div>
      );
    },
    filterFn: (row, id, value) => {
      return value.includes(row.getValue(id));
    },
  },
  {
    id: "actions",
    cell: ({ row }) => <DataTableRowActions row={row} />,
  },
];
