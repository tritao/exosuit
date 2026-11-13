package workspace.provider;

import haxe.Json;
import haxe.io.Bytes;
import haxe.io.Path;
import sys.FileSystem;
import workspace.service.WorkspaceAgentProtocol;

/**
 * Claude Code's own record of a conversation: `<config>/projects/<folder slug>/<session id>.jsonl`, one JSON value per
 * line. The service keeps only a short preview of a session, so after a restart this file is where the whole
 * conversation comes from, and whether it exists says if `--resume` can work. Read only; never written here.
 */
class ClaudeTranscript {
 /** Only the end of a larger file is taken; what came before is reported as omitted. */
 public static inline final MAX_READ_BYTES:Int = 8 * 1024 * 1024;
 /** A larger file is not read at all (there is no partial read here); the session then shows the service's preview. */
 public static inline final MAX_FILE_BYTES:Int = 64 * 1024 * 1024;
 static inline final MAX_LINE_BYTES:Int = 1024 * 1024;

 /** Claude Code's configuration folder: `CLAUDE_CONFIG_DIR`, else `.claude` in the user's home. */
 public static function configDirectory():Null<String> {
  var configured = Sys.getEnv("CLAUDE_CONFIG_DIR");
  if (configured != null && StringTools.trim(configured) != "") return configured;
  var home = Sys.systemName() == "Windows" ? Sys.getEnv("USERPROFILE") : Sys.getEnv("HOME");
  return home == null || home == "" ? null : Path.join([home, ".claude"]);
 }

 static function slug(cwd:String):String return ~/[^A-Za-z0-9]/g.replace(cwd, "-");

 /** The transcript of `thread`, looked for under the folder Claude derives from `cwd`, then under every project. */
 public static function locate(thread:String, cwd:String, ?config:String):Null<String> {
  try {
   if (config == null) config = configDirectory();
   if (config == null || thread == null || thread == "") return null;
   var projects = Path.join([config, "projects"]);
   if (!FileSystem.exists(projects) || !FileSystem.isDirectory(projects)) return null;
   var direct = LongPath.of(Path.join([projects, slug(cwd), thread + ".jsonl"]));
   if (FileSystem.exists(direct)) return direct;
   var checked = 0;
   for (name in FileSystem.readDirectory(projects)) {
    if (++checked > 4096) break;
    var candidate = LongPath.of(Path.join([projects, name, thread + ".jsonl"]));
    if (FileSystem.exists(candidate)) return candidate;
   }
  } catch (_:Dynamic) {}
  return null;
 }

 /** Whether Claude keeps any conversation for `cwd` (its folder of records exists and holds one). */
 public static function hasConversations(cwd:String, ?config:String):Bool {
  try {
   if (config == null) config = configDirectory();
   if (config == null) return false;
   var folder = LongPath.of(Path.join([config, "projects", slug(cwd)]));
   if (!FileSystem.exists(folder) || !FileSystem.isDirectory(folder)) return false;
   for (name in FileSystem.readDirectory(folder)) if (StringTools.endsWith(name, ".jsonl")) return true;
  } catch (_:Dynamic) {}
  return false;
 }

 /**
  * Whether any conversation of the same folder (`cwd` as Claude wrote it) other than `thread` and those kept elsewhere
  * (`taken`) was written since `thread`'s record was last written (`SLACK` seconds of overlap allowed). Then the
  * terminal of `thread` may have gone on under a new id (`/clear`), or someone else talked to Claude there: which one is
  * not known from the files, so the caller lets the user pick instead of guessing. True when it cannot be told.
  */
 public static function othersWrittenSince(thread:String, cwd:String, taken:Array<String>, ?config:String):Bool {
  try {
   if (config == null) config = configDirectory();
   if (config == null || thread == null || thread == "") return true;
   var folder = LongPath.of(Path.join([config, "projects", slug(cwd)]));
   if (!FileSystem.exists(folder) || !FileSystem.isDirectory(folder)) return false;
   var own = FileSystem.metadata(LongPath.of(Path.join([folder, thread + ".jsonl"])));
   if (own == null) return true;
   var names = FileSystem.readDirectory(folder);
   if (names.length > MAX_FOLDER_FILES) return true;
   for (name in names) {
    if (!StringTools.endsWith(name, ".jsonl")) continue;
    var id = name.substr(0, name.length - 6);
    if (id == thread || taken.indexOf(id) >= 0) continue;
    var path = LongPath.of(Path.join([folder, name]));
    var metadata = FileSystem.metadata(path);
    if (metadata == null || metadata.modified < own.modified - SLACK) continue;
    var head = recordHead(path);
    if (head == null || head.cwd != null && !sameFolder(head.cwd, cwd)) continue;
    return true;
   }
   return false;
  } catch (_:Dynamic) {}
  return true;
 }

