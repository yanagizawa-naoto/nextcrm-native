# Campaign TipTap 保存往復テスト

Repository root で実行する。

```sh
python3 desktop/native/campaign-tiptap-test.py
```

本体 `CampaignRichText.swift` と実 `CampaignTemplateEditor` / `CRMTemplates` /
`CRMCampaignDraft` / SQLite を直接使用する。94入力fixturesと実選択範囲の太字保存・
再open後の編集保存2行を検証し、結果は `desktop/native/build/campaign-tiptap/verification.json`
に保存する。候補ソース、過去baseline、`template-rich-test.sh` の83チェックは再実行しない。

既存installed/locked依存のTipTap、TypeScript、esbuildだけを使用する。
`components/campaigns/TipTapEditor.tsx` の実extensions式をASTから抽出するため、
StarterKit / Underline / Linkの構成を別途近似しない。Reactと同じcore Editorの
実DOM parser / serializer / ProseMirror schemaをmacOS標準の非表示WKWebViewで動かす。
非永続データストア、外部通信を禁止するCSP、about:blank以外のnavigation拒否を使用する。
ブラウザ/ライブラリのdownload、通常データ、実Keychain、clipboard、外部HTTP、実送信は使わない。
製品にWebKitを追加するテストではない。SQLiteは一意の一時directoryで作成・回収する。

初期importではonUpdateが発生しないことと、本文変更時の更新を分ける。初期HTML/JSONは
fresh Editor同士で比較し、setContentのtrailing-node追加を初期parse差と誤認しない。
通常のmarks/境界空白/空ノード、HTML編集、metadata-only保存、campaign用の再利用/複製、
SQLite再open、実選択太字→保存→再編集を検証する。AppKitが同じmarkを隣接タグへ分割する
場合も、保存行を実upstream schemaへ戻し、HTMLの字面だけで判定しない。
属性内の擬似tagへ一時tokenを混入させないことも確認する。

## 明示的な限界

表・画像・詳細書式等の9fixturesは原HTMLを保護する。通常のmark境界空白は保護扱いにしない。
保護範囲の `nativeRawHTML` とラベルを含むnative JSONは、原典schema単独へ可搬ではない。
外部のJSON-only editorでは未知属性が落ち、保護ラベルになる。これは完全なrich/JSON互換を
証明するテストではなく、未対応範囲も証拠に記録する。

特殊URLの2fixturesでは、Foundation tidyの従来の`>`等→percent encodingという文字列差が残る。
fixtureに記載した該当hrefだけの変換を期待値として扱い、他の本文/marks/構造/URLは緩和しない。
`existingURLNormalizationBoundary` にこの差を明記する。

`campaign-tiptap-consumers.cjs` は原典の読取/編集/送信/MCP/exportとnative複製/送信の
20sourceをhash付きで記録し、実SSR rendererでHTML本文保持・保護ラベル不混入を検証する。
現Editor/preview/template selection/sendはHTMLを読み、MCPは両fieldを返し作成更新する。
DB backupのpg_dumpはソースを読むだけで実行しない。専用template-body exportは見つからず、
report CSVは集計だけである。live provider / PostgreSQL / MCP transport / exportの実行証明は含まない。
