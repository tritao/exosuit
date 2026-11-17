package workspace.provider;

import haxe.Json;
import haxe.io.Bytes;
import sys.FileSystem;
import workspace.service.WorkspaceAgentProtocol;

/**
 * A provider's own record of a conversation (Claude's `<id>.jsonl`, Pi's session file), one JSON value per line, read
 * into activity items with whole texts. The service keeps only a short preview of a session, so after a restart this
 * file is where the whole conversation comes from. The provider's reader (`ClaudeTranscript`, `PiTranscript`) turns
 * each line into items through `entry`; a user's prompt starts a turn (`turn`). Read only; never written here.
 */
class AgentTranscript {
 /** Only the end of a larger file is taken; what came before is reported as omitted. */
 public static inline final MAX_READ_BYTES:Int = 8 * 1024 * 1024;
 /** A larger file is not read at all (there is no partial read here); the session then shows the service's preview. */
 public static inline final MAX_FILE_BYTES:Int = 64 * 1024 * 1024;
 static inline final MAX_LINE_BYTES:Int = 1024 * 1024;

 /** The turn items are filed under: "history" until the first prompt. */
 public var turn:String = "history";
 final items:Array<AgentActivityItem> = [];
 final byKey:Map<String, AgentActivityItem> = [];

 function new() {}

 /** The item `id` of the current turn, made with `kind`, `title` and `state` when new; null for an unusable id. */
 public function entry(id:String, kind:String, title:String, state:String):Null<AgentActivityItem> {
  if (id == "" || id.length > 128) return null;
  var key = turn + "\n" + id;
  var found = byKey.get(key);
  if (found == null) {
   found = {id:id, turn:turn, kind:kind, title:title.substring(0, 256), text:"", detail:"", state:state, truncated:false};
   byKey.set(key, found); items.push(found);
  }
  return found;
 }

 /**
  * The conversation in `path`, oldest first, at most `limit` items (the newest are kept), each line given to `line`.
  * Null when the file cannot be read.
  */
 public static function read(path:String, limit:Int, line:(AgentTranscript, Dynamic) -> Void):Null<{items:Array<AgentActivityItem>, omitted:Bool}> {
  var bytes:Bytes;
  var omitted = false, from = 0;
  try {
   path = LongPath.of(path);
   var metadata = FileSystem.metadata(path);
   if (metadata == null || metadata.size > MAX_FILE_BYTES) return null;
   bytes = sys.io.File.getBytes(path);
   if (bytes.length > MAX_READ_BYTES) { from = bytes.length - MAX_READ_BYTES; omitted = true; }
  } catch (_:Dynamic) return null;
  var transcript = new AgentTranscript();
  var start = from, first = omitted;
  for (index in from...bytes.length + 1) {
   if (index < bytes.length && bytes.get(index) != 10) continue;
   var length = index - start;
   // The first line of a file read from the middle is a fragment.
   if (!first && length > 1 && length <= MAX_LINE_BYTES) {
    try line(transcript, Json.parse(bytes.getString(start, length))) catch (_:Dynamic) {}
   } else if (length > MAX_LINE_BYTES) omitted = true;
   first = false;
   start = index + 1;
  }
  var items = transcript.items;
  // A tool that never reported back did not outlive the process that ran it.
  for (item in items) if (item.kind == "tool" && item.state == "inProgress") item.state = "interrupted";
  if (items.length > limit) { items = items.slice(items.length - limit); omitted = true; }
  return {items:items, omitted:omitted};
 }

 /** The text parts of a message's content (a string, or a list of parts), and whether it holds pictures. */
 public static function text(content:Dynamic):{text:String, pictures:Bool} {
  var text = "", pictures = false;
  if (Std.isOfType(content, String)) text = content;
  else if (Std.isOfType(content, Array)) for (part in (cast content:Array<Dynamic>)) switch (str(part, "type")) {
   case "text": if (text.length <= AgentContentCache.MAX_MESSAGE) text += str(part, "text");
   case "image": pictures = true;
   default:
  }
  return {text:text, pictures:pictures};
 }

 public static function str(v:Dynamic, key:String):String {
  var x = v == null ? null : Reflect.field(v, key);
  return Std.isOfType(x, String) ? x : "";
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
