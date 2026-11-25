import Container from "@/app/[locale]/(routes)/components/ui/Container";
import { BasicView } from "./components/BasicView";
import { getTargetList } from "@/actions/crm/get-target-list";

const TargetListViewPage = async (props: any) => {
  const params = await props.params;
  const { targetListId } = params;
  const targetList: any = await getTargetList(targetListId);

  if (!targetList) return <div>{"営業対象リストが見つかりません"}</div>;

  return (
    <Container
      title={`Target List: ${targetList?.name}`}
      description="リスト内の営業対象を確認・管理します"
    >
      <div className="space-y-5">
        <BasicView data={targetList} />
      </div>
    </Container>
  );
};

export default TargetListViewPage;
