#!/usr/bin/env python3
"""Original order TypeScript oracle versus real native router/SQLite effects."""
from pathlib import Path
import hashlib
import json
import subprocess

n = Path(__file__).resolve().parent
names = ["NativeDatabase", "CRMModules", "InvoiceModules", "CatalogModules", "LineItemModules", "LineItemMath", "CRMLineItems", "CRMCatalog", "ProductCSV", "PricingEngine", "CRMService", "OrderModules", "OrderWorkflow", "OrderDraftStore", "CRMOrders", "InvoiceMath", "NativeAPITokens", "NativeMCPProtocol", "NativeMCPInputCatalog", "NativeMCPRequestRouter", "NativeMCPAccounts", "NativeMCPAccountsFixture", "NativeMCPLeads", "NativeMCPLeadsMail", "InvoiceMail", "InvoiceMailCredentials", "NativeMCPProducts", "NativeMCPPriceLists", "NativeMCPOrders", "NativeMCPOrdersTests", 'MailReview']
sources = [n / (name + ".swift") for name in names]
inputs = sources + [n / "schema.json", n / "schema.sql", n / "MCPToolCatalog.json", n / "mcp-orders-reference.cjs", Path(__file__).resolve()]
before = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
subprocess.run(["node", str(n / "mcp-orders-reference.cjs"), str(n / "build/mcp-orders-reference.json")], check=True)
binary = n / "build/NativeMCPOrdersTests"
subprocess.run(["swiftc", "-swift-version", "5", "-parse-as-library", "-O", "-target", "arm64-apple-macos13.0", "-framework", "Security", "-framework", "LocalAuthentication", "-lsqlite3", *map(str, sources), "-o", str(binary)], check=True)
result = subprocess.run([str(binary), str(n)], text=True, capture_output=True, timeout=240)
print(result.stdout, end="", flush=True)
print(result.stderr, end="", flush=True)
reference = json.loads((n / "build/mcp-orders-reference.json").read_text())
stable = before == {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
source_stable = all(hashlib.sha256((n.parent.parent / p).read_bytes()).hexdigest() == h for p, h in reference["sourceSHA256"].items())
(n / "build/mcp-orders-verification.json").write_text(json.dumps({"sourcesSHA256": before, "sourceReference": reference["sourceSHA256"], "inputsUnchanged": stable and source_stable,
    "stdout": result.stdout, "stderr": result.stderr, "exit": result.returncode, "sourceCases": len(reference["cases"]), "binaryBytes": binary.stat().st_size,
    "scope": "Eight order MCP operations against actual original handlers/services/workflow/pricing; SQLite order/line/numbering, audit and notification decisions; no external email or plugin hooks."}, ensure_ascii=False, indent=2) + "\n")
result.check_returncode()
assert stable and source_stable, "Inputs changed during verification"
