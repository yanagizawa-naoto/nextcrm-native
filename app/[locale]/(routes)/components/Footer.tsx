import { version } from "@/package.json";

export default function Footer() {
  return (
    <footer className="flex h-10 items-center justify-end gap-4 px-5 text-xs text-muted-foreground">
      <span>NextCRM 日本語版 · {version}</span>
      {process.env.NEXTCRM_DESKTOP === "1" && <span>データ保存先：このMac</span>}
    </footer>
  );
}
