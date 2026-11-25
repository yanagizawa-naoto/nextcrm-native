import { FileBarChart } from "lucide-react"
import { NavItem } from "../nav-main"

/**
 * Reports Module Menu Item - Task 2.6.4
 *
 * Converted from Link pattern to NavItem structure for sidebar integration.
 * Used in app-sidebar.tsx with module filtering (name === "reports").
 *
 * References:
 * - Previous: Simple Link component with FileBarChart icon
 * - ModuleMenu.tsx: lines 96-100
 * - Route: /reports
 */

interface GetReportsMenuItemProps {
  title: string
}

/**
 * Returns navigation item configuration for Reports module
 * @param title - Localized title for the menu item
 * @returns NavItem object compatible with NavMain component
 */
export default function getReportsMenuItem({
  title,
}: GetReportsMenuItemProps): NavItem {
  return {
    title,
    icon: FileBarChart,
    items: [
      { title: "ダッシュボード", url: "/reports", exact: true },
      { title: "営業管理", url: "/reports/sales" },
      { title: "見込み客", url: "/reports/leads" },
      { title: "取引先", url: "/reports/accounts" },
      { title: "活動履歴", url: "/reports/activity" },
      { title: "キャンペーン", url: "/reports/campaigns" },
      { title: "ユーザー管理", url: "/reports/users" },
    ],
  }
}
