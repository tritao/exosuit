package workspace.runtime;

import haxe.io.Path;
import sys.FileSystem;
import workspace.provider.ClaudeTranscript;
import workspace.provider.LongPath;
import workspace.service.WorkspaceTerminalProtocol;

/** What a provider terminal is started with, and the conversation id its record keeps. */
typedef AgentTerminalLaunch = {
 var arguments:Array<String>;
 var session:Null<String>;
 /** Seconds since 1970 when the conversation was begun; kept so a Codex conversation can be found afterwards. */
 var started:Null<Int>;
 /** Shown in the terminal above the restarted program. */
 var note:String;
}

/**
 * A provider terminal (Claude Code, Codex in a terminal) continues the same conversation when it is started again
 * after its program was lost or ended. Without this a restart began a new conversation every time.
 *
 * A conversation is resumed only when it is provably the terminal's; otherwise the provider's own list of the folder's
 * conversations opens (`claude --resume`, `codex resume`, `pi --resume`) and the user picks. A folder and a time are
 * not proof: Claude, Codex and Pi run outside Exosuit, in chat sessions and in other terminals of the same folder too.
 *
 * - Claude: the terminal's conversation id is chosen here and given at the first start (`--session-id <id>`), and its
 *   Claude reports every conversation it goes on with (startup, resume, `/clear`) through a SessionStart hook in a
 *   settings file of the terminal's own state (`AgentTerminalIdentity`, `--settings <file>`). The service keeps the
 *   reported id in the record while the terminal runs, and a restart resumes the last reported id (`--resume <id>`
 *   when Claude keeps a record of it, else `--session-id <id>`). With nothing reported (a terminal started before the
 *   hook, or the hook could not run) the recorded id is resumed unless another conversation of the folder was written
 *   since; then the user picks.
 * - Codex cannot be given an id. Its record (`<CODEX_HOME or ~/.codex>/sessions/YYYY/MM/DD/rollout-<time>-<id>.jsonl`,
 *   first line `session_meta` with `cwd`) is looked for while the terminal runs (`resolve`): taken only when it is the
 *   one record of the terminal UI in the folder begun since the terminal started and not taken, and no other terminal
 *   of the folder waits for its own. Restart: `resume <id>`; without one, the list when the folder has a candidate.
 * - Pi keeps a session file per conversation (`<PI_CODING_AGENT_DIR or ~/.pi/agent>/sessions/--<folder>--/*.jsonl`,
 *   first line the `session` header with `cwd` and `timestamp`), found the same way as Codex's; the record keeps its
 *   path. Restart: `--session <file>`, else `--resume`.
 *
 * Provider files are only read, never written.
 */
class AgentTerminalResume {
 static inline final CODEX_SCAN_DAYS:Int = 7;
 static inline final CODEX_MAX_FILES:Int = 2048;
 /** The longest first line looked at (`session_meta` carries the session instructions, which can be large; the Pi `session` header). */
 static inline final CODEX_HEAD_BYTES:Int = 4 * 1024 * 1024;
 /** Larger records are not opened (they are read whole). */
 static inline final CODEX_MAX_BYTES:Int = 64 * 1024 * 1024;

