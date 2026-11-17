package workspace.runtime;

import haxe.io.Path;
import sys.FileSystem;

/**
 * How a provider terminal says which conversation it is in. Each terminal has a folder in the service's state (never the
 * user's own provider settings) holding `sessions.log`, to which its provider appends a line each time it goes on with a
 * conversation, through the provider's own extension point:
 *
 * - Claude Code: `--settings <folder>/claude-settings.json`, whose SessionStart hook appends the hook's input (with
 *   `session_id`). Claude runs it at startup, on a resume (also one that carries on under a new id) and after `/clear`.
 * - Codex: `-c notify=[<folder>/codex-notify script]`. Codex runs the program after each turn with a JSON argument
 *   holding `thread-id`, also after `/new` or a resume from its own picker. Until a first turn completes there is
 *   nothing to resume, and nothing is reported. The setting replaces a `notify` of the user's own Codex configuration
 *   in this terminal.
 * - Pi: `--extension <folder>/pi-identity.mjs`, whose `session_start` handler appends `session_id` (Pi runs it at
 *   startup and after `/new`, `/resume` and `/fork`).
 *
 * The last id in the log is the terminal's conversation, and a restart resumes it: a conversation is never taken by its
 * folder and time, and the providers' own files are not searched for it.
 */
class AgentTerminalIdentity {
 static inline final READ_BYTES:Int = 64 * 1024;
 static inline final MAX_LOG_BYTES:Int = 4 * 1024 * 1024;

 /** The terminal's folder under the service's state folder; null when there is no state folder. */
 public static function folder(state:Null<String>, terminal:String):Null<String> {
  if (state == null || terminal == null || terminal == "") return null;
  return Path.join([state, "agent-identity", haxe.crypto.Sha256.encode(terminal).substr(0, 24)]);
 }

 /** A path a command shim and the reporting shell pass unchanged: absolute, plain characters, no quotes. */
 static function plain(path:String):Bool
  return path.length <= 900 && path.indexOf("..") < 0 && ~/^([A-Za-z]:[\\\/]|\/)[A-Za-z0-9 _.\\\/:-]+$/.match(path);

 /**
  * The arguments that make the terminal's provider report its conversation into the log of `folder`; none when the
  * folder cannot be used (its path has characters a command line or a shell would change, or it cannot be written).
  * `fresh` empties the log: a terminal's first start, whose conversation is the one it is given.
  */
 public static function reporting(provider:String, folder:Null<String>, fresh:Bool):Array<String> {
  if (folder == null) return [];
  try {
   var full = Path.normalize(folder);
   if (!plain(full)) return [];
   var parent = Path.directory(full);
   if (!FileSystem.exists(parent)) FileSystem.createDirectory(parent);
   if (!FileSystem.exists(full)) FileSystem.createDirectory(full);
   var log = Path.join([full, "sessions.log"]);
   if (fresh && FileSystem.exists(log)) FileSystem.deleteFile(log);
   var windows = Sys.systemName() == "Windows";
   switch (provider) {
    case "claude":
     // Windows: PowerShell, which every Windows has (Git Bash is optional); elsewhere the hook's default shell.
     var hook:Dynamic = windows
      ? {type: "command", shell: "powershell", timeout: 10,
       command: "$t=[Console]::In.ReadToEnd(); Add-Content -LiteralPath '" + log + "' -Value $t"}
      : {type: "command", timeout: 10, command: "cat >> '" + log + "'; echo >> '" + log + "'"};
     var settings = Path.join([full, "claude-settings.json"]);
     sys.io.File.saveContent(settings, haxe.Json.stringify({hooks: {SessionStart: [{hooks: [hook]}]}}, null, " "));
     return ["--settings", settings];
    case "codex":
     // The program gets the turn as JSON in its last argument. The setting is a TOML list of literal strings: it has
     // no `"`, which a Windows command shim would take as quoting.
     var script = Path.join([full, windows ? "codex-notify.ps1" : "codex-notify.sh"]);
     sys.io.File.saveContent(script, windows
      ? "param([string]$turn)\r\nAdd-Content -LiteralPath '" + log + "' -Value $turn\r\n"
      : "printf '%s\\n' \"$1\" >> '" + log + "'\n");
     var program = windows ? ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", script] : ["sh", script];
     return ["-c", "notify=[" + [for (part in program) "'" + part + "'"].join(",") + "]"];
    case "pi":
     var extension = Path.join([full, "pi-identity.mjs"]);
     sys.io.File.saveContent(extension, 'import { appendFileSync } from "node:fs";\n'
      + "export default function (pi) {\n"
      + ' pi.on("session_start", (_event, ctx) => {\n'
      + "  try { appendFileSync(" + haxe.Json.stringify(log)
      + ', JSON.stringify({ session_id: ctx.sessionManager.getSessionId() }) + "\\n"); } catch {}\n'
      + " });\n}\n");
     return ["--extension", extension];
    default:
   }
  } catch (_:Dynamic) {}
  return [];
 }

 /** The last conversation id the terminal's provider reported; null when it reported none. */
 public static function reported(folder:Null<String>):Null<String> {
  if (folder == null) return null;
  try {
   var log = Path.join([folder, "sessions.log"]);
   if (!FileSystem.exists(log)) return null;
   // A report is a few hundred bytes per conversation start or turn; a log far larger than that is not one.
   var metadata = FileSystem.metadata(log);
   if (metadata == null || metadata.size > MAX_LOG_BYTES) return null;
   var bytes = sys.io.File.getBytes(log);
   var from = bytes.length > READ_BYTES ? bytes.length - READ_BYTES : 0;
   var text = bytes.getString(from, bytes.length - from);
   // Claude and Pi report `session_id`, Codex `thread-id`.
   var pattern = ~/"(session_id|thread-id)"\s*:\s*"([0-9A-Za-z][0-9A-Za-z._-]{0,127})"/;
   var last:Null<String> = null;
   while (pattern.match(text)) {
    last = pattern.matched(2);
    text = pattern.matchedRight();
   }
   return last;
  } catch (_:Dynamic) {}
  return null;
 }

 /** Removes the terminal's folder (the terminal was removed). */
 public static function remove(folder:Null<String>):Void {
  if (folder == null) return;
  try {
   if (!FileSystem.exists(folder)) return;
   for (name in FileSystem.readDirectory(folder)) FileSystem.deleteFile(Path.join([folder, name]));
   FileSystem.deleteDirectory(folder);
  } catch (_:Dynamic) {}
 }
}
