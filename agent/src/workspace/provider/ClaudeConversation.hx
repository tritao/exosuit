package workspace.provider;

import workspace.service.WorkspaceAgentProtocol;

/** Bounded normalized conversation. Cursors are invalidated when old items are evicted. */
class ClaudeConversation {
 static var nextCacheId:Int = 0;
 final cacheId:Int;
 final archive:Null<AgentResponseArchive>;
 var restoring=true;
 public function archiveError():Null<String> return archive==null ? null : archive.problem;
 final entries:Array<AgentActivityItem> = [];
 var revision = 0;
 final incarnation:String = AgentHistoryEpoch.create();
 var omitted:Bool = false;
 public function epoch():String return incarnation + "-" + revision;
 public function hasOmitted():Bool return omitted;
 function cacheKey(turn:String,id:String):String return "claude-"+cacheId+":"+turn.length+":"+turn+id;
 public function content(turn:String,id:String,token:String,offset:Int):Null<AgentContentChunk> {
  for (entry in entries) if (entry.turn == turn && entry.id == id && entry.kind == "agentMessage" && entry.contentToken == token) {
   var key=cacheKey(turn,id),chunk=AgentContentCache.chunk(key,token,offset);
   if(chunk==null && archive!=null && archive.restore(key,entry,token)!=null) return AgentContentCache.chunk(key,token,offset);
   return chunk;
  }
  return null;
 }
 public function new(?saved:Array<AgentActivityItem>,?archive:AgentResponseArchive) {
  cacheId=++nextCacheId;this.archive=archive;
  if (saved != null) for (entry in saved) {
   put(entry.id, entry.turn, entry.kind, entry.title, entry.text, entry.detail, entry.state, !entry.truncated);
   for (restored in entries) if (restored.id == entry.id && restored.turn == entry.turn) {
    restored.truncated = entry.truncated;restored.contentDigest=entry.contentDigest;
    if(entry.truncated && archive!=null) restored.contentToken=archive.restore(cacheKey(entry.turn,entry.id),restored);
   }
  }
  restoring=false;
 }
 public function put(id:String, turn:String, kind:String, title:String, text:String, detail:String, state:String, retainContent:Bool = true):Void {
  if (id == null || id.length == 0 || id.length > 128 || turn.length > 128) return;
  title = title.substring(0,256);
  var entry:Null<AgentActivityItem> = null;
  for (e in entries) if (e.id == id && e.turn == turn) entry = e;
  if (entry == null) {
   entry = {id:id, turn:turn, kind:kind, title:title, text:"", detail:"", state:state, truncated:false};
   entries.push(entry);
  }
  if(kind=="agentMessage" && (retainContent || state=="inProgress")) entry.contentDigest=null;
  if (kind == "agentMessage" && retainContent) entry.contentToken = AgentContentCache.replace(cacheKey(turn,id),text);
  entry.text = text.substring(0,4096);
  // Tool results carry no input detail; keep the arguments received at tool_use.
  entry.detail = detail == "" ? entry.detail : detail.substring(0,2048); entry.state = state;
  entry.truncated = entry.truncated || text.length > 4096 || detail.length > 2048;
  if(!restoring && archive!=null) archive.capture(cacheKey(turn,id),entry);
  if (entries.length > 128) { entries.shift(); revision++; omitted=true; }
 }
 public function delta(id:String, turn:String, text:String):Void {
  var previous = "", existing:Null<AgentActivityItem> = null;
  for (entry in entries) if (entry.id == id && entry.turn == turn) { previous = entry.text; existing=entry; }
  if (existing == null) { put(id,turn,"agentMessage","Claude",text,"","inProgress"); return; }
  var token = existing.contentToken == null ? null : AgentContentCache.append(cacheKey(turn,id),text);
  put(id,turn,"agentMessage","Claude",previous + text,"","inProgress",false);
  existing.contentToken=token;
 }
 public function finish(turn:String, state:String):Void {
  for (entry in entries) if (entry.turn == turn && entry.state == "inProgress") {
   entry.state = state;if(archive!=null) archive.capture(cacheKey(turn,entry.id),entry);
  }
 }
 public function offset(cursor:String):Null<Int> {
  var parts = cursor.split(":");
  if (parts.length != 2 || parts[0] != epoch()) return null;
  var n = Std.parseInt(parts[1]);
  return n != null && n >= 0 && n <= entries.length && Std.string(n) == parts[1] ? n : null;
 }
 public function page(?before:Int):Array<AgentActivityItem> {
  var end = before == null ? entries.length : before;
  return entries.slice(Std.int(Math.max(0,end-8)),end);
 }
 public function next(?before:Int):Null<String> {
  var end = before == null ? entries.length : before;
  return end > 8 ? epoch() + ":" + (end-8) : null;
 }
 /** Keep the resource payload below the existing 16 KiB storage bound. */
 public function snapshot():Array<AgentActivityItem> {
  var saved:Array<AgentActivityItem> = [for (e in entries.slice(Std.int(Math.max(0,entries.length-6)))) {
   id:e.id,turn:e.turn,kind:e.kind,title:e.title,text:e.text.substring(0,384),detail:e.detail.substring(0,128),state:e.state,
   contentDigest:e.contentDigest,truncated:e.truncated || e.text.length > 384 || e.detail.length > 128
  }];
  while (saved.length > 0 && haxeon.wire.MessagePack.encode(saved).length > 6144) saved.shift();
  return saved;
 }
}
