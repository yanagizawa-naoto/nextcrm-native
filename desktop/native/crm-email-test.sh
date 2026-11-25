#!/bin/zsh
set -euo pipefail
native_dir="${0:A:h}"
mkdir -p "$native_dir/build"
mail_build=$(mktemp -d "$native_dir/build/crm-email-test.XXXXXX")
function finish_mail_build() {
  local result=$?
  python3 "$native_dir/native_mail_build.py" verify "$native_dir" "$mail_build" "$0" --exit "$result"
  local verification=$?
  rm -rf "$mail_build/cache"
  if (( result != 0 )); then return "$result"; fi
  return "$verification"
}
trap finish_mail_build EXIT
python3 "$native_dir/native_mail_build.py" build "$native_dir" "$mail_build" "$0"
swiftc -swift-version 5 -parse-as-library -O -lsqlite3 -lcurl -framework Security -framework LocalAuthentication -lxml2 -module-cache-path "$mail_build/cache" -import-objc-header "$native_dir/NativeMailParsing.h" "$mail_build/NativeMailTransport.o" "$mail_build/CampaignHTML.o" "$native_dir/NativeOperationalAssets.swift" "$native_dir/NativeOperationalDocumentAssets.swift" "$native_dir/NativeMigratedDocuments.swift" "$native_dir/NativeDatabase.swift" "$native_dir/MailReview.swift" "$native_dir/CRMModules.swift" "$native_dir/InvoiceModules.swift" "$native_dir/CatalogModules.swift" "$native_dir/LineItemModules.swift" "$native_dir/LineItemMath.swift" "$native_dir/CRMLineItems.swift" "$native_dir/CRMCatalog.swift" "$native_dir/ProductCSV.swift" "$native_dir/PricingEngine.swift" "$native_dir/CRMService.swift" "$native_dir/OrderModules.swift" "$native_dir/OrderWorkflow.swift" "$native_dir/OrderDraftStore.swift" "$native_dir/CRMOrders.swift" "$native_dir/InvoiceMath.swift" "$native_dir/CRMRelationships.swift" "$native_dir/CRMProjects.swift" "$native_dir/CRMProjectTasks.swift" "$native_dir/NativeDocumentFiles.swift" "$native_dir/NativeMigrationManifest.swift" "$native_dir/NativeMigrationJSON.swift" "$native_dir/NativeDataMaintenanceRecoveryTypes.swift" "$native_dir/NativeDataMaintenanceRecoveryFiles.swift" "$native_dir/NativeDataMaintenanceRecovery.swift" "$native_dir/NativeExportStaging.swift" "$native_dir/CRMDocumentExports.swift" "$native_dir/CRMDocuments.swift" "$native_dir/NativeDocumentProcessing.swift" "$native_dir/CRMAccountTasks.swift" "$native_dir/NativeMailTemporaryFiles.swift" "$native_dir/NativeMail.swift" "$native_dir/NativeMailHTMLText.swift" "$native_dir/NativeMailMIME.swift" "$native_dir/NativeMailIMAP.swift" "$native_dir/NativeMailMIMESpool.swift" "$native_dir/NativeMailTextHTML.swift" "$native_dir/NativeMailIMAPFile.swift" "$native_dir/NativeFreshCredentialPublication.swift" "$native_dir/NativeMailCredentials.swift" "$native_dir/NativeUserCredentialCleanup.swift" "$native_dir/CRMEmail.swift" "$native_dir/NativeMailSpool.swift" "$native_dir/NativeMailClient.swift" "$native_dir/NativeMailSync.swift" "$native_dir/NativeMailSyncTests.swift" "$native_dir/NativeMailContent.swift" "$native_dir/NativeMailContentTests.swift" "$native_dir/NativeMailSend.swift" "$native_dir/NativeMailSendTests.swift" "$native_dir/InvoiceJobRunner.swift" "$native_dir/NativeMailRuntime.swift" "$native_dir/NativeMailRuntimeTests.swift" "$native_dir/CRMEmailTests.swift" -o "$mail_build/CRMEmailTests"
"$mail_build/CRMEmailTests" "$native_dir" "$@"
