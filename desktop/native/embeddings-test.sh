#!/bin/zsh
set -euo pipefail
native_dir="${0:A:h}"
mkdir -p "$native_dir/build"
node "$native_dir/native-embedding-reference.cjs" "$native_dir/build/native-embedding-reference.json"
sources=(NativeDatabase MailReview CRMModules InvoiceModules CatalogModules LineItemModules LineItemMath CRMLineItems CRMCatalog ProductCSV PricingEngine CRMService OrderModules OrderWorkflow OrderDraftStore CRMOrders InvoiceMath NativeEmbeddingVector NativeEmbeddingClient NativeEmbeddingIndex CRMEmbeddingSearch NativeEmbeddingTests)
files=()
for source in "${sources[@]}"; do files+=("$native_dir/$source.swift"); done
swiftc -swift-version 5 -parse-as-library -O -target arm64-apple-macos13.0 -lsqlite3 "${files[@]}" -o "$native_dir/build/NativeEmbeddingTests"
"$native_dir/build/NativeEmbeddingTests" "$native_dir"
