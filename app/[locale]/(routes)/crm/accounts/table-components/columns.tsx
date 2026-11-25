"use client";

import { ColumnDef } from "@tanstack/react-table";

import { statuses } from "../table-data/data";
import { Account } from "../table-data/schema";
import { DataTableColumnHeader } from "./data-table-column-header";
import { DataTableRowActions } from "./data-table-row-actions";
import moment from "moment";
import Link from "next/link";

export const columns: ColumnDef<Account>[] = [
  {
    accessorKey: "createdAt",
    header: ({ column }) => (
      <DataTableColumnHeader column={column} title="作成" />
    ),
    cell: ({ row }) => (
      <div className="">
        {moment(row.getValue("createdAt")).format("YY/MM/DD-HH:mm")}
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
    accessorKey: "name",
    header: ({ column }) => (
      <DataTableColumnHeader column={column} title="名称" />
    ),

    cell: ({ row }) => (
      <Link href={`/crm/accounts/${row.original?.id}`} data-testid="account-row-name">
        <div className="w-[250px]">{row.original.name}</div>
      </Link>
    ),
    enableSorting: false,
    enableHiding: true,
  },
  {
    accessorKey: "email",
    header: ({ column }) => (
      <DataTableColumnHeader column={column} title="メールアドレス" />
    ),

    cell: ({ row }) => <div className="w-[150px]">{row.getValue("email")}</div>,
    enableSorting: true,
    enableHiding: true,
  },
  {
    accessorKey: "contacts",
    header: ({ column }) => (
      <DataTableColumnHeader column={column} title="取引先の連絡先" />
    ),

    cell: ({ row }) => (
      <div className="w-[150px]">
        {row.original.contacts?.map(
          (contact: any) => [contact.last_name, contact.first_name].filter(Boolean).join(" ")
        )}
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
