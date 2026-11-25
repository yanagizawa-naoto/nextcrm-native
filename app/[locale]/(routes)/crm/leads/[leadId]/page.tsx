import { getLead } from "@/actions/crm/get-lead";
import Container from "@/app/[locale]/(routes)/components/ui/Container";
import React from "react";
import { BasicView } from "./components/BasicView";
import { FindSimilarButton } from "@/components/crm/find-similar-button";
import DocumentsView from "../../components/DocumentsView";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { HistoryTab } from "./components/HistoryTab";
import { ActivitiesSection } from "./components/ActivitiesSection";

interface LeadDetailPageProps {
  params: Promise<{
    leadId: string;
  }>;
}

const LeadDetailPage = async (props: LeadDetailPageProps) => {
  const params = await props.params;
  const { leadId } = params;
  const lead: any = await getLead(leadId);

  if (!lead) return <div>{"見込み客が見つかりません"}</div>;

  return (
    <Container
      title={`見込み客： ${lead?.lastName} ${lead?.firstName}`}
      description={"取引先の営業状況を確認します"}
    >
      <Tabs defaultValue="overview">
        <TabsList>
          <TabsTrigger value="overview">{"概要"}</TabsTrigger>
          <TabsTrigger value="history">{"履歴"}</TabsTrigger>
        </TabsList>
        <TabsContent value="overview">
          <div className="space-y-5">
            <BasicView data={lead} />
            <ActivitiesSection leadId={lead.id} />
            <FindSimilarButton entityType="lead" recordId={leadId} />
            {/*         <DocumentsView data={lead?.documents} /> */}
          </div>
        </TabsContent>
        <TabsContent value="history">
          <HistoryTab leadId={leadId} />
        </TabsContent>
      </Tabs>
    </Container>
  );
};

export default LeadDetailPage;
