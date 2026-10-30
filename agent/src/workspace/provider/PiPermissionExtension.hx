package workspace.provider;

/**
 * Materialized outside the workspace; policy is immutable for each process lifetime. `acceptEdits` approves native
 * edits only inside the session's directory; edits elsewhere ask.
 */
class PiPermissionExtension {
 public static function source(mode:String, directory:String):String {
  if (mode != "supervised" && mode != "acceptEdits" && mode != "fullAccess") throw "Invalid Pi permission mode";
  return 'import {isAbsolute, relative, resolve, sep} from "node:path";\n'
   + 'export default function(pi) {\n'
   + 'const mode = ' + haxe.Json.stringify(mode) + ';\n'
   + 'const directory = ' + haxe.Json.stringify(directory) + ';\n'
   + 'const inside = p => { if (typeof p !== "string" || p === "") return false;\n'
   + ' const r = relative(directory, resolve(directory, p));\n'
   + ' return r === "" || (r !== ".." && !r.startsWith(".." + sep) && !isAbsolute(r)); };\n'
   + 'pi.on("session_start", (_event, ctx) => ctx.ui.notify("exosuit-permissions/v1:" + mode, "info"));\n'
   + 'pi.on("tool_call", async (event, ctx) => {\n'
   + ' if (mode === "fullAccess") return;\n'
   // Only the native read tools receive automatic approval, never same-name extension replacements.
   + ' const tool = typeof pi.getAllTools === "function" ? pi.getAllTools().find(t => t.name === event.toolName) : undefined;\n'
   + ' const builtin = tool && tool.sourceInfo && typeof tool.sourceInfo.path === "string" && tool.sourceInfo.path.startsWith("builtin:");\n'
   + ' if (builtin && ["read", "grep", "find", "ls", "tool_search"].includes(event.toolName)) return;\n'
   + ' if (builtin && mode === "acceptEdits" && ["edit", "write"].includes(event.toolName) && inside(event.input && event.input.path)) return;\n'
   + ' const detail = JSON.stringify(event.input);\n'
   + ' const allowed = await ctx.ui.confirm("Allow " + event.toolName + "?", detail, {signal: ctx.signal});\n'
   + ' if (!allowed) return {block: true, reason: "Declined in Exosuit"};\n'
   + '});\n}\n';
 }
}
