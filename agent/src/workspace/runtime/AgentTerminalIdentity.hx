package workspace.runtime;

import haxe.io.Path;
import sys.FileSystem;

/**
 * How a Claude Code terminal says which conversation it is in. The terminal's Claude is started with
 * `--settings <folder>/claude-settings.json`, a file in Exosuit's own state (never the user's settings), whose
 * SessionStart hook appends the hook's input to `<folder>/sessions.log`. Claude runs that hook at startup, on a resume
 * (also one that carries on under a new id) and after `/clear`, each time with the conversation's `session_id`; the
 * last id in the log is the terminal's conversation. The service reads it while the terminal runs and at a restart, so
 * a conversation is never taken by its folder and time alone.
 */
class AgentTerminalIdentity {
 static inline final READ_BYTES:Int = 64 * 1024;
 static inline final MAX_LOG_BYTES:Int = 4 * 1024 * 1024;

 /** The terminal's folder under the service's state folder; null when there is no state folder. */
 public static function folder(state:Null<String>, terminal:String):Null<String> {
  if (state == null || terminal == null || terminal == "") return null;
  return Path.join([state, "agent-identity", haxe.crypto.Sha256.encode(terminal).substr(0, 24)]);
 }

 /** A path a command shim and the hook's shell pass unchanged: absolute, plain characters, no quotes. */
 static function plain(path:String):Bool
  return path.length <= 900 && path.indexOf("..") < 0 && ~/^([A-Za-z]:[\\\/]|\/)[A-Za-z0-9 _.\\\/:-]+$/.match(path);

 /**
  * Writes the folder's Claude settings and returns their path, or null when they cannot be used (the folder's path has
  * characters a command line or the hook's shell would change, or it cannot be written). `fresh` empties the log: a
  * terminal's first start, whose conversation is the one it is given.
  */
 public static function claudeSettings(folder:Null<String>, fresh:Bool):Null<String> {
  if (folder == null) return null;
  try {
   var full = Path.normalize(folder);
   if (!plain(full)) return null;
   var parent = Path.directory(full);
   if (!FileSystem.exists(parent)) FileSystem.createDirectory(parent);
   if (!FileSystem.exists(full)) FileSystem.createDirectory(full);
   var log = Path.join([full, "sessions.log"]), settings = Path.join([full, "claude-settings.json"]);
   if (fresh && FileSystem.exists(log)) FileSystem.deleteFile(log);
   var slashed = StringTools.replace(log, "\\", "/");
   // Windows: PowerShell, which every Windows has (Git Bash is optional); elsewhere the hook's default shell.
   var hook:Dynamic = Sys.systemName() == "Windows"
    ? {type: "command", shell: "powershell", timeout: 10,
     command: "$t=[Console]::In.ReadToEnd(); Add-Content -LiteralPath '" + slashed + "' -Value $t"}
    : {type: "command", timeout: 10, command: "cat >> '" + slashed + "'; echo >> '" + slashed + "'"};
   sys.io.File.saveContent(settings, haxe.Json.stringify({hooks: {SessionStart: [{hooks: [hook]}]}}, null, " "));
   return settings;
  } catch (_:Dynamic) {}
  return null;
 }

 /** The last conversation id the terminal's Claude reported; null when it reported none. */
 public static function reported(folder:Null<String>):Null<String> {
  if (folder == null) return null;
  try {
   var log = Path.join([folder, "sessions.log"]);
   if (!FileSystem.exists(log)) return null;
   // A report is a few hundred bytes per conversation start; a log far larger than that is not one.
   var metadata = FileSystem.metadata(log);
   if (metadata == null || metadata.size > MAX_LOG_BYTES) return null;
   var bytes = sys.io.File.getBytes(log);
   var from = bytes.length > READ_BYTES ? bytes.length - READ_BYTES : 0;
   var text = bytes.getString(from, bytes.length - from);
   var pattern = ~/"session_id"\s*:\s*"([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})"/;
   var last:Null<String> = null;
   while (pattern.match(text)) {
    last = pattern.matched(1);
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
