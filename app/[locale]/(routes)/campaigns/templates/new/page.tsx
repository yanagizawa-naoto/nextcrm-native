import TemplateEditorForm from "./components/TemplateEditorForm";

export default function NewTemplatePage() {
  return (
    <div className="flex flex-col gap-6 p-6">
      <div>
        <h1 className="text-2xl font-bold">{"テンプレートを作成"}</h1>
        <p className="text-muted-foreground">
          {"キャンペーンのメールテンプレートを作成します"}</p>
      </div>
      <TemplateEditorForm />
    </div>
  );
}
