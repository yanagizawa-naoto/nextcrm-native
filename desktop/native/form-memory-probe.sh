#!/bin/zsh
set -euo pipefail
native_dir="${0:A:h}"
mkdir -p "$native_dir/build"
swiftc -swift-version 5 -parse-as-library -O -target arm64-apple-macos13.0 \
  -framework AppKit -framework CoreText -lsqlite3 "$native_dir/NativeDatabase.swift" "$native_dir/MailReview.swift" "$native_dir/CRMModules.swift" "$native_dir/InvoiceModules.swift" "$native_dir/CatalogModules.swift" "$native_dir/LineItemModules.swift" "$native_dir/LineItemMath.swift" "$native_dir/CRMLineItems.swift" "$native_dir/CRMCatalog.swift" "$native_dir/ProductCSV.swift" "$native_dir/PricingEngine.swift" "$native_dir/CRMService.swift" "$native_dir/OrderModules.swift" "$native_dir/OrderWorkflow.swift" "$native_dir/OrderDraftStore.swift" "$native_dir/CRMOrders.swift" "$native_dir/InvoiceMath.swift" "$native_dir/CRMRelationships.swift" "$native_dir/LegacyMigration.swift" "$native_dir/CRMEditor.swift" "$native_dir/FormDraft.swift" "$native_dir/DeferredTextInput.swift" "$native_dir/VirtualFormEditor.swift" "$native_dir/CRMOrderLineEditor.swift" "$native_dir/CRMOrderWindow.swift" "$native_dir/CRMOrderSettingsWindow.swift" "$native_dir/CRMTargetListWindow.swift" "$native_dir/CRMPriceCheckWindow.swift" "$native_dir/CRMProductImportWindow.swift" "$native_dir/LightweightTable.swift" "$native_dir/MemoryBudget.swift" "$native_dir/FormMemoryProbe.swift" \
  -o "$native_dir/build/FormMemoryProbe"
for run in 1 2 3; do
  for mode in eager virtual; do
    NEXTCRM_NATIVE_FORM_MODE="$mode" "$native_dir/build/FormMemoryProbe" "$native_dir" "$native_dir/../artifacts/native-long-form-$mode-$run.json" 4000
  done
done