 /**
  * `restart` is false for the terminal's first start. `taken` holds the conversation ids kept elsewhere: by other
  * terminals of the workspace and by its chat sessions. `identity` is the terminal's folder in the service's state
  * (`AgentTerminalIdentity`), null without one.
  */
 public static function plan(record:TerminalRecord, restart:Bool, taken:Array<String>, ?identity:String):AgentTerminalLaunch {
  var now = Std.int(Date.now().getTime() / 1000);
  var plain:AgentTerminalLaunch = {arguments: [], session: record.agentSession, started: record.agentStarted == null ? now : record.agentStarted,
   note: "── Shell restarted ──"};
  switch (record.agentProvider) {
   case "claude":
    var settings = AgentTerminalIdentity.claudeSettings(identity, !restart);
    var hook = settings == null ? [] : ["--settings", settings];
    var picker:AgentTerminalLaunch = {arguments: hook.concat(["--resume"]), session: null, started: now,
     note: "── Claude Code restarted: pick the conversation to continue ──"};
    var id = record.agentSession;
    if (id != null && !uuid(id)) id = null;
    if (restart) {
     // The conversation the terminal's own Claude last reported (also after `/clear`, or a resume under a new id).
     var told = AgentTerminalIdentity.reported(identity);
     if (told != null && taken.indexOf(told) < 0) id = told;
     // Nothing reported (a terminal started before the hook, or the hook could not run): when another conversation of
     // the folder was written since this one, the terminal may have gone on under a new id or someone else talked to
     // Claude there. Which one is not known, so the user picks.
     else if (id != null && ClaudeTranscript.locate(id, record.cwd) != null && ClaudeTranscript.othersWrittenSince(id, record.cwd, taken))
      return picker;
    }
    if (id == null) {
     if (restart && ClaudeTranscript.configDirectory() != null && ClaudeTranscript.hasConversations(record.cwd)) return picker;
     id = newUuid(record.id);
     return {arguments: hook.concat(["--session-id", id]), session: id, started: now,
      note: restart ? "── Claude Code restarted (new conversation) ──" : plain.note};
    }
    if (ClaudeTranscript.locate(id, record.cwd) != null)
     return {arguments: hook.concat(["--resume", id]), session: id, started: plain.started, note: "── Claude Code resumed ──"};
    return {arguments: hook.concat(["--session-id", id]), session: id, started: plain.started, note: "── Claude Code restarted ──"};
   case "codex":
    if (!restart) return {arguments: [], session: null, started: now, note: plain.note};
    var id = record.agentSession;
    if (id != null && ~/^[0-9A-Za-z-]{8,64}$/.match(id))
     return {arguments: ["resume", id], session: id, started: plain.started, note: "── Codex resumed ──"};
    // Not found while the terminal ran (`resolve`): a conversation of the folder begun since is not taken by its time
    // alone; the user picks.
    if (record.agentStarted == null || codexCandidates(record.cwd, record.agentStarted, taken).length > 0)
     return {arguments: ["resume"], session: null, started: now, note: "── Codex restarted: pick the conversation to continue ──"};
    return {arguments: [], session: null, started: now, note: "── Codex restarted (new conversation) ──"};
   case "pi":
    if (!restart) return {arguments: [], session: null, started: now, note: plain.note};
    var file = record.agentSession;
    if (file != null && (!FileSystem.exists(file) || !piArgument(file))) file = null;
    if (file != null) return {arguments: ["--session", file], session: file, started: plain.started, note: "── Pi resumed ──"};
    if (record.agentStarted == null || piCandidates(record.cwd, record.agentStarted, taken).length > 0)
     return {arguments: ["--resume"], session: null, started: now, note: "── Pi restarted: pick the conversation to continue ──"};
    return {arguments: [], session: null, started: now, note: "── Pi restarted (new conversation) ──"};
   default:
    return plain;
  }
 }

 /**
  * The conversation of a running Codex or Pi terminal that has none recorded yet (neither can be given an id, and both
  * may write their record only at the first message): the record of the terminal's folder begun since the terminal
  * started and not taken, when there is exactly one. The caller asks only while the terminal runs and no other
  * terminal of the same provider and folder is waiting for its own. Null while there is none, or more than one.
  */
 public static function resolve(record:TerminalRecord, taken:Array<String>):Null<String> {
  if (record.agentSession != null || record.agentStarted == null) return null;
  var found = switch (record.agentProvider) {
   case "codex": codexCandidates(record.cwd, record.agentStarted, taken);
   case "pi": piCandidates(record.cwd, record.agentStarted, taken);
   default: [];
  }
  return found.length == 1 ? found[0] : null;
 }

