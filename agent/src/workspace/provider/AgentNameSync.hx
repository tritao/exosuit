package workspace.provider;

import haxeon.rpc.RpcError;
import workspace.service.WorkspaceAgentProtocol;
import workspace.service.AgentNames;

typedef NativeNameReadDone = (Null<String>, Null<RpcError>)->Void;
typedef NativeNameRead = NativeNameReadDone->Void;
typedef NativeNameWrite = (String, Null<String>, Null<RpcError>->Void)->Void;

/** Native title is authoritative only after opt-in. A saved intent reconciles partial failures without repeating writes. */
class AgentNameSync {
 final record:AgentRecord;
 final save:Void->Void;
 final read:NativeNameRead;
 final write:NativeNameWrite;
 final clock:Void->Float;
 public var busy(default,null) = false;
 var nextRead = 0.0;
 var disposed = false;

 public function new(record:AgentRecord,save:Void->Void,read:NativeNameRead,write:NativeNameWrite,clock:Void->Float) {
  this.record=record;this.save=save;this.read=read;this.write=write;this.clock=clock;
 }
 public function dispose():Void disposed=true;
 static function error(code:String,message:String,ambiguous:Bool=false):RpcError return {code:code,message:message,ambiguous:ambiguous};
 function update(name:String,metadata:AgentNameMetadata):Void {
  var previous=record.name,old=record.nameMetadata;
  record.name=name;record.nameMetadata=metadata;
  try save() catch(e:Dynamic) {record.name=previous;record.nameMetadata=old;throw e;}
 }
 function observed(nativeName:Null<String>):Void {
  var metadata=record.nameMetadata;
  var source=metadata==null ? "workbench" : metadata.source;
  var name=source=="native" ? (nativeName==null ? (metadata!=null && metadata.nativeName!=null ? fallback() : record.name) : nativeName.substring(0,256)) : record.name;
  if(metadata!=null && metadata.pending==null && metadata.nativeName==nativeName && record.name==name) return;
  update(name,{source:source,nativeName:nativeName});
 }
 function fallback():String return record.provider=="claude" ? "Claude" : "Codex";
 function reconciled(nativeName:Null<String>):Void {
  var metadata=record.nameMetadata, intent=metadata==null ? null : metadata.pending;
  if(intent!=null && intent.session==record.thread && nativeName==intent.target)
   update(intent.target,{source:"native",nativeName:nativeName});
  else observed(nativeName);
 }
 public function observeExternal(nativeName:Null<String>):Void {
  // An in-flight write is verified by a subsequent read, not by an intermediate event.
  if(disposed || busy || record.nameMetadata!=null && record.nameMetadata.pending!=null) return;
  try observed(nativeName) catch(_:Dynamic) {}
 }
 public function inspect(done:Void->Void,failed:RpcError->Void):Void {
  if(disposed || busy) {failed(error("busy","Session naming is busy; try again shortly"));return;}
  busy=true;nextRead=clock()+5000;
  read(function(name,problem) {
   if(disposed) return;
   busy=false;
   if(problem!=null) {failed(problem);return;}
   try reconciled(name) catch(_:Dynamic) {failed(error("storage_unavailable","Native name was read, but its local metadata could not be saved",true));return;}
   done();
  });
 }
 public function poll():Bool {
  if(disposed || busy || record.thread=="" || clock()<nextRead) return false;
  inspect(function() {},function(_) {});return true;
 }
 public function rename(expectedLocal:String,expectedNative:Null<String>,value:String,done:Void->Void,failed:RpcError->Void):Void {
  if(disposed || busy) {failed(error("busy","Session naming is busy; try again shortly"));return;}
  var target=AgentNames.normalize(value);
  if(target==null) {failed(error("invalid_name","Enter a name of 1–256 characters without control characters"));return;}
  if(record.name!=expectedLocal) {failed(error("conflict","The session label changed. Reopen Rename before saving."));return;}
  if(record.nameMetadata!=null && record.nameMetadata.pending!=null) {
   inspect(function() failed(error("reconcile_required","A previous rename was reconciled. Reopen Rename before saving.")),failed);return;
  }
  busy=true;nextRead=clock()+5000;
  read(function(actual,problem) {
   if(disposed) return;
   if(problem!=null) {busy=false;failed(problem);return;}
   if(actual!=expectedNative || record.name!=expectedLocal) {
    busy=false;
    try observed(actual) catch(_:Dynamic) {}
    failed(error("conflict","The name changed in the native tool. Reopen Rename before saving."));return;
   }
   if(actual==target) {
    busy=false;
    try update(target,{source:"native",nativeName:actual}) catch(_:Dynamic) {failed(error("storage_unavailable","The existing native name could not be saved locally"));return;}
    done();return;
   }
   var source=record.nameMetadata==null ? "workbench" : record.nameMetadata.source;
   try update(record.name,{source:source,nativeName:actual,pending:{expected:actual,target:target,session:record.thread}})
   catch(_:Dynamic) {busy=false;failed(error("storage_unavailable","Rename was not sent because its recovery record could not be saved"));return;}
   write(target,actual,function(writeError) {
    if(disposed) return;
    // Reads are safe to repeat; title writes are never blindly retried.
    read(function(confirmed,readError) {
     if(disposed) return;
     busy=false;
     if(readError!=null) {failed(error("rename_unconfirmed","The native rename could not be confirmed. Refresh to reconcile it before retrying.",true));return;}
     try reconciled(confirmed) catch(_:Dynamic) {
      failed(error("storage_unavailable","The native title changed, but saving the local result failed. Refresh after storage recovers.",true));return;
     }
     if(confirmed==target) done();
     else if(writeError!=null) failed(writeError);
     else failed(error("conflict","The native name changed before the rename could be confirmed. Refresh before retrying."));
    });
   });
  });
 }
}
