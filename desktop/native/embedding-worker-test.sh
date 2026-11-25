#!/bin/zsh
set -euo pipefail
native_dir="${0:A:h}"
mkdir -p "$native_dir/build"
node "$native_dir/native-embedding-worker-reference.cjs" "$native_dir/build/native-embedding-worker-reference.json"
sources=(NativeDatabase MailReview CRMModules InvoiceModules CatalogModules LineItemModules LineItemMath CRMLineItems CRMCatalog ProductCSV PricingEngine CRMService OrderModules OrderWorkflow OrderDraftStore CRMOrders InvoiceMath NativeEmbeddingVector NativeEmbeddingClient NativeDocumentAIText NativeOpenAIChatClient NativeDocumentAIWorker NativeEmbeddingIndex NativeAICredentials NativeUserCredentialCleanup NativeAIQAServices NativeEmbeddingJobs NativeEmbeddingWorker NativeEmbeddingWorkerTests)
files=()
for source in "${sources[@]}"; do files+=("$native_dir/$source.swift"); done
swiftc -swift-version 5 -parse-as-library -O -target arm64-apple-macos13.0 -framework Security -framework LocalAuthentication -lsqlite3 "${files[@]}" -o "$native_dir/build/NativeEmbeddingWorkerTests"
"$native_dir/build/NativeEmbeddingWorkerTests" "$native_dir"