 /** A session file Pi can be pointed at through a Windows command shim: an absolute path of plain characters. */
 static function piArgument(path:String):Bool
  return path.length <= 1024 && ~/^([A-Za-z]:[\\\/]|\/)[A-Za-z0-9 _.\\\/:-]+$/.match(path) && path.indexOf("..") < 0;

 /** `PI_CODING_AGENT_DIR`, else `.pi/agent` in the user's home. */
 public static function piAgentDirectory():Null<String> {
  var configured = Sys.getEnv("PI_CODING_AGENT_DIR");
  if (configured != null && StringTools.trim(configured) != "") return configured;
  var home = Sys.systemName() == "Windows" ? Sys.getEnv("USERPROFILE") : Sys.getEnv("HOME");
  return home == null || home == "" ? null : Path.join([home, ".pi", "agent"]);
 }

 /** The folder Pi keeps a working folder's sessions in: `--` + the path without its leading separator, `/ \ :` as `-`, + `--`. */
 public static function piSessionFolder(cwd:String):Null<String> {
  var agent = piAgentDirectory();
  if (agent == null) return null;
  return Path.join([agent, "sessions", "--" + ~/[\\\/:]/g.replace(~/^[\\\/]/.replace(cwd, ""), "-") + "--"]);
 }

 /** Pi session files of the folder begun since `started` and not taken. */
 public static function piCandidates(cwd:String, started:Int, taken:Array<String>):Array<String> {
  var found:Array<String> = [];
  try {
   var folder = piSessionFolder(cwd);
   if (folder == null) return found;
   folder = LongPath.of(folder);
   if (!FileSystem.exists(folder) || !FileSystem.isDirectory(folder)) return found;
   var files = 0;
   var piName = ~/^(\d{4})-(\d{2})-(\d{2})T(\d{2})-(\d{2})-(\d{2})/;
   for (name in FileSystem.readDirectory(folder)) {
    if (!StringTools.endsWith(name, ".jsonl") || ++files > CODEX_MAX_FILES) continue;
    var path = Path.join([folder, name]);
    if (taken.indexOf(path) >= 0 || !piArgument(path)) continue;
    // The name carries the UTC start time (`2026-10-29T02-45-46-642Z_<id>.jsonl`); a file named long before is not opened.
    if (piName.match(name) && matchedTime(piName) < started - 15 * 3600) continue;
    var metadata = FileSystem.metadata(path);
    if (metadata == null || metadata.modified < started - 2) continue;
    var header:Dynamic = try firstRecord(path) catch (_:Dynamic) null;
    if (header == null || Reflect.field(header, "type") != "session") continue;
    var directory = Reflect.field(header, "cwd");
    if (!Std.isOfType(directory, String) || !samePath(directory, cwd)) continue;
    var stamp = Reflect.field(header, "timestamp");
    var time = Std.isOfType(stamp, String) ? utc(stamp) : null;
    if (time == null || time < started - 2) continue;
    found.push(path);
   }
  } catch (_:Dynamic) {}
  return found;
 }

 /**
  * The first line of a file, parsed, kept per path: a record's first line never changes once written, so a file the
  * scan has seen is not read again (haxeon's `sys.io.File` has no partial read, so each file is read whole, once).
  * Files over `CODEX_MAX_BYTES` and lines over `CODEX_HEAD_BYTES` are not looked at; a line that does not parse yet
  * (the file is being written) is not kept.
  */
 static function firstRecord(path:String):Dynamic {
  var held = heads.get(path);
  if (held != null) return held;
  var metadata = FileSystem.metadata(path);
  if (metadata == null || metadata.size > CODEX_MAX_BYTES) return null;
  var bytes = sys.io.File.getBytes(path);
  var end = 0;
  while (end < bytes.length && end < CODEX_HEAD_BYTES && bytes.get(end) != 10) end++;
  var first:Dynamic = haxe.Json.parse(bytes.getString(0, end));
  if (first == null) return null;
  if (headCount >= CODEX_MAX_FILES) {
   heads.clear();
   headCount = 0;
  }
  heads.set(path, first);
  headCount++;
  return first;
 }
 static final heads:Map<String, Dynamic> = [];
 static var headCount:Int = 0;

