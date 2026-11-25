#!/bin/zsh
set -euo pipefail
native_dir="${0:A:h}"
swiftc -swift-version 5 -parse-as-library -O -lsqlite3 "$native_dir/NativeDatabase.swift" "$native_dir/MailReview.swift" "$native_dir/CRMModules.swift" "$native_dir/InvoiceModules.swift" "$native_dir/OrderModules.swift" "$native_dir/CatalogModules.swift" "$native_dir/LineItemModules.swift" "$native_dir/LineItemMath.swift" "$native_dir/CRMLineItems.swift" "$native_dir/CRMCatalog.swift" "$native_dir/ProductCSV.swift" "$native_dir/PricingEngine.swift" "$native_dir/InvoiceMath.swift" "$native_dir/CRMService.swift" "$native_dir/CRMRelationships.swift" "$native_dir/OrderWorkflow.swift" "$native_dir/OrderDraftStore.swift" "$native_dir/CRMOrders.swift" "$native_dir/CRMOrdersTests.swift" -o "$native_dir/build/CRMOrdersTests"
"$native_dir/build/CRMOrdersTests" "$native_dir"
node "$native_dir/orders-reference.cjs"
swiftc -swift-version 5 -parse-as-library -O -lsqlite3 "$native_dir/NativeDatabase.swift" "$native_dir/MailReview.swift" "$native_dir/PricingEngine.swift" "$native_dir/LineItemMath.swift" "$native_dir/InvoiceMath.swift" "$native_dir/OrderWorkflow.swift" "$native_dir/OrderReferenceTests.swift" -o "$native_dir/build/OrderReferenceTests"
"$native_dir/build/OrderReferenceTests" "$native_dir/build/orders-reference.json"
