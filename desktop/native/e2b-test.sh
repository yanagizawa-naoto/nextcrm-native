#!/bin/zsh
set -euo pipefail
native_dir="${0:A:h}"
mkdir -p "$native_dir/build"
node "$native_dir/generate-target-enrichment-agent.cjs"
node "$native_dir/target-agent-script-test.cjs" "$native_dir/build/TargetEnrichmentAgent.mjs"
node "$native_dir/native-e2b-reference.cjs" "$native_dir/build/native-e2b-reference.json"
sources=(NativeDatabase MailReview CRMModules InvoiceModules CatalogModules LineItemModules LineItemMath CRMLineItems CRMCatalog ProductCSV PricingEngine CRMService OrderModules OrderWorkflow OrderDraftStore CRMOrders InvoiceMath NativeEmbeddingVector NativeEmbeddingClient NativeDocumentAIText NativeOpenAIChatClient NativeDocumentAIWorker NativeEmbeddingIndex NativeAICredentials NativeUserCredentialCleanup NativeE2BSettings NativeE2BConfiguration NativeAIQAServices NativeEmbeddingJobs NativeEmbeddingWorker NativeEnrichmentPolicy NativeContactEnrichment NativeContactEnrichmentWorker NativeTargetEnrichment NativeTargetEnrichmentWorker NativeE2BHTTP NativeE2BClient NativeEnrichmentWeb NativeEnrichmentText NativeEnrichmentPrompts NativeEnrichmentOpenAI NativeEnrichmentIdentity NativeEnrichmentOrchestrator InvoiceJobRunner NativeRuntimeControlTasks NativeContactEnrichmentRuntime NativeTargetEnrichmentRuntime NativeE2BTests)
files=()
for source in "${sources[@]}"; do files+=("$native_dir/$source.swift"); done
swiftc -swift-version 5 -parse-as-library -O -target arm64-apple-macos13.0 -framework Security -framework LocalAuthentication -lsqlite3 "${files[@]}" -o "$native_dir/build/NativeE2BTests"
"$native_dir/build/NativeE2BTests" "$native_dir"