 static function uuid(v:String):Bool return ~/^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/.match(v);

 static function newUuid(seed:String):String {
  var hex = haxe.crypto.Sha256.encode(Std.string(Sys.time()) + ":" + Math.random() + ":" + seed);
  return hex.substr(0, 8) + "-" + hex.substr(8, 4) + "-4" + hex.substr(13, 3) + "-a" + hex.substr(17, 3) + "-" + hex.substr(20, 12);
 }

 /** `CODEX_HOME`, else `.codex` in the user's home. */
 public static function codexHome():Null<String> {
  var configured = Sys.getEnv("CODEX_HOME");
  if (configured != null && StringTools.trim(configured) != "") return configured;
  var home = Sys.systemName() == "Windows" ? Sys.getEnv("USERPROFILE") : Sys.getEnv("HOME");
  return home == null || home == "" ? null : Path.join([home, ".codex"]);
 }

 static function samePath(a:String, b:String):Bool {
  var x = Path.normalize(a), y = Path.normalize(b);
  while (x.length > 1 && StringTools.endsWith(x, "/")) x = x.substr(0, x.length - 1);
  while (y.length > 1 && StringTools.endsWith(y, "/")) y = y.substr(0, y.length - 1);
  return Sys.systemName() == "Windows" ? x.toLowerCase() == y.toLowerCase() : x == y;
 }

 /** Codex conversations of the terminal UI in the folder begun since `started` and not taken. */
 public static function codexCandidates(cwd:String, started:Int, taken:Array<String>):Array<String> {
  var found:Array<String> = [];
  try {
   var home = codexHome();
   if (home == null) return found;
   var sessions = Path.join([home, "sessions"]);
   if (!FileSystem.exists(sessions)) return found;
   var name = ~/^rollout-(\d{4})-(\d{2})-(\d{2})T(\d{2})-(\d{2})-(\d{2})-([0-9A-Za-z-]{8,64})\.jsonl$/;
   var files = 0;
   // Folders and names carry the local time the conversation began, which haxeon's Date cannot give: they are read as
   // UTC, a day of folders is added on each side and names are only a first filter (15 h covers every time zone); the
   // UTC time in the record decides.
   var now = Std.int(Date.now().getTime() / 1000);
   var first = Math.floor(started / 86400) - 1, last = Math.floor(Math.min(now, started + CODEX_SCAN_DAYS * 86400) / 86400) + 1;
   for (day in first...last + 1) {
    var date = calendar(day * 86400);
    var folder = LongPath.of(Path.join([sessions, Std.string(date.year), pad(date.month), pad(date.day)]));
    if (!FileSystem.exists(folder) || !FileSystem.isDirectory(folder)) continue;
    for (file in FileSystem.readDirectory(folder)) {
     if (++files > CODEX_MAX_FILES) break;
     if (!name.match(file)) continue;
     var id = name.matched(7);
     if (taken.indexOf(id) >= 0) continue;
     var nominal = matchedTime(name);
     if (nominal < started - 15 * 3600) continue;
     var path = LongPath.of(Path.join([folder, file]));
     // A record not written since the terminal started was not begun since: not opened.
     var stat = FileSystem.metadata(path);
     if (stat == null || stat.modified < started - 2) continue;
     var meta:Dynamic = try codexMeta(path) catch (_:Dynamic) null;
     if (meta == null) continue;
     var originator = Reflect.field(meta, "originator");
     if (Std.isOfType(originator, String) && originator != "codex-tui" && originator != "codex_cli_rs") continue;
     var directory = Reflect.field(meta, "cwd");
     if (!Std.isOfType(directory, String) || !samePath(directory, cwd)) continue;
     var stamp = Reflect.field(meta, "timestamp");
     var time = Std.isOfType(stamp, String) ? utc(stamp) : null;
     if (time == null) time = nominal;
     if (time < started - 2) continue;
     var recorded = Reflect.field(meta, "id");
     if (Std.isOfType(recorded, String) && recorded != "") {
      if (taken.indexOf(recorded) >= 0) continue;
      id = recorded;
     }
     if (found.indexOf(id) < 0) found.push(id);
    }
   }
  } catch (_:Dynamic) {}
  return found;
 }

