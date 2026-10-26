package workspace.provider;

import workspace.service.WorkspaceAgentProtocol;

/** Bounded normalized conversation. Cursors are invalidated when old items are evicted. */
class PiConversation {
 final entries:Array<AgentActivityItem> = [];
 var revision = 0;
 public function new(?saved:Array<AgentActivityItem>) {
  if (saved != null) for (entry in saved) {
   put(entry.id, entry.turn, entry.kind, entry.title, entry.text, entry.detail, entry.state);
   entries[entries.length-1].truncated=entry.truncated;
  }
 }
 public function put(id:String, turn:String, kind:String, title:String, text:String, detail:String, state:String):Void {
  if (id.length > 512 || turn.length > 128) throw "Pi activity identity exceeds bound";
  var entry:Null<AgentActivityItem> = null;
  for (e in entries) if (e.id == id) entry = e;
  if (entry == null) {
   entry = {id:id, turn:turn, kind:kind, title:title, text:"", detail:"", state:state, truncated:false};
   entries.push(entry);
  }
  entry.title=title.substring(0,256); entry.kind=kind;
  entry.text = text.substring(0,4096); entry.detail = detail == "" ? entry.detail : detail.substring(0,2048); entry.state = state;
  entry.truncated = entry.truncated || title.length > 256 || text.length > 4096 || detail.length > 2048;
  if (entries.length > 128) { entries.shift(); revision++; }
 }
 public function delta(id:String, turn:String, text:String, kind:String = "agentMessage"):Void {
  var previous = "";
  for (entry in entries) if (entry.id == id) previous = entry.text;
  put(id,turn,kind,kind == "reasoning" ? "Reasoning" : "Pi",previous + text,"","inProgress");
 }
 public function finish(turn:String, state:String):Void {
  for (entry in entries) if (entry.turn == turn && entry.state == "inProgress") entry.state = state;
 }
 public function offset(cursor:String):Null<Int> {
  var parts = cursor.split(":");
  if (parts.length != 2 || parts[0] != Std.string(revision)) return null;
  var n = Std.parseInt(parts[1]);
  return n != null && n >= 0 && n <= entries.length && Std.string(n) == parts[1] ? n : null;
 }
 public function page(?before:Int):Array<AgentActivityItem> {
  var end = before == null ? entries.length : before;
  return entries.slice(Std.int(Math.max(0,end-8)),end);
 }
 public function next(?before:Int):Null<String> {
  var end = before == null ? entries.length : before;
  return end > 8 ? revision + ":" + (end-8) : null;
 }
 /** Keep the resource payload below the existing 16 KiB storage bound. */
 public function snapshot():Array<AgentActivityItem> {
  return [for (e in entries.slice(Std.int(Math.max(0,entries.length-6)))) {
   id:e.id,turn:e.turn,kind:e.kind,title:e.title,text:e.text.substring(0,384),detail:e.detail.substring(0,128),state:e.state,
   truncated:e.truncated || e.text.length > 384 || e.detail.length > 128
  }];
 }
}
