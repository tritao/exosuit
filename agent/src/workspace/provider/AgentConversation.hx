package workspace.provider;

import workspace.service.WorkspaceAgentProtocol;

/**
 * A chat session's conversation as the service keeps it (Claude, Pi): bounded activity items, whole assistant texts in
 * `AgentContentCache` and the archive, 8-item pages with cursors that an eviction invalidates, and a 6-item preview
 * saved with the record.
 */
class AgentConversation {
 /** Items kept per session; older ones are dropped and reported as omitted. */
 public static inline final MAX_ENTRIES:Int = 512;
 static var nextCacheId:Int = 0;
 /** The provider's name: the title of its replies, and part of their content keys. */
 final speaker:String;
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
 function cacheKey(turn:String,id:String):String return speaker+"-"+cacheId+":"+turn.length+":"+turn+id;
 public function content(turn:String,id:String,token:String,offset:Int):Null<AgentContentChunk> {
  for (entry in entries) if (entry.turn == turn && entry.id == id && entry.kind == "agentMessage" && entry.contentToken == token) {
   var key=cacheKey(turn,id),chunk=AgentContentCache.chunk(key,token,offset);
   if(chunk==null && archive!=null && archive.restore(key,entry,token)!=null) return AgentContentCache.chunk(key,token,offset);
   return chunk;
  }
  return null;
 }
 /**
  * `saved` is the service's shortened preview of the newest items, or with `whole` the conversation read from the
  * provider's own record (`AgentTranscript`): whole texts, of which older parts were left out when `partial`.
  */
 public function new(speaker:String,?saved:Array<AgentActivityItem>,?archive:AgentResponseArchive,whole:Bool=false,partial:Bool=false) {
  this.speaker=speaker;cacheId=++nextCacheId;this.archive=archive;omitted=partial;
  if (saved != null) for (entry in saved) {
   put(entry.id, entry.turn, entry.kind, entry.title, entry.text, entry.detail, entry.state, !entry.truncated);
   var restored:Null<AgentActivityItem>=null;
   for (candidate in entries) if (candidate.id == entry.id && candidate.turn == entry.turn) restored=candidate;
   if (restored == null) continue;
   restored.images=entry.images;
   if (whole) continue;
   restored.truncated=entry.truncated;restored.contentDigest=entry.contentDigest;
   if(entry.truncated && archive!=null) restored.contentToken=archive.restore(cacheKey(entry.turn,entry.id),restored);
   restored.files=retainedFiles(entry,2048);
  }
  restoring=false;
 }
 public function attachImages(turn:String,id:String,ids:Array<String>):Void {
  for(entry in entries) if(entry.turn==turn && entry.id==id) entry.images=[for(imageId in ids) {id:imageId}];
 }
 /** Keeps Pi's tool record and shows a real edit patch it reported as an activity of its own. */
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
 public function put(id:String, turn:String, kind:String, title:String, text:String, detail:String, state:String, retainContent:Bool = true):Void {
  if (id == null || id.length == 0 || id.length > 512 || turn.length > 128) return;
  var entry:Null<AgentActivityItem> = null;
  for (e in entries) if (e.id == id && e.turn == turn) entry = e;
  if (entry == null) {
   // A tool keeps the name it was called with: its result names no tool.
   entry = {id:id, turn:turn, kind:kind, title:title.substring(0,256), text:"", detail:"", state:state, truncated:false};
   entries.push(entry);
  }
  if(kind=="agentMessage" && (retainContent || state=="inProgress")) entry.contentDigest=null;
  if (kind == "agentMessage" && retainContent) entry.contentToken = AgentContentCache.replace(cacheKey(turn,id),text);
  entry.text = text.substring(0,4096);
  // Tool results carry no input detail; keep the arguments received at tool_use.
  entry.detail = detail == "" ? entry.detail : detail.substring(0,2048); entry.state = state;
  entry.truncated = entry.truncated || title.length > 256 || text.length > 4096 || detail.length > 2048;
  if(!restoring && archive!=null) archive.capture(cacheKey(turn,id),entry);
  if (entries.length > MAX_ENTRIES) { entries.shift(); revision++; omitted=true; }
 }
 /** Appends streamed text to a reply (or, with `kind` "reasoning", to its reasoning). */
 public function delta(id:String, turn:String, text:String, kind:String = "agentMessage"):Void {
  var previous = "", existing:Null<AgentActivityItem> = null;
  for (entry in entries) if (entry.id == id && entry.turn == turn) { previous = entry.text; existing=entry; }
  var title = kind == "reasoning" ? "Reasoning" : speaker;
  if (existing == null) { put(id,turn,kind,title,text,"","inProgress"); return; }
  var token = kind == "agentMessage" && existing.contentToken != null ? AgentContentCache.append(cacheKey(turn,id),text) : null;
  put(id,turn,kind,title,previous + text,"","inProgress",false);
  if (kind == "agentMessage") existing.contentToken=token;
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
   contentDigest:e.contentDigest,truncated:e.truncated || e.text.length > 384 || e.detail.length > 128,files:retainedFiles(e,128),images:e.images
  }];
  while (saved.length > 0 && haxeon.wire.MessagePack.encode(saved).length > 6144) saved.shift();
  return saved;
 }
}