 /** Seconds since 1970 of a UTC calendar time (Howard Hinnant's days_from_civil). */
 public static function seconds(year:Int, month:Int, day:Int, hour:Int, minute:Int, second:Int):Int {
  var y = month <= 2 ? year - 1 : year;
  var era = Math.floor(y / 400);
  var yearOfEra = y - era * 400;
  var dayOfYear = Math.floor((153 * (month > 2 ? month - 3 : month + 9) + 2) / 5) + day - 1;
  var dayOfEra = yearOfEra * 365 + Math.floor(yearOfEra / 4) - Math.floor(yearOfEra / 100) + dayOfYear;
  var days = era * 146097 + dayOfEra - 719468;
  return days * 86400 + hour * 3600 + minute * 60 + second;
 }

 /** The UTC calendar time of seconds since 1970 (the inverse of `seconds`). */
 public static function calendar(value:Int):{year:Int, month:Int, day:Int, hour:Int, minute:Int, second:Int} {
  var days = Math.floor(value / 86400), rest = value - days * 86400;
  var z = days + 719468;
  var era = Math.floor(z / 146097);
  var dayOfEra = z - era * 146097;
  var yearOfEra = Math.floor((dayOfEra - Math.floor(dayOfEra / 1460) + Math.floor(dayOfEra / 36524) - Math.floor(dayOfEra / 146096)) / 365);
  var dayOfYear = dayOfEra - (365 * yearOfEra + Math.floor(yearOfEra / 4) - Math.floor(yearOfEra / 100));
  var monthIndex = Math.floor((5 * dayOfYear + 2) / 153);
  var day = dayOfYear - Math.floor((153 * monthIndex + 2) / 5) + 1;
  var month = monthIndex < 10 ? monthIndex + 3 : monthIndex - 9;
  return {year: yearOfEra + era * 400 + (month <= 2 ? 1 : 0), month: month, day: day, hour: Math.floor(rest / 3600),
   minute: Math.floor(rest % 3600 / 60), second: rest % 60};
 }

 /** `2026-10-29T02:45:46.642Z` as seconds since 1970; null for anything else. */
 public static function utc(text:String):Null<Int> {
  var r = ~/^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(\.\d+)?Z$/;
  if (!r.match(text)) return null;
  return matchedTime(r);
 }

 /**
  * Seconds since 1970 of the UTC calendar time in groups 1 to 6 of `r` (year, month, day, hour, minute, second, each
  * plain digits). Read as decimal: haxeon's `Std.parseInt` takes a leading 0 as octal, so "08" and "09" read as 0.
  */
 public static function matchedTime(r:EReg):Int
  return seconds(decimal(r.matched(1)), decimal(r.matched(2)), decimal(r.matched(3)), decimal(r.matched(4)), decimal(r.matched(5)),
   decimal(r.matched(6)));

 static function decimal(digits:String):Int {
  while (digits.length > 1 && StringTools.startsWith(digits, "0")) digits = digits.substr(1);
  return Std.parseInt(digits);
 }

 public static function pad(v:Int):String return v < 10 ? "0" + v : Std.string(v);

 /** The payload of the record's first line, `session_meta`. */
 static function codexMeta(path:String):Dynamic {
  var first:Dynamic = firstRecord(path);
  if (first == null || Reflect.field(first, "type") != "session_meta") return null;
  return Reflect.field(first, "payload");
 }
}
