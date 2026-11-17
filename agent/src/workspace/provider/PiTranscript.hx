package workspace.provider;

import haxe.Json;
import workspace.service.WorkspaceAgentProtocol;
import workspace.provider.AgentTranscript.str;

/**
 * Pi's own record of a conversation: its session file (the session's `thread`), one JSON value per line
 * (`AgentTranscript`). The first is the `session` header; each `message` entry holds one message of the agent loop
 * (`role` user, assistant or toolResult). Read only; never written here.
 */
class PiTranscript {
 /** The conversation in `path` as activity items with whole texts (`AgentTranscript.read`). */
 public static function read(path:String, limit:Int):Null<{items:Array<AgentActivityItem>, omitted:Bool}>
  return AgentTranscript.read(path, limit, function(transcript, value) {
   if (str(value, "type") != "message") return;
   var id = str(value, "id");
   var message:Dynamic = Reflect.field(value, "message");
   if (message == null || id == "" || id.length > 100) return;
   var content:Dynamic = Reflect.field(message, "content");
   switch (str(message, "role")) {
    case "user":
     var said = AgentTranscript.text(content);
     // A prompt may be pictures alone.
     if (said.text == "" && !said.pictures) return;
     transcript.turn = "h-" + id;
     var prompt = transcript.entry(id, "userMessage", "You", "completed");
     if (prompt != null) prompt.text = said.text;
    case "assistant":
     // The reply's text comes before the tools it calls, as Pi shows them.
     var text = AgentTranscript.text(content).text;
     if (text != "") {
      var reply = transcript.entry(id, "agentMessage", "Pi", "completed");
      if (reply != null && reply.text.length <= AgentContentCache.MAX_MESSAGE) reply.text += text;
     }
     if (Std.isOfType(content, Array)) for (part in (cast content:Array<Dynamic>)) if (str(part, "type") == "toolCall") {
      var tool = transcript.entry(str(part, "id"), "tool", str(part, "name"), "inProgress");
      if (tool != null) tool.detail = Json.stringify(Reflect.field(part, "arguments"));
     }
    case "toolResult":
     var tool = transcript.entry(str(message, "toolCallId"), "tool", str(message, "toolName") == "" ? "Tool" : str(message, "toolName"), "completed");
     if (tool != null) {
      tool.text = AgentTranscript.text(content).text;
      tool.state = Reflect.field(message, "isError") == true ? "failed" : "completed";
     }
    default:
   }
  });
}
