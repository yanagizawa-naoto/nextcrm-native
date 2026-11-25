import { getSession } from "@/lib/auth-server";
import { redirect } from "next/navigation";
import Link from "next/link";

import Container from "../../../components/ui/Container";
import { getUserCRMTasks } from "@/actions/crm/tasks/get-user-tasks";
import { getUserLeads } from "@/actions/crm/get-user-leads";
import { getUserOpportunities } from "@/actions/crm/get-user-opportunities";
import { Badge } from "@/components/ui/badge";
import {
  Card,
  CardContent,
  CardHeader,
  CardTitle,
} from "@/components/ui/card";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";

const UserDashboardPage = async () => {
  const session = await getSession();

  if (!session) {
    redirect("/auth/signin");
  }

  const [tasks, leads, opportunities] = await Promise.all([
    getUserCRMTasks(session.user.id),
    getUserLeads(session.user.id),
    getUserOpportunities(session.user.id),
  ]);

  const openTasks = tasks.filter((t) => t.taskStatus === "ACTIVE");
  const openLeads = leads;
  const activeOpportunities = opportunities.filter(
    (o) => o.status === "ACTIVE"
  );

  return (
    <Container
      title={`${session.user.name} — My Dashboard`}
      description="担当する営業活動の概要"
    >
      {/* Stats */}
      <div className="grid grid-cols-2 md:grid-cols-4 gap-4 mb-6">
        <Card>
          <CardHeader className="pb-2">
            <CardTitle className="text-sm font-medium text-muted-foreground">
              {"タスク総数"}</CardTitle>
          </CardHeader>
          <CardContent>
            <div className="text-2xl font-bold">{tasks.length}</div>
          </CardContent>
        </Card>
        <Card>
          <CardHeader className="pb-2">
            <CardTitle className="text-sm font-medium text-muted-foreground">
              {"未完了タスク"}</CardTitle>
          </CardHeader>
          <CardContent>
            <div className="text-2xl font-bold">{openTasks.length}</div>
          </CardContent>
        </Card>
        <Card>
          <CardHeader className="pb-2">
            <CardTitle className="text-sm font-medium text-muted-foreground">
              {"自分の見込み客"}</CardTitle>
          </CardHeader>
          <CardContent>
            <div className="text-2xl font-bold">{openLeads.length}</div>
          </CardContent>
        </Card>
        <Card>
          <CardHeader className="pb-2">
            <CardTitle className="text-sm font-medium text-muted-foreground">
              {"進行中の商談"}</CardTitle>
          </CardHeader>
          <CardContent>
            <div className="text-2xl font-bold">
              {activeOpportunities.length}
            </div>
          </CardContent>
        </Card>
      </div>

      <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
        {/* Tasks */}
        <Card>
          <CardHeader>
            <CardTitle className="text-base">{"自分のタスク"}</CardTitle>
          </CardHeader>
          <CardContent className="p-0">
            {tasks.length === 0 ? (
              <p className="text-sm text-muted-foreground px-6 pb-4">
                {"担当するタスクはありません。"}</p>
            ) : (
              <Table>
                <TableHeader>
                  <TableRow>
                    <TableHead>{"契約名"}</TableHead>
                    <TableHead>{"優先度"}</TableHead>
                    <TableHead>{"状態"}</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {tasks.slice(0, 8).map((task) => (
                    <TableRow key={task.id}>
                      <TableCell className="font-medium">
                        <Link
                          href={`/crm/tasks/viewtask/${task.id}`}
                          className="hover:underline"
                        >
                          {task.title}
                        </Link>
                      </TableCell>
                      <TableCell>
                        <Badge
                          variant={
                            task.priority === "high"
                              ? "destructive"
                              : "outline"
                          }
                        >
                          {task.priority}
                        </Badge>
                      </TableCell>
                      <TableCell>
                        <Badge
                          variant={
                            task.taskStatus === "ACTIVE"
                              ? "default"
                              : "secondary"
                          }
                        >
                          {task.taskStatus}
                        </Badge>
                      </TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
            )}
          </CardContent>
        </Card>

        {/* Opportunities */}
        <Card>
          <CardHeader>
            <CardTitle className="text-base">{"自分の商談"}</CardTitle>
          </CardHeader>
          <CardContent className="p-0">
            {opportunities.length === 0 ? (
              <p className="text-sm text-muted-foreground px-6 pb-4">
                {"担当する商談はありません。"}</p>
            ) : (
              <Table>
                <TableHeader>
                  <TableRow>
                    <TableHead>{"名称"}</TableHead>
                    <TableHead>{"段階"}</TableHead>
                    <TableHead>{"予算"}</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {opportunities.slice(0, 8).map((opp) => (
                    <TableRow key={opp.id}>
                      <TableCell className="font-medium">
                        <Link
                          href={`/crm/opportunities/${opp.id}`}
                          className="hover:underline"
                        >
                          {opp.name ?? "—"}
                        </Link>
                      </TableCell>
                      <TableCell>
                        {opp.assigned_sales_stage?.name ?? "—"}
                      </TableCell>
                      <TableCell>
                        {opp.budget ? `$${Number(opp.budget).toLocaleString("ja-JP")}` : "—"}
                      </TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
            )}
          </CardContent>
        </Card>

        {/* Leads */}
        <Card className="md:col-span-2">
          <CardHeader>
            <CardTitle className="text-base">{"自分の見込み客"}</CardTitle>
          </CardHeader>
          <CardContent className="p-0">
            {leads.length === 0 ? (
              <p className="text-sm text-muted-foreground px-6 pb-4">
                {"担当する見込み客はありません。"}</p>
            ) : (
              <Table>
                <TableHeader>
                  <TableRow>
                    <TableHead>{"名称"}</TableHead>
                    <TableHead>{"会社名"}</TableHead>
                    <TableHead>{"メールアドレス"}</TableHead>
                    <TableHead>{"状態"}</TableHead>
                    <TableHead>{"登録元"}</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {leads.slice(0, 10).map((lead) => (
                    <TableRow key={lead.id}>
                      <TableCell className="font-medium">
                        <Link
                          href={`/crm/leads/${lead.id}`}
                          className="hover:underline"
                        >
                          {[lead.lastName, lead.firstName]
                            .filter(Boolean)
                            .join(" ")}
                        </Link>
                      </TableCell>
                      <TableCell>{lead.company ?? "—"}</TableCell>
                      <TableCell>{lead.email ?? "—"}</TableCell>
                      <TableCell>
                        <Badge variant="outline">
                          {"—"}
                        </Badge>
                      </TableCell>
                      <TableCell>{"—"}</TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
            )}
          </CardContent>
        </Card>
      </div>
    </Container>
  );
};

export default UserDashboardPage;
