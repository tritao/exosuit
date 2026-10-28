package workspace.provider;

import haxe.io.Bytes;
import workspace.service.WorkspaceAgentProtocol.AgentContentChunk;

private typedef ContentEntry = { var key:String; var token:String; var bytes:Bytes; var partial:Bool; }

/** Process-wide bounded snapshots for assistant messages; wire previews remain small. */
class AgentContentCache {
 public static inline final MAX_MESSAGE = 256 * 1024;
 public static inline final MAX_TOTAL = 4 * 1024 * 1024;
 public static inline final CHUNK = 24 * 1024;
 static var entries:Array<ContentEntry> = [];
 static var used:Int = 0;
 static var serial:Int = 0;
 static function find(key:String):Null<ContentEntry> { for (entry in entries) if (entry.key == key) return entry; return null; }
 static function retain(entry:ContentEntry):Void {
  entries.remove(entry); entries.push(entry);
  while (entries.length > 128 || used > MAX_TOTAL) { var old = entries.shift(); used -= old.bytes.length; }
 }
 static function prefix(bytes:Bytes, limit:Int):Bytes {
  if (bytes.length <= limit) return bytes;
  var n = limit;
  // UTF-8 continuation bytes mark a cut through a code point.
  while (n > 0 && (bytes.get(n) & 192) == 128) n--;
  return bytes.sub(0,n);
 }
 public static function replace(key:String, value:String):String {
  var old=find(key); if (old != null) { used-=old.bytes.length; entries.remove(old); }
  var bytes=Bytes.ofString(value), partial=bytes.length > MAX_MESSAGE;
  var data=prefix(bytes,MAX_MESSAGE), token=Std.string(++serial);
  var entry:ContentEntry={key:key,token:token,bytes:data,partial:partial}; entries.push(entry); used+=data.length; retain(entry); return token;
 }
 public static function append(key:String, value:String):Null<String> {
  var entry=find(key); if (entry == null) return null;
  if (entry.partial) { entry.token=Std.string(++serial); retain(entry); return entry.token; }
  var added=Bytes.ofString(value), remaining=MAX_MESSAGE-entry.bytes.length, keep=prefix(added,remaining);
  var joined=Bytes.alloc(entry.bytes.length+keep.length); joined.blit(0,entry.bytes,0,entry.bytes.length); joined.blit(entry.bytes.length,keep,0,keep.length);
  used-=entry.bytes.length; entry.bytes=joined; used+=joined.length;
  entry.partial=entry.partial || added.length > keep.length; entry.token=Std.string(++serial); retain(entry); return entry.token;
 }
 /** Immutable captured source for durable terminal-message retention. */
 public static function snapshot(key:String,token:String):Null<workspace.service.WorkspaceAgentContentPersistence.AgentStoredContent> {
  var entry=find(key);return entry==null || entry.token!=token ? null : {bytes:entry.bytes,partial:entry.partial};
 }
 /** Restore a verified source while preserving a still-published token when requested. */
 public static function recover(key:String,bytes:Bytes,partial:Bool,?token:String):String {
  if(bytes==null || bytes.length>MAX_MESSAGE || !workspace.TextFileContent.validUtf8(bytes)) throw "Invalid retained response";
  var old=find(key);if(old!=null) {used-=old.bytes.length;entries.remove(old);}
  var version=token==null ? Std.string(++serial) : token;
  var entry:ContentEntry={key:key,token:version,bytes:bytes,partial:partial};
  entries.push(entry);used+=bytes.length;retain(entry);return version;
 }
 public static function chunk(key:String, token:String, offset:Int):Null<AgentContentChunk> {
  var entry=find(key); if (entry == null || token != entry.token || offset < 0 || offset > entry.bytes.length) return null;
  retain(entry); var count=Std.int(Math.min(CHUNK,entry.bytes.length-offset));
  return {token:entry.token,offset:offset,total:entry.bytes.length,bytes:entry.bytes.sub(offset,count),partial:entry.partial};
 }
}
