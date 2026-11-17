package workspace.provider;

import haxe.Json;
import haxe.io.Path;
import sys.FileSystem;
import workspace.service.WorkspaceAgentProtocol;
import workspace.provider.AgentTranscript.str;

/**
 * Claude Code's own record of a conversation: `<config>/projects/<folder slug>/<session id>.jsonl`, one JSON value per
 * line (`AgentTranscript`). Whether it exists says if `--resume` can work. Read only; never written here.
 */
class ClaudeTranscript {
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

 /** The conversation in `path` as activity items with whole texts (`AgentTranscript.read`). */
 public static function read(path:String, limit:Int):Null<{items:Array<AgentActivityItem>, omitted:Bool}>
  return AgentTranscript.read(path, limit, function(transcript, value) {
   var type = str(value, "type");
   if (type != "user" && type != "assistant") return;
   if (Reflect.field(value, "isSidechain") == true || Reflect.field(value, "isMeta") == true) return;
   var message = Reflect.field(value, "message"), content:Dynamic = message == null ? null : Reflect.field(message, "content");
   var uuid = str(value, "uuid");
   var said = AgentTranscript.text(content);
   if (Std.isOfType(content, Array)) for (part in (cast content:Array<Dynamic>)) switch (str(part, "type")) {
    case "tool_use":
     var tool = transcript.entry(str(part, "id"), "tool", str(part, "name"), "inProgress");
     if (tool != null) tool.detail = Json.stringify(Reflect.field(part, "input"));
    case "tool_result":
     var result:Dynamic = Reflect.field(part, "content");
     var tool = transcript.entry(str(part, "tool_use_id"), "tool", "Tool", "completed");
     if (tool != null) {
      tool.text = Std.isOfType(result, String) ? result : Json.stringify(result);
      tool.state = Reflect.field(part, "is_error") == true ? "failed" : "completed";
     }
    default:
   }
   // A prompt may be pictures alone.
   if (said.text == "" && !(said.pictures && type == "user")) return;
   if (type == "user") {
    if (uuid == "" || uuid.length > 100) return;
    transcript.turn = "h-" + uuid;
    var prompt = transcript.entry(uuid, "userMessage", "You", "completed");
    if (prompt != null) prompt.text = said.text;
   } else {
    var id = str(message, "id");
    if (id == "" || id.length > 128) id = uuid;
    var reply = transcript.entry(id, "agentMessage", "Claude", "completed");
    if (reply != null && reply.text.length <= AgentContentCache.MAX_MESSAGE) reply.text += said.text;
   }
  });
}
