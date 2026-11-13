package workspace.provider;

import haxe.Json;
import haxe.io.Bytes;
import sys.FileSystem;
import workspace.service.WorkspaceAgentProtocol;

/**
 * Pi's own record of a conversation: its session file (the session's `thread`), one JSON value per line. The first is
 * the `session` header; each `message` entry holds one message of the agent loop (`role` user, assistant or
 * toolResult). The service keeps only a short preview of a session, so after a restart this file is where the whole
 * conversation comes from, as `ClaudeTranscript` does for Claude. Read only; never written here.
 */
class PiTranscript {
 static inline final MAX_LINE_BYTES:Int = 1024 * 1024;

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
   if (metadata == null || metadata.size > ClaudeTranscript.MAX_FILE_BYTES) return null;
   bytes = sys.io.File.getBytes(path);
   if (bytes.length > ClaudeTranscript.MAX_READ_BYTES) { from = bytes.length - ClaudeTranscript.MAX_READ_BYTES; omitted = true; }
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
  function textOf(content:Dynamic):{text:String, pictures:Bool} {
   var text = "", pictures = false;
   if (Std.isOfType(content, String)) text = content;
   else if (Std.isOfType(content, Array)) for (part in (cast content:Array<Dynamic>)) switch (str(part, "type")) {
    case "text": if (text.length <= AgentContentCache.MAX_MESSAGE) text += str(part, "text");
    case "image": pictures = true;
    default:
   }
   return {text:text, pictures:pictures};
  }
  function line(value:Dynamic):Void {
   if (str(value, "type") != "message") return;
   var id = str(value, "id");
   var message:Dynamic = Reflect.field(value, "message");
   if (message == null || id == "" || id.length > 100) return;
   var content:Dynamic = Reflect.field(message, "content");
   switch (str(message, "role")) {
    case "user":
     var said = textOf(content);
     // A prompt may be pictures alone.
     if (said.text == "" && !said.pictures) return;
     turn = "h-" + id;
     var prompt = entry(id, "userMessage", "You", "completed");
     if (prompt != null) prompt.text = said.text;
    case "assistant":
     // The reply's text comes before the tools it calls, as Pi shows them.
     var text = textOf(content).text;
     if (text != "") {
      var reply = entry(id, "agentMessage", "Pi", "completed");
      if (reply != null && reply.text.length <= AgentContentCache.MAX_MESSAGE) reply.text += text;
     }
     if (Std.isOfType(content, Array)) for (part in (cast content:Array<Dynamic>)) if (str(part, "type") == "toolCall") {
      var tool = entry(str(part, "id"), "tool", str(part, "name"), "inProgress");
      if (tool != null) tool.detail = Json.stringify(Reflect.field(part, "arguments"));
     }
    case "toolResult":
     var tool = entry(str(message, "toolCallId"), "tool", str(message, "toolName") == "" ? "Tool" : str(message, "toolName"), "completed");
     if (tool != null) {
      tool.text = textOf(content).text;
      tool.state = Reflect.field(message, "isError") == true ? "failed" : "completed";
     }
    default:
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

 static function str(v:Dynamic, key:String):String {
  var x = v == null ? null : Reflect.field(v, key);
  return Std.isOfType(x, String) ? x : "";
 }
}
