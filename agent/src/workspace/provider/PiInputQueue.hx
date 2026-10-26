package workspace.provider;

import haxe.crypto.Sha256;
import haxe.io.Bytes;
import haxeon.wire.MessagePack;
import workspace.service.WorkspaceAgentProtocol;

/** A bounded durable outbox. The serial rejects expired tokens even after their receipts are pruned. */
class PiInputQueue {
 final record:AgentRecord;
 public final messages:Array<AgentInputMessage>;
 public function new(record:AgentRecord) {
  this.record=record;
  if(record.inputSerial == null) record.inputSerial=0;
  if(record.inputMessages == null) record.inputMessages=[];
  messages=cast record.inputMessages;
  if(record.inputSerial < 0 || messages.length>16) throw "Invalid Pi input history";
  var seen:Map<String,Bool>=[],bytes=0;
  var current=token(),prefix=current.substr(0,current.lastIndexOf("-")+1);
  for(m in messages) {
   if(m.id == null || m.id.length==0 || m.id.length>128 || seen.exists(m.id) || m.fingerprint == null || m.fingerprint.length!=64
    || (m.kind!="queue" && m.kind!="steer" && m.kind!="clear") || !validState(m.state) || m.text == null
    || (m.error != null && m.error.length>256)) throw "Invalid persisted Pi input";
   var suffix=m.id.substr(prefix.length),serial=Std.parseInt(suffix);
   if(!StringTools.startsWith(m.id,prefix) || serial==null || serial<0 || serial>=(cast record.inputSerial:Int) || Std.string(serial)!=suffix
    || !~/^[0-9a-f]{64}$/.match(m.fingerprint) || (m.text!="" && m.fingerprint!=fingerprint(m.kind,m.text))) throw "Invalid Pi input receipt identity";
   seen.set(m.id,true);bytes+=Bytes.ofString(m.text).length;
   if(m.state=="sending" || m.state=="steering") {m.state="uncertain";m.error=null;}
  }
  if(bytes>4096 || [for(m in pending()) if(m.kind!="clear") true].length>8) throw "Pi input history exceeds bound";
  // Reconnecting a process is not authorization to replay unsent work.
  if(pending().length>0) record.queuePaused=true;
 }
 static function validState(v:String):Bool return ["queued","sending","steering","sent","handled","cancelled","uncertain","rejected"].contains(v);
 public function token():String return "pi-input-"+Sha256.encode(record.id+"\n"+record.thread).substr(0,16)+"-"+Std.string(record.inputSerial);
 public static function fingerprint(kind:String,text:String):String return Sha256.encode(kind+"\n"+text);
 public function find(id:String):Null<AgentInputMessage> {
  if(id != null) for(m in messages) if(m.id==id) return m;
  return null;
 }
 public function pending():Array<AgentInputMessage> return [for(m in messages) if(m.state!="sent" && m.state!="handled" && m.state!="cancelled") m];
 public function next():Null<AgentInputMessage> {
  for(m in messages) if(m.kind=="queue" && m.state=="queued") return m;
  return null;
 }
 public function hasNativeOperation():Bool {
  for(m in messages) if(m.state=="sending") return true;
  return false;
 }
 public function canAdd(text:String,kind:String="queue"):Bool {
  var bytes=Bytes.ofString(text).length,count=0;
  for(m in messages) {bytes+=Bytes.ofString(m.text).length;if(m.kind!="clear" && m.state!="sent" && m.state!="handled" && m.state!="cancelled") count++;}
  if(bytes>4096 || (kind!="clear" && count>=8) || (cast record.inputSerial:Int)>=2147483647) return false;
  var candidate=messages.copy();
  if(candidate.length>=16) for(m in candidate) if(m.state=="sent" || m.state=="handled" || m.state=="cancelled") {candidate.remove(m);break;}
  if(candidate.length>=16) return false;
  candidate.push({id:token(),kind:kind,text:text,fingerprint:fingerprint(kind,text),state:kind=="queue" ? "queued" : "sending"});
  // Check the mandatory state before admission. Optional history may be shortened by the provider's save.
  var replay=record.replay,previous=record.inputMessages;
  record.replay=[];record.inputMessages=candidate;
  var size=MessagePack.encode(record).length;
  record.replay=replay;record.inputMessages=previous;
  return size<=16000;
 }
 public function add(id:String,kind:String,text:String):AgentInputMessage {
  if(id != token() || !canAdd(text,kind)) throw "Pi input token or limit changed";
  if(messages.length>=16) for(m in messages) if(m.state=="sent" || m.state=="handled" || m.state=="cancelled") {messages.remove(m);break;}
  var m:AgentInputMessage={id:id,kind:kind,text:text,fingerprint:fingerprint(kind,text),state:kind=="queue" ? "queued" : "sending"};
  messages.push(m);record.inputSerial=(cast record.inputSerial:Int)+1;
  return m;
 }
 public function finish(m:AgentInputMessage,state:String,?error:String):Void {
  m.state=state;m.error=error == null ? null : error.substr(0,256);
  if(state=="sent" || state=="handled" || state=="cancelled") m.text="";
 }
 public function pause():Void {
  record.queuePaused=true;
  for(m in messages) if(m.state=="sending" || m.state=="steering") finish(m,"uncertain");
 }
 public function nativeEmpty():Void {for(m in messages) if(m.state=="steering") finish(m,"sent");}
}
