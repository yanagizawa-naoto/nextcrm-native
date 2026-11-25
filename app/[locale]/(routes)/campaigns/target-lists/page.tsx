import { Suspense } from "react";

import CrmTableSkeleton from "@/components/skeletons/crm-table-skeleton";
import Container from "../../components/ui/Container";
import TargetListsView from "./components/TargetListsView";
import { getTargetLists } from "@/actions/crm/get-target-lists";

const TargetListsPage = async () => {
  const targetLists = await getTargetLists();
  return (
    <Container
      title="営業対象リスト"
      description="キャンペーンや営業活動で使うリストを管理します"
    >
      <Suspense fallback={<CrmTableSkeleton />}>
        <TargetListsView data={targetLists} />
      </Suspense>
    </Container>
  );
};

export default TargetListsPage;
