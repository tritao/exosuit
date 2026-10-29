package workspace.provider;

import haxe.io.Bytes;
import workspace.service.WorkspaceAgentProtocol.AgentSnapshotReply;

private typedef SnapshotEntry = {var session:String; var bytes:Bytes; var created:Float; var touched:Float;}

/** Per-connection immutable snapshots; all lengths are encoded byte lengths. */
class AgentSnapshotCache {
 public static inline final MAX_BYTES = 4 * 1024 * 1024;
 public static inline final MAX_TOTAL = 8 * 1024 * 1024;
 public static inline final CHUNK = 24 * 1024;
 final entries:Map<String,SnapshotEntry> = [];
 final clock:Void->Float;
 final token:Void->String;
 final root:String;
 var used:Int = 0;
 public function new(root:String,clock:Void->Float,token:Void->String) {this.root=root;this.clock=clock;this.token=token;}
 public function clean():Void {
  var now=clock();
  for (id=>entry in entries) if (now-entry.created >= 120 || now-entry.touched >= 30) remove(id);
 }
 function remove(id:String):Void {var entry=entries.get(id); if(entry != null) {used-=entry.bytes.length; entries.remove(id);}}
 public function clear():Void {entries.clear();used=0;}
 public function create(session:String,bytes:Bytes,inputToken:Null<String>):AgentSnapshotReply {
  clean();
  if(bytes == null || bytes.length == 0 || bytes.length > MAX_BYTES) return failed(session,inputToken,"Snapshot exceeds the supported size");
  var count=0;for(_ in entries) count++;
  if(bytes.length > CHUNK && (count >= 4 || bytes.length > MAX_TOTAL-used)) return failed(session,inputToken,"Snapshot capacity is temporarily unavailable");
  var id:Null<String> = null;
  for (_ in 0...4) {var candidate=token();if(candidate != null && candidate.length > 0 && candidate.length <= 128 && !entries.exists(candidate)) {id=candidate;break;}}
  if(id == null) return failed(session,inputToken,"Snapshot identity unavailable");
  if(bytes.length > CHUNK) entries.set(id,{session:session,bytes:bytes,created:clock(),touched:clock()});
  if(bytes.length > CHUNK) used+=bytes.length;
  return {session:session,root:root,token:id,total:bytes.length,offset:0,bytes:bytes.sub(0,Std.int(Math.min(CHUNK,bytes.length))),inputToken:inputToken,snapshotError:null};
 }
 public function failed(session:String,inputToken:Null<String>,message:String):AgentSnapshotReply
  return {session:session,root:root,token:null,total:0,offset:0,bytes:null,inputToken:inputToken,snapshotError:message};
 public function read(session:String,id:String,offset:Int):Null<AgentSnapshotReply> {
  clean();var entry=entries.get(id);
  if(entry == null || entry.session != session || offset <= 0 || offset >= entry.bytes.length || offset % CHUNK != 0) return null;
  entry.touched=clock();var total=entry.bytes.length, size=Std.int(Math.min(CHUNK,total-offset));
  var chunk=entry.bytes.sub(offset,size);
  if(offset+size == total) remove(id);
  return {session:session,root:root,token:id,total:total,offset:offset,bytes:chunk,inputToken:null,snapshotError:null};
 }
}
