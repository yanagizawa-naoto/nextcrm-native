"use client";

import { ColumnDef } from "@tanstack/react-table";

import { TargetList } from "../table-data/schema";
import { DataTableColumnHeader } from "./data-table-column-header";
import { DataTableRowActions } from "./data-table-row-actions";
import moment from "moment";

export const columns: ColumnDef<TargetList>[] = [
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
    accessorKey: "name",
    header: ({ column }) => (
      <DataTableColumnHeader column={column} title="名称" />
    ),
    cell: ({ row }) => <div className="font-medium">{row.getValue("name")}</div>,
    enableSorting: true,
    enableHiding: true,
  },
  {
    accessorKey: "description",
    header: ({ column }) => (
      <DataTableColumnHeader column={column} title="品名・内容" />
    ),
    cell: ({ row }) => (
      <div className="max-w-[300px] truncate">{row.getValue("description")}</div>
    ),
    enableSorting: true,
    enableHiding: true,
  },
  {
    accessorKey: "_count",
    header: ({ column }) => (
      <DataTableColumnHeader column={column} title="営業対象" />
    ),
    cell: ({ row }) => (
      <div className="">
        {(row.getValue("_count") as any)?.targets ?? 0}
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
    cell: ({ row }) => (
      <div className="">{row.original.status ? "有効" : "無効"}</div>
    ),
    enableSorting: true,
    enableHiding: true,
  },
  {
    id: "actions",
    cell: ({ row }) => <DataTableRowActions row={row} />,
  },
];
