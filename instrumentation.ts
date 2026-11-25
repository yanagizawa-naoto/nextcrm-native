export async function register() {
  if (process.env.NEXT_RUNTIME === "nodejs") {
  if (process.env.NEXTCRM_DESKTOP === "1" && process.listenerCount("SIGUSR2") === 0) {
    // Local diagnostics contain only memory counters, never CRM records.
    process.on("SIGUSR2", () => console.info("[NextCRM memory]", JSON.stringify(process.memoryUsage())));
  }
  if (process.env.SKIP_ENV_VALIDATION === "1") return; // docker build stage has no DB
  const { runPluginUpgrades } = await import("@/lib/plugins/upgrade");
  // Not awaited: onUpgrade hooks may take minutes and must not block serving. Replicas are
  // serialized by the advisory lock; until a plugin's upgrade finishes its code is already the new version and only the stored version is old.
  void runPluginUpgrades().catch((e) => console.error("[PLUGIN_UPGRADE]", e));
  }
}
