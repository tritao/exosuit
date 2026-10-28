package workspace.client;

import haxe.io.Bytes;
import haxeon.wire.MessagePack;
import workspace.service.WorkspaceAgentProtocol.AgentSnapshotReply;
import workspace.service.WorkspaceAgentProtocol.AgentView;

/** Validates one immutable bounded snapshot before exposing its decoded view. */
class AgentSnapshotAssembler {
 public static inline final MAX_TOTAL = 4 * 1024 * 1024;
 public static inline final MAX_CHUNK = 24 * 1024;
 final session:String; final root:String; final token:String; final total:Int; final data:Bytes;
 public var offset(default,null):Int = 0;
 public function new(first:AgentSnapshotReply, session:String, root:String) {
  if (first == null || first.session != session || first.root != root || first.snapshotError != null
    || first.token == null || first.token.length == 0 || first.token.length > 128 || first.total <= 0 || first.total > MAX_TOTAL
    || first.offset != 0 || first.bytes == null || first.bytes.length == 0 || first.bytes.length > MAX_CHUNK || first.bytes.length > first.total)
   throw "Invalid session snapshot";
  this.session=session; this.root=root; this.token=cast first.token; this.total=first.total;
  data=Bytes.alloc(total); add(first,true);
 }
 public function snapshotToken():String return token;
 public function complete():Bool return offset == total;
 public function add(chunk:AgentSnapshotReply, first:Bool = false):Void {
  if (chunk == null || chunk.session != session || chunk.root != root || chunk.token != token || chunk.total != total
    || chunk.snapshotError != null || (!first && chunk.inputToken != null) || chunk.offset != offset || chunk.bytes == null
    || chunk.bytes.length == 0 || chunk.bytes.length > MAX_CHUNK || chunk.bytes.length > total-offset)
   throw "Invalid session snapshot chunk";
  data.blit(offset,chunk.bytes,0,chunk.bytes.length); offset += chunk.bytes.length;
 }
 public function view():AgentView {
  if (!complete()) throw "Incomplete session snapshot";
  var decoded:AgentView = MessagePack.decode(data);
  if (decoded == null || decoded.record == null || decoded.record.id != session || decoded.record.workspaceRoot != root)
   throw "Invalid session snapshot view";
  return decoded;
 }
}
