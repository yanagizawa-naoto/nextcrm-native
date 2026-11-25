// The importable/exportable crm_Targets fields. Used by the import
// mapping UI and by CSV/XLSX export so the two stay in sync.
export interface TargetField {
  key: string;
  label: string;
  required: boolean;
}

export const TARGET_FIELDS: TargetField[] = [
  { key: "last_name", label: "Last Name", required: false },
  { key: "first_name", label: "First Name", required: false },
  { key: "email", label: "メールアドレス", required: false },
  { key: "mobile_phone", label: "Mobile Phone", required: false },
  { key: "office_phone", label: "Office Phone", required: false },
  { key: "company", label: "会社名", required: false },
  { key: "position", label: "部署・役職", required: false },
  { key: "company_website", label: "Company Website", required: false },
  { key: "personal_website", label: "Personal Website", required: false },
  { key: "social_linkedin", label: "LinkedIn", required: false },
  { key: "social_x", label: "X / Twitter", required: false },
  { key: "social_instagram", label: "Instagram", required: false },
  { key: "social_facebook", label: "Facebook", required: false },
  { key: "personal_email", label: "個人メールアドレス", required: false },
  { key: "company_email",  label: "会社メールアドレス",  required: false },
  { key: "company_phone",  label: "会社電話番号",  required: false },
  { key: "city",           label: "市区町村",           required: false },
  { key: "country",        label: "国",        required: false },
  { key: "industry",       label: "業種",       required: false },
  { key: "employees",      label: "従業員",      required: false },
  { key: "description",    label: "品名・内容",    required: false },
];
