#!/bin/zsh
set -euo pipefail
native_dir="${0:A:h}"
fixture="$HOME/Library/Application Support/NextCRMNative/imports/benchmark-1000.jsonl"
[[ -f "$fixture" ]] || { print -u2 '既存の架空データ（benchmark-1000.jsonl）が見つかりません。'; exit 1; }
swiftc -swift-version 5 -parse-as-library -O -lsqlite3 "$native_dir/NativeDatabase.swift" "$native_dir/MailReview.swift" "$native_dir/CRMModules.swift" "$native_dir/InvoiceModules.swift" "$native_dir/CatalogModules.swift" "$native_dir/LineItemModules.swift" "$native_dir/LineItemMath.swift" "$native_dir/CRMLineItems.swift" "$native_dir/CRMCatalog.swift" "$native_dir/ProductCSV.swift" "$native_dir/PricingEngine.swift" "$native_dir/CRMService.swift" "$native_dir/OrderModules.swift" "$native_dir/OrderWorkflow.swift" "$native_dir/OrderDraftStore.swift" "$native_dir/CRMOrders.swift" "$native_dir/InvoiceMath.swift" "$native_dir/AccountStore.swift" "$native_dir/LegacyMigration.swift" "$native_dir/BenchmarkFixture.swift" -o "$native_dir/build/BenchmarkFixture"
"$native_dir/build/BenchmarkFixture" "$native_dir" "$fixture"
