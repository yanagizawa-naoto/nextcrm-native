"use client";

import { ColumnDef } from "@tanstack/react-table";

import { Badge } from "@/components/ui/badge";

import { visibility } from "../data/data";
import { Task } from "../data/schema";
import { DataTableColumnHeader } from "./data-table-column-header";
import { DataTableRowActions } from "./data-table-row-actions";
import moment from "moment";
import Link from "next/link";

export const columns: ColumnDef<Task>[] = [
  {
    accessorKey: "date_created",
    header: ({ column }) => (
      <DataTableColumnHeader column={column} title="作成日" />
    ),
    cell: ({ row }) => (
      <div className="w-[80px]">
        {moment(row.getValue("date_created")).format("YY-MM-DD")}
      </div>
    ),
    enableSorting: true,
    enableHiding: false,
  },
  {
    accessorKey: "assigned_user",
    header: ({ column }) => (
      <DataTableColumnHeader column={column} title="担当者" />
    ),

    cell: ({ row }) => (
      <div className="w-[150px]">
        {row.original.assigned_user.name ?? "未割り当て"}
      </div>
    ),
    enableSorting: true,
    enableHiding: true,
  },

  {
    accessorKey: "title",
    header: ({ column }) => (
      <DataTableColumnHeader column={column} title="名称" />
    ),
    cell: ({ row }) => (
      <Link href={`/projects/boards/${row.original.id}`}>
        <div className="w-[300px]">{row.getValue("title")}</div>
      </Link>
    ),
  },
  {
    accessorKey: "description",
    header: ({ column }) => (
      <DataTableColumnHeader column={column} title="品名・内容" />
    ),
    cell: ({ row }) => (
      <div className="w-[300px]">{row.getValue("description")}</div>
    ),
  },
  {
    accessorKey: "visibility",
    header: ({ column }) => (
      <DataTableColumnHeader column={column} title="公開範囲" />
    ),
    cell: ({ row }) => {
      const status = visibility.find(
        (status) => status.value === row.getValue("visibility")
      );

      if (!status) {
        return null;
      }

      return (
        <div className="flex w-[100px] items-center">
          {status.label && <Badge variant="outline">{status.label}</Badge>}
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
