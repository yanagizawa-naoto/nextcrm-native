"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { cn } from "@/lib/utils";
import { Key, Users, Settings, SlidersHorizontal, ClipboardList, Coins, FileText, CalendarClock, Puzzle, Tags, ShoppingCart } from "lucide-react";

const navItems = [
  { label: "AIのAPIキー",     href: "/admin/llm-keys",     icon: Key },
  { label: "ユーザー管理",        href: "/admin/users",        icon: Users },
  { label: "外部サービス",     href: "/admin/services",     icon: Settings },
  { label: "営業管理の設定", href: "/admin/crm-settings", icon: SlidersHorizontal },
  { label: "営業フローの設定", href: "/admin/funnel-settings", icon: SlidersHorizontal },
  { label: "カレンダー設定", href: "/admin/calendar-settings", icon: CalendarClock },
  { label: "変更履歴",    href: "/admin/audit-log",    icon: ClipboardList },
  { label: "通貨",   href: "/admin/currencies",   icon: Coins },
  { label: "価格設定",      href: "/admin/pricing",      icon: Tags },
  { label: "受注設定",       href: "/admin/orders",       icon: ShoppingCart },
  { label: "請求書",     href: "/admin/invoices",     icon: FileText },
  { label: "拡張機能",      href: "/admin/plugins",      icon: Puzzle },
];

export function AdminSidebarNav() {
  const pathname = usePathname();

  return (
    <nav className="flex flex-col gap-1">
      <p className="px-3 py-2 text-xs font-semibold text-muted-foreground uppercase tracking-wider">
        {"管理者"}</p>
      {navItems.map(({ label, href, icon: Icon }) => {
        const isActive = pathname.includes(href);
        return (
          <Link
            key={href}
            href={href}
            className={cn(
              "flex items-center gap-3 rounded-md px-3 py-2 text-sm font-medium transition-colors",
              isActive
                ? "bg-primary text-primary-foreground"
                : "text-muted-foreground hover:bg-muted hover:text-foreground"
            )}
          >
            <Icon className="h-4 w-4 shrink-0" />
            {label}
          </Link>
        );
      })}
    </nav>
  );
}
