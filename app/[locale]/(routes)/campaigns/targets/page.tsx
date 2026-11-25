import { Suspense } from "react";

import CrmTableSkeleton from "@/components/skeletons/crm-table-skeleton";
import Container from "../../components/ui/Container";
import TargetsView from "./components/TargetsView";
import { getTargets } from "@/actions/crm/get-targets";

const TargetsPage = async () => {
  const targets = await getTargets();
  return (
    <Container
      title="営業対象"
      description="マーケティングと営業の対象を管理します"
    >
      <Suspense fallback={<CrmTableSkeleton />}>
        <TargetsView data={targets} />
      </Suspense>
    </Container>
  );
};

export default TargetsPage;
