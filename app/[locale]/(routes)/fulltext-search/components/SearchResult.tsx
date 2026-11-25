"use client";

import { useSearchParams, useParams } from "next/navigation";
import { useEffect, useState } from "react";
import { EntityResultSection } from "@/components/fulltext-search/entity-result-section";
import {
  unifiedSearch,
  type UnifiedSearchResults,
} from "@/actions/fulltext/unified-search";

const ENTITY_LABELS: Record<keyof UnifiedSearchResults, string> = {
  accounts: "Accounts",
  contacts: "Contacts",
  leads: "Leads",
  opportunities: "Opportunities",
  projects: "Projects",
  tasks: "Tasks",
  users: "Users",
  documents: "Documents",
};

const ENTITY_ORDER: (keyof UnifiedSearchResults)[] = [
  "accounts",
  "contacts",
  "leads",
  "opportunities",
  "projects",
  "tasks",
  "users",
  "documents",
];

export default function SearchResult() {
  const searchParams = useSearchParams();
  const params = useParams();
  const query = searchParams?.get("q") ?? "";
  const locale = (params?.locale as string) ?? "en";

  const [results, setResults] = useState<UnifiedSearchResults | null>(null);
  // Key of the last finished search; loading while it differs from the current one
  const [loadedKey, setLoadedKey] = useState<string | null>(null);
  const searchKey = `${locale}:${query.trim()}`;
  const isLoading = loadedKey !== searchKey;

  useEffect(() => {
    if (!query || query.trim().length < 2) return;
    let cancelled = false;
    unifiedSearch(query.trim(), locale)
      .then((res) => {
        if (cancelled) return;
        if ("error" in res) {
          console.error("[UNIFIED_SEARCH]", res.error);
          return;
        }
        setResults(res);
      })
      .catch((err) => console.error(err))
      .finally(() => {
        if (!cancelled) setLoadedKey(searchKey);
      });
    return () => {
      cancelled = true;
    };
  }, [query, locale, searchKey]);

  if (!query)
    return <p className="text-muted-foreground">{"上の欄に検索語を入力してください。"}</p>;

  if (query.trim().length < 2)
    return (
      <p className="text-muted-foreground text-sm">
        {"2文字以上入力してください。"}</p>
    );

  if (isLoading)
    return (
      <div className="flex flex-col gap-4">
        {ENTITY_ORDER.map((key) => (
          <div key={key} className="h-16 rounded-md bg-muted animate-pulse" />
        ))}
      </div>
    );

  if (!results) return null;

  const hasAnyResults = ENTITY_ORDER.some((key) => results[key].length > 0);

  if (!hasAnyResults)
    return (
      <p className="text-muted-foreground">
        {"検索結果がありません：「"}{query}&quot;.
      </p>
    );

  return (
    <div className="flex flex-col gap-6">
      {ENTITY_ORDER.map((key) => (
        <EntityResultSection
          key={key}
          label={ENTITY_LABELS[key]}
          results={results[key]}
        />
      ))}
    </div>
  );
}
