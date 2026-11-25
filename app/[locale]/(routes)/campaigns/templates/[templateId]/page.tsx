import { getTemplate } from "@/actions/campaigns/templates/get-template";
import TemplateEditorForm from "../new/components/TemplateEditorForm";

type Props = {
  params: Promise<{ templateId: string }>;
};

export default async function EditTemplatePage({ params }: Props) {
  const { templateId } = await params;
  const template = await getTemplate(templateId);

  if (!template) {
    return (
      <div className="flex flex-col gap-6 p-6">
        <p className="text-muted-foreground">{"テンプレートが見つかりません。"}</p>
      </div>
    );
  }

  return (
    <div className="flex flex-col gap-6 p-6">
      <div>
        <h1 className="text-2xl font-bold">{"テンプレートを編集"}</h1>
        <p className="text-muted-foreground">
          {"キャンペーンのメールテンプレートを編集します"}</p>
      </div>
      <TemplateEditorForm
        templateId={template.id}
        initialData={{
          name: template.name,
          description: template.description,
          subject_default: template.subject_default,
          content_html: template.content_html,
          content_json: template.content_json as object | null,
        }}
      />
    </div>
  );
}