 static inline final SLACK:Int = 5;
 static inline final MAX_FOLDER_FILES:Int = 4096;

 static function sameFolder(a:String, b:String):Bool {
  var x = Path.normalize(a), y = Path.normalize(b);
  while (x.length > 1 && StringTools.endsWith(x, "/")) x = x.substr(0, x.length - 1);
  while (y.length > 1 && StringTools.endsWith(y, "/")) y = y.substr(0, y.length - 1);
  return Sys.systemName() == "Windows" ? x.toLowerCase() == y.toLowerCase() : x == y;
 }

 /** The first `timestamp` (Unix seconds) and `cwd` among a record's first whole lines (within its first 64 KiB). */
 static function recordHead(path:String):Null<{time:Null<Int>, cwd:Null<String>}> {
  var bytes = sys.io.File.getBytes(path);
  // Whole lines only, so no character is cut.
  var length = 0;
  for (index in 0...(bytes.length < 65536 ? bytes.length : 65536)) if (bytes.get(index) == 10) length = index;
  var time:Null<Int> = null, folder:Null<String> = null;
  for (line in bytes.getString(0, length).split(String.fromCharCode(10))) {
   var value:Dynamic = try Json.parse(line) catch (_:Dynamic) null;
   if (value == null) continue;
   if (time == null) time = utc(str(value, "timestamp"));
   if (folder == null && str(value, "cwd") != "") folder = str(value, "cwd");
   if (time != null && folder != null) break;
  }
  return {time: time, cwd: folder};
 }

 /** `2026-10-29T02:45:46.642Z` as Unix seconds; null for anything else. */
 static function utc(text:String):Null<Int> {
  var r = ~/^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(\.\d+)?Z$/;
  if (!r.match(text)) return null;
  return workspace.runtime.AgentTerminalResume.seconds(Std.parseInt(r.matched(1)), Std.parseInt(r.matched(2)),
   Std.parseInt(r.matched(3)), Std.parseInt(r.matched(4)), Std.parseInt(r.matched(5)), Std.parseInt(r.matched(6)));
 }

 static function str(v:Dynamic, key:String):String {
  var x = v == null ? null : Reflect.field(v, key);
  return Std.isOfType(x, String) ? x : "";
 }

