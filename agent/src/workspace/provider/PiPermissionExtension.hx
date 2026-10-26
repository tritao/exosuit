package workspace.provider;

/** Materialized outside the workspace; policy is immutable for each process lifetime. */
class PiPermissionExtension {
 public static function source(mode:String):String {
  if (mode != "supervised" && mode != "acceptEdits" && mode != "fullAccess") throw "Invalid Pi permission mode";
  return 'export default function(pi) {\n'
   + 'const mode = ' + haxe.Json.stringify(mode) + ';\n'
   + 'pi.on("session_start", (_event, ctx) => ctx.ui.notify("exosuit-permissions/v1:" + mode, "info"));\n'
   + 'pi.on("tool_call", async (event, ctx) => {\n'
   + ' if (mode === "fullAccess") return;\n'
   // Only the native read tools receive automatic approval, never same-name extension replacements.
   + ' const tool = typeof pi.getAllTools === "function" ? pi.getAllTools().find(t => t.name === event.toolName) : undefined;\n'
   + ' const builtin = tool && tool.sourceInfo && typeof tool.sourceInfo.path === "string" && tool.sourceInfo.path.startsWith("builtin:");\n'
   + ' if (builtin && ["read", "grep", "find", "ls", "tool_search"].includes(event.toolName)) return;\n'
   + ' if (builtin && mode === "acceptEdits" && ["edit", "write"].includes(event.toolName)) return;\n'
   + ' const detail = JSON.stringify(event.input);\n'
   + ' const allowed = await ctx.ui.confirm("Allow " + event.toolName + "?", detail, {signal: ctx.signal});\n'
   + ' if (!allowed) return {block: true, reason: "Declined in Exosuit"};\n'
   + '});\n}\n';
 }
}
