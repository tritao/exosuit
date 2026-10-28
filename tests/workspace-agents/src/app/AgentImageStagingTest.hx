package app;

import haxe.io.Bytes;
import workspace.provider.AgentImageStaging;
import workspace.service.WorkspaceAgentProtocol.AgentImageUpload;

/** Staging never trusts caller identity, offsets, size, or replayed lease metadata. */
class AgentImageStagingTest {
 static function require(value:Bool, message:String):Void if (!value) throw message;
 static function main():Void run();
 public static function run():Void {
  var attempts=0, delays:Array<Float>=[];
  workspace.provider.AgentJournalPublisher.write("journal","unchanged",true,function(path,content) {
   require(path=="journal" && content=="unchanged","Journal retry changed publication");
   attempts++;if(attempts<3) throw "transient";
  },function(delay) delays.push(delay));
  require(attempts==3 && delays.length==2 && delays[0]==0.01 && delays[1]==0.02,"Transient journal retry failed");
  attempts=0;delays=[];var retryFailed=false;
  try workspace.provider.AgentJournalPublisher.write("journal","unchanged",true,function(_,_) {attempts++;throw "persistent";},function(delay) delays.push(delay))
  catch (_:Dynamic) retryFailed=true;
  require(retryFailed && attempts==4 && delays.length==3 && delays[2]==0.04,"Persistent journal retry was not bounded");
  attempts=0;delays=[];retryFailed=false;
  try workspace.provider.AgentJournalPublisher.write("journal","unchanged",false,function(_,_) {attempts++;throw "persistent";},function(delay) delays.push(delay))
  catch (_:Dynamic) retryFailed=true;
  require(retryFailed && attempts==1 && delays.length==0,"Non-Windows publication unexpectedly retried");
  var base = Sys.args()[0], root = "image-test-" + Std.string(Sys.time()), serial = 0, now = 1000.0;
  function random():String return StringTools.lpad(Std.string(++serial), "0", 32);
  function secureDir(path:String):Bool { if (!sys.FileSystem.exists(path)) sys.FileSystem.createDirectory(path); return true; }
  var stage = new AgentImageStaging(base, root, random, function() return now, secureDir, function(_) return true, function(_) return true, function() {});
  function request(session:String, operation:String, upload:Null<String>, size:Int, offset:Int, bytes:Null<Bytes>):AgentImageUpload
   return {workspace:"workspace",instance:"instance",session:session,operation:operation,upload:upload,size:size,offset:offset,bytes:bytes};
  var frame = haxeon.wire.MessagePack.encode(request("one", "chunk", StringTools.lpad("1", "0", 64),
   AgentImageStaging.MAX_IMAGE, 0, Bytes.alloc(AgentImageStaging.MAX_CHUNK)));
  require(frame.length < workspace.transport.NoiseMessageTransport.MAX_PLAINTEXT_BYTES, "Maximum upload chunk exceeds the secure relay frame");
  var legacy:workspace.service.WorkspaceAgentProtocol.AgentView = {record:{id:"one",name:"One",group:"work",cwd:"/repo",thread:"thread",
   state:"idle",turn:null,workspaceRoot:"/repo"},activity:"",requests:[],error:null};
  var legacyDecoded:workspace.service.WorkspaceAgentProtocol.AgentView = haxeon.wire.MessagePack.decode(haxeon.wire.MessagePack.encode(legacy));
  require(legacyDecoded.supportsImageUpload == null, "Legacy provider unexpectedly advertised image upload");
  var imageOnly = workspace.provider.CodexProvider.turnInput("", ["host-private-image.png"]);
  require(imageOnly.length == 1 && Reflect.field(imageOnly[0], "type") == "localImage"
   && Reflect.field(imageOnly[0], "path") == "host-private-image.png", "Image-only turn did not use the Codex local image input");
  var png = sys.io.File.getBytes("graphical/assets/icons/exosuit-16.png");
  var start = stage.process(request("one","begin",null,png.length,0,null));
  var rejected = false;
  try stage.process(request("two","chunk",start.upload,png.length,0,png)) catch (_:Dynamic) rejected = true;
  require(rejected,"A different session appended to an upload");
  rejected = false;
  try stage.process(request("one","chunk",start.upload,png.length,1,png)) catch (_:Dynamic) rejected = true;
  require(rejected,"Wrong chunk offset was accepted");
  var offset = 0;
  while (offset < png.length) {
   var count = Std.int(Math.min(AgentImageStaging.MAX_CHUNK,png.length-offset));
   var result = stage.process(request("one","chunk",start.upload,png.length,offset,png.sub(offset,count)));
   offset += count; require(result.offset == offset,"Chunk acknowledgement changed offset");
  }
  var finished = stage.process(request("one","finish",start.upload,png.length,offset,null));
  require(finished.complete && stage.resolve("two",[start.upload]) == null,"Completed image escaped session scope");
  var paths = stage.resolve("one",[start.upload]);
  require(paths != null && paths.length == 1 && sys.FileSystem.exists(paths[0]),"Staged image unavailable");
  require(stage.pin("one","thread",[start.upload]),"Could not pin image");
  stage.process(request("one","remove",start.upload,0,0,null));
  stage.dispose();
  require(sys.FileSystem.exists(paths[0]),"Disposal removed an in-flight image");
  var restored = new AgentImageStaging(base, root, random, function() return now, secureDir, function(_) return true, function(_) return true, function() {});
  now += 1200; restored.clean(function(_) return true, function(_,_) return true);
  require(sys.FileSystem.exists(paths[0]),"Expiry removed an unresolved image");
  restored.clean(function(_) return true, function(_,_) return false);
  require(!sys.FileSystem.exists(paths[0]),"Reconciled removed image was not cleaned");
  var missing = restored.process(request("one","begin",null,png.length,0,null));
  restored.process(request("one","chunk",missing.upload,png.length,0,png));
  restored.process(request("one","finish",missing.upload,png.length,png.length,null));
  var missingPaths = restored.resolve("one",[missing.upload]);
  sys.FileSystem.deleteFile(missingPaths[0]); // Simulate a crash after deletion and before journal update.
  var recovered = new AgentImageStaging(base, root, random, function() return now, secureDir, function(_) return true, function(_) return true, function() {});
  require(recovered.available() && recovered.resolve("one",[missing.upload]) == null, "Missing unpinned file did not recover its journal");
  restored = recovered;
  var bad = restored.process(request("one","begin",null,10,0,null));
  restored.process(request("one","chunk",bad.upload,10,0,Bytes.ofString("not image!")));
  rejected = false; try restored.process(request("one","finish",bad.upload,10,10,null)) catch (_:Dynamic) rejected = true;
  require(rejected,"Invalid image bytes were accepted");
  rejected = false; try restored.process(request("one","begin",null,AgentImageStaging.MAX_IMAGE+1,0,null)) catch (_:Dynamic) rejected = true;
  require(rejected,"Oversized image was accepted");
  restored.dispose();
  Sys.println("PASS: bounded image chunks, scope, format, pinned restart and reconciliation");
 }
}