 /**
  * The conversation in `path` as activity items with whole texts, oldest first, at most `limit` (the newest are kept).
  * Each prompt of the user starts a turn. Null when the file cannot be read.
  */
 public static function read(path:String, limit:Int):Null<{items:Array<AgentActivityItem>, omitted:Bool}> {
  var bytes:Bytes;
  var omitted = false, from = 0;
  try {
   path = LongPath.of(path);
   var metadata = FileSystem.metadata(path);
   if (metadata == null || metadata.size > MAX_FILE_BYTES) return null;
   bytes = sys.io.File.getBytes(path);
   if (bytes.length > MAX_READ_BYTES) { from = bytes.length - MAX_READ_BYTES; omitted = true; }
  } catch (_:Dynamic) return null;
  var items:Array<AgentActivityItem> = [];
  var byKey:Map<String, AgentActivityItem> = [];
  var turn = "history";
  function entry(id:String, kind:String, title:String, state:String):Null<AgentActivityItem> {
   if (id == "" || id.length > 128) return null;
   var key = turn + "\n" + id;
   var found = byKey.get(key);
   if (found == null) {
    found = {id:id, turn:turn, kind:kind, title:title.substring(0, 256), text:"", detail:"", state:state, truncated:false};
    byKey.set(key, found); items.push(found);
   }
   return found;
  }
  function line(value:Dynamic):Void {
   var type = str(value, "type");
   if (type != "user" && type != "assistant") return;
   if (Reflect.field(value, "isSidechain") == true || Reflect.field(value, "isMeta") == true) return;
   var message = Reflect.field(value, "message"), content:Dynamic = message == null ? null : Reflect.field(message, "content");
   var uuid = str(value, "uuid");
   var text = "", pictures = false;
   if (Std.isOfType(content, String)) text = content;
   else if (Std.isOfType(content, Array)) for (part in (cast content:Array<Dynamic>)) switch (str(part, "type")) {
    case "text": if (text.length <= AgentContentCache.MAX_MESSAGE) text += str(part, "text");
    case "image": pictures = true;
    case "tool_use":
     var tool = entry(str(part, "id"), "tool", str(part, "name"), "inProgress");
     if (tool != null) tool.detail = Json.stringify(Reflect.field(part, "input"));
    case "tool_result":
     var result:Dynamic = Reflect.field(part, "content");
     var tool = entry(str(part, "tool_use_id"), "tool", "Tool", "completed");
     if (tool != null) {
      tool.text = Std.isOfType(result, String) ? result : Json.stringify(result);
      tool.state = Reflect.field(part, "is_error") == true ? "failed" : "completed";
     }
    default:
   }
   // A prompt may be pictures alone.
   if (text == "" && !(pictures && type == "user")) return;
   if (type == "user") {
    if (uuid == "" || uuid.length > 100) return;
    turn = "h-" + uuid;
    var prompt = entry(uuid, "userMessage", "You", "completed");
    if (prompt != null) prompt.text = text;
   } else {
    var id = str(message, "id");
    if (id == "" || id.length > 128) id = uuid;
    var reply = entry(id, "agentMessage", "Claude", "completed");
    if (reply != null && reply.text.length <= AgentContentCache.MAX_MESSAGE) reply.text += text;
   }
  }
  var start = from, first = omitted;
  for (index in from...bytes.length + 1) {
   if (index < bytes.length && bytes.get(index) != 10) continue;
   var length = index - start;
   // The first line of a file read from the middle is a fragment.
   if (!first && length > 1 && length <= MAX_LINE_BYTES) {
    try line(Json.parse(bytes.getString(start, length))) catch (_:Dynamic) {}
   } else if (length > MAX_LINE_BYTES) omitted = true;
   first = false;
   start = index + 1;
  }
  // A tool that never reported back did not outlive the process that ran it.
  for (item in items) if (item.kind == "tool" && item.state == "inProgress") item.state = "interrupted";
  if (items.length > limit) { items = items.slice(items.length - limit); omitted = true; }
  return {items:items, omitted:omitted};
 }

 /**
  * Joins the transcript with the service's own preview of the newest items. A prompt both know keeps the service's turn
  * and item ids (sent images are filed under them); a prompt only the service knows, one whose delivery is uncertain,
  * is kept at the end.
  */
 public static function merge(history:Array<AgentActivityItem>, preview:Null<Array<AgentActivityItem>>):Array<AgentActivityItem> {
  if (preview == null) return history;
  var taken:Map<Int, Bool> = [];
  var missing:Array<AgentActivityItem> = [];
  var index = preview.length;
  while (index > 0) {
   var saved = preview[--index];
   if (saved.kind != "userMessage") continue;
   var match = -1, at = history.length;
   while (at > 0) {
    var candidate = history[--at];
    if (candidate.kind != "userMessage" || taken.exists(at)) continue;
    if (saved.truncated ? StringTools.startsWith(candidate.text, saved.text) : candidate.text == saved.text) { match = at; break; }
   }
   if (match < 0) { missing.unshift(saved); continue; }
   taken.set(match, true);
   var prompt = history[match], previous = prompt.turn;
   for (item in history) if (item.turn == previous) item.turn = saved.turn;
   prompt.id = saved.id; prompt.images = saved.images;
  }
  return history.concat(missing);
 }
}
