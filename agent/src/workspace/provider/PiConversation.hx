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
   entries[entries.length-1].files=retainedFiles(entry,2048);
  }
 }
 /** Preserve the original tool record; expose a real edit patch as its own activity. */
 public function toolPatch(id:String, turn:String, output:Dynamic):Void {
  var tool:Null<AgentActivityItem> = null;
  for (entry in entries) if (entry.id == id && entry.turn == turn) tool = entry;
  if (tool == null || tool.title != "edit" || tool.state != "completed") return;
  var details = output == null ? null : Reflect.field(output,"details");
  var raw:Dynamic = details == null ? null : Reflect.field(details,"patch");
  if (!Std.isOfType(raw,String) || raw == "") return;
  var patch:String = raw, hasHunk = false;
  // Do not reinterpret Pi's numbered display-oriented `diff` as a unified patch.
  for (part in workspace.client.SessionDiff.parse(patch.substring(0,2048)))
   for (line in part.lines) if (line.kind == "hunk") hasHunk = true;
  if (!hasHunk || id.length > 506) return;
  var path:Null<String> = null;
  try {
   var args = haxe.Json.parse(tool.detail), value:Dynamic = Reflect.field(args,"path");
   if (Std.isOfType(value,String) && value.length <= 512 && workspace.client.SessionLinkTarget.parse(value) != null) path = value;
  } catch (_:Dynamic) {}
  var patchId = id + ":patch";
  put(patchId,turn,"fileChange","Edit file","",patch,"completed");
  for (entry in entries) if (entry.id == patchId && entry.turn == turn) {
   entry.files = path == null ? null : [{path:path,kind:"update",offset:0,length:entry.detail.length,truncated:entry.truncated}];
  }
 }
 static function retainedFiles(entry:AgentActivityItem, limit:Int):Null<Array<AgentFileChange>> {
  if (entry.files == null) return null;
  var result:Array<AgentFileChange> = [];
  for (file in entry.files) {
   if (result.length >= 1 || file.offset < 0 || file.length < 0 || file.offset > entry.detail.length
     || file.length > entry.detail.length - file.offset || file.path.length > 512) continue;
   var offset = Std.int(Math.min(limit,file.offset));
   var length = Std.int(Math.max(0,Math.min(file.length,limit-offset)));
   result.push({path:file.path,kind:file.kind,offset:offset,length:length,truncated:file.truncated || length != file.length});
  }
  return result.length == 0 ? null : result;
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
  var saved:Array<AgentActivityItem> = [for (e in entries.slice(Std.int(Math.max(0,entries.length-6)))) {
   id:e.id,turn:e.turn,kind:e.kind,title:e.title,text:e.text.substring(0,384),detail:e.detail.substring(0,128),state:e.state,
   truncated:e.truncated || e.text.length > 384 || e.detail.length > 128,files:retainedFiles(e,128)
  }];
  while (saved.length > 0 && haxeon.wire.MessagePack.encode(saved).length > 6144) saved.shift();
  return saved;
 }
}
