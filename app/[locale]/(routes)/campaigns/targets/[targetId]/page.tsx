import Container from "@/app/[locale]/(routes)/components/ui/Container";
import { BasicView } from "./components/BasicView";
import { getTarget } from "@/actions/crm/get-target";

const TargetViewPage = async (props: any) => {
  const params = await props.params;
  const { targetId } = params;
  const target: any = await getTarget(targetId);

  if (!target) return <div>{"営業対象が見つかりません"}</div>;

  return (
    <Container
      title={`営業対象： ${target?.first_name || ""} ${target?.last_name}`}
      description="営業対象の詳細を確認します"
    >
      <div className="space-y-5">
        <BasicView data={target} />
      </div>
    </Container>
  );
};

export default TargetViewPage;
