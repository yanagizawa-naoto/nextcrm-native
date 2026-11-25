import Container from "@/app/[locale]/(routes)/components/ui/Container";

import { BasicView } from "./components/BasicView";
import { FindSimilarButton } from "@/components/crm/find-similar-button";

import { getContact } from "@/actions/crm/get-contact";
import { getOpportunitiesFullByContactId } from "@/actions/crm/get-opportunities-with-includes-by-contactId";
import { getAllCrmData } from "@/actions/crm/get-crm-data";
import { getDocumentsByContactId } from "@/actions/documents/get-documents-by-contactId";
import { getAccountsByContactId } from "@/actions/crm/get-accounts-by-contactId";

import AccountsView from "../../components/AccountsView";
import OpportunitiesView from "../../components/OpportunitiesView";
import DocumentsView from "../../components/DocumentsView";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { HistoryTab } from "./components/HistoryTab";
import { ActivitiesSection } from "./components/ActivitiesSection";

const ContactViewPage = async (props: any) => {
  const params = await props.params;
  const { contactId } = params;
  const contact: any = await getContact(contactId);
  const opportunities: any = await getOpportunitiesFullByContactId(contactId);
  const documents = await getDocumentsByContactId(contactId);
  const accounts = await getAccountsByContactId(contactId);
  const crmData = await getAllCrmData();

  //  console.log(accounts, "accounts");

  if (!contact) return <div>{"連絡先が見つかりません"}</div>;

  return (
    <Container
      title={`連絡先： ${contact?.last_name} ${contact?.first_name}`}
      description={"取引先の営業状況を確認します"}
    >
      <Tabs defaultValue="overview">
        <TabsList>
          <TabsTrigger value="overview">{"概要"}</TabsTrigger>
          <TabsTrigger value="history">{"履歴"}</TabsTrigger>
        </TabsList>
        <TabsContent value="overview">
          <div className="space-y-5">
            <BasicView data={contact} />
            <ActivitiesSection contactId={contact.id} />
            <FindSimilarButton entityType="contact" recordId={contactId} />
            <AccountsView data={accounts} crmData={crmData} />
            <OpportunitiesView data={opportunities} crmData={crmData} />
            <DocumentsView data={documents} />
          </div>
        </TabsContent>
        <TabsContent value="history">
          <HistoryTab contactId={contactId} />
        </TabsContent>
      </Tabs>
    </Container>
  );
};

export default ContactViewPage;
