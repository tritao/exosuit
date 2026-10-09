package workspace.provider;

import haxe.Json;
import workspace.service.WorkspaceAgentProtocol;

/** Stable turn/item identity across live events and persisted history. */
class CodexConversation {
  public static inline final PAGE_ITEMS = 8;
  var entries:Array<AgentActivityItem> = [];
  var historyRevision:Int = 0;

  public function new() {
  }

  public function items():Array<AgentActivityItem> return entries.copy();
  public function cursorOffset(cursor:String):Null<Int> {
    var parts = cursor.split(":");
    if (parts.length != 2 || parts[0] != Std.string(historyRevision)) return null;
    var offset = Std.parseInt(parts[1]);
    return offset != null && offset >= 0 && offset <= entries.length && Std.string(offset) == parts[1] ? offset : null;
  }
  public function page(?before:Int):Array<AgentActivityItem> {
    var end = before == null ? entries.length : before;
    return entries.slice(Std.int(Math.max(0, end - PAGE_ITEMS)), end);
  }
  public function next(?before:Int):Null<String> {
    var end = before == null ? entries.length : before;
    return end > PAGE_ITEMS ? historyRevision + ":" + (end - PAGE_ITEMS) : null;
  }
  public function finish(turn:String, state:String):Void {
    for (entry in entries)
      if (entry.turn == turn && entry.state == "inProgress") entry.state = state;
  }
  public function historyBaseline():Array<String> return [for (entry in entries) entry.turn + ":" + entry.id];

  static function string(value:Dynamic, field:String):String {
    if (value == null) return "";
    var result = Reflect.field(value, field);
    return Std.isOfType(result, String) ? result : "";
  }

  static function clipped(value:String, limit:Int):String {
    if (value.length <= limit) return value;
    // Do not split a UTF-16 surrogate pair at the retained boundary.
    var end = limit;
    if (end > 0 && value.charCodeAt(end - 1) >= 0xD800 && value.charCodeAt(end - 1) <= 0xDBFF) end--;
    return value.substring(0, end);
  }

  function find(turn:String, id:String):Null<AgentActivityItem> {
    for (entry in entries) if (entry.turn == turn && entry.id == id) return entry;
    return null;
  }

  function bounded(entry:AgentActivityItem):Void {
    var title = clipped(entry.title, 256), text = clipped(entry.text, 4096), detail = clipped(entry.detail, 2048);
    entry.truncated = entry.truncated || title != entry.title || text != entry.text || detail != entry.detail;
    entry.title = title;
    entry.text = text;
    entry.detail = detail;
  }

  public function put(turn:String, item:Dynamic, completed:Bool):Void {
    var id = string(item, "id"), kind = string(item, "type");
    if (id == "" || id.length > 128 || turn.length > 128 || kind == "" || kind.length > 64) return;
    var existing = find(turn, id);
    // A delayed started event cannot replace a finished item.
    if (existing != null && existing.state != "inProgress" && !completed) return;
    var entry:AgentActivityItem = {
      id: id,
      turn: turn,
      kind: kind,
      title: "Activity",
      text: "",
      detail: "",
      state: completed ? "completed" : "inProgress",
      truncated: false
    };
    switch kind {
      case "agentMessage":
        entry.title = "Codex";
        entry.text = string(item, "text");
      case "userMessage":
        entry.title = "You";
        var content:Array<Dynamic> = Reflect.field(item, "content");
        if (content != null) for (part in content) {
          var text = string(part, "text");
          entry.text += (entry.text == "" ? "" : "\n") + (text == "" ? "[" + string(part, "type") + "]" : text);
          if (entry.text.length > 4096) {
            entry.truncated = true;
            break;
          }
        }
      case "reasoning":
        entry.title = "Reasoning";
        var summary:Array<String> = Reflect.field(item, "summary");
        if (summary != null) for (text in summary) {
          entry.text += (entry.text == "" ? "" : "\n") + text;
          if (entry.text.length > 4096) {
            entry.truncated = true;
            break;
          }
        }
      case "commandExecution":
        entry.title = "Command";
        entry.text = string(item, "command");
        entry.detail = string(item, "cwd");
        var exit = Reflect.field(item, "exitCode");
        if (exit != null) entry.detail += "\nExit code: " + Std.string(exit);
        entry.detail += "\n" + string(item, "aggregatedOutput");
      case "fileChange":
        entry.title = "File changes";
        var changes:Array<Dynamic> = Reflect.field(item, "changes");
        if (changes != null) for (change in changes) {
          entry.text += (entry.text == "" ? "" : "\n") + string(Reflect.field(change, "kind"), "type") + " " + string(
            change,
            "path"
          );
          entry.detail += string(change, "diff") + "\n";
          if (entry.text.length > 4096 || entry.detail.length > 2048) {
            entry.truncated = true;
            break;
          }
        }
      case "mcpToolCall":
        entry.title = "Tool";
        entry.text = string(item, "server") + " / " + string(item, "tool");
        entry.detail = Json.stringify(Reflect.field(item, "result"));
      case _:
        entry.title = "Additional activity";
        entry.text = kind;
        entry.detail = Json.stringify(item);
    }
    var state = string(item, "status");
    if (state != "") entry.state = clipped(state, 64);
    bounded(entry);
    if (existing == null) entries.push(entry);
    else entries[entries.indexOf(existing)] = entry;
  }

  public function delta(turn:String, id:String, kind:String, text:String):Void {
    var entry = find(turn, id);
    if (entry == null) {
      put(turn, {id: id, type: kind}, false);
      entry = find(turn, id);
    }
    if (entry == null || entry.state != "inProgress") return;
    if (kind == "commandExecution") entry.detail += text;
    else entry.text += text;
    bounded(entry);
  }

  public function history(data:Array<Dynamic>, ?activeTurn:String, ?baseline:Array<String>):Void {
    historyRevision++;
    var previous = entries;
    if (baseline == null) baseline = historyBaseline();
    entries = [];
    // The page is authoritative for ordering; preserve newer live updates.
    var count = data.length;
    for (index in 0...count) {
      var entry = data[count - 1 - index];
      var turn = string(entry, "turnId");
      var item = Reflect.field(entry, "item"), id = string(item, "id");
      var completed = turn != activeTurn || Reflect.field(entry, "completedAtMs") != null;
      var retained:Null<AgentActivityItem> = null;
      for (old in previous) if (old.turn == turn && old.id == id) retained = old;
      if (retained != null && (!completed || baseline.indexOf(turn + ":" + id) < 0)) entries.push(retained);
      else put(turn, item, completed);
    }
    for (old in previous) if (find(old.turn,
      old.id) == null && (baseline.indexOf(old.turn + ":" + old.id) < 0 || old.state == "inProgress")) entries.push(old);
  }
}
