package workspace.provider;

import haxe.crypto.Base64;
import haxe.io.Bytes;
import workspace.service.WorkspaceAgentProtocol;

typedef NativePage = {var cursor:String; var next:Null<String>; var conversation:CodexConversation;}

/** Small refetchable cache; opaque native cursor remains the source of truth. */
class CodexHistoryPages {
 static inline final MAX_PAGES=8;
 public static inline final CURSOR_BASE=1000000000;
 static inline final MAX_HANDLES=128;
 static inline final MAX_CURSOR_CHARS=2048;
 static inline final MAX_CURSOR_BYTES=6144;
 static inline final MAX_ENVELOPE_CHARS=8448;
 final pages:Array<NativePage> = [];
 final handles:Map<Int,String> = [];
 public var first:Null<String> = null;
 public function new() {}
 public function reset(next:Null<String>):Void {pages.resize(0);handles.clear();first=next == null || next == "" ? null : next;}
 static function number(epoch:String,value:String):Null<Int> {
  if(value == null) return null;
  var parts=value.split(":");
  if(parts.length!=2 || parts[0]!=epoch) return null;
  var n=Std.parseInt(parts[1]);
  return n!=null && n>=0 && n<CURSOR_BASE && Std.string(n)==parts[1] ? n : null;
 }
 public static function isNative(value:String):Bool {
  if(value==null) return false;
  var parts=value.split(":");if(parts.length!=2) return false;
  var n=Std.parseInt(parts[1]);return n!=null && n>=0 && n<CURSOR_BASE && Std.string(n)==parts[1];
 }
 public function firstCursor(epoch:String):Null<String> {
  if(first==null) return null;
  handles.set(CURSOR_BASE-1,first);return epoch+":"+(CURSOR_BASE-1);
 }
 public function resolve(epoch:String,value:String):Null<String> {
  var n=number(epoch,value);return n==null ? null : handles.get(n);
 }
 public function following(epoch:String,current:String,nativeNext:String):Null<String> {
  var n=number(epoch,current);
  if(n==null || nativeNext==null || nativeNext=="" || cursor(epoch,nativeNext)==null || n<=0) return null;
  var target=n-1, existing=handles.get(target);
  if(existing!=null) return existing==nativeNext ? epoch+":"+target : null;
  for(id=>value in handles) if(value==nativeNext) return null;
  var count=0, oldest=-1;
  for(id=>_ in handles) {count++;if(id!=CURSOR_BASE-1 && id>oldest) oldest=id;}
  if(count>=MAX_HANDLES) {
   if(oldest<0) return null;
   handles.remove(oldest);
  }
  handles.set(target,nativeNext);return epoch+":"+target;
 }
 public static function cursor(epoch:String,nativeCursor:String):Null<String> {
  if(nativeCursor == null || nativeCursor == "" || nativeCursor.length > MAX_CURSOR_CHARS || Bytes.ofString(nativeCursor).length > MAX_CURSOR_BYTES) return null;
  return "n:" + epoch + ":" + Base64.encode(Bytes.ofString(nativeCursor));
 }
 public static function decode(epoch:String,cursor:String):Null<String> {
  var prefix="n:"+epoch+":";
  if(cursor == null || !StringTools.startsWith(cursor,prefix) || cursor.length > MAX_ENVELOPE_CHARS) return null;
  try {
   var part=cursor.substr(prefix.length), decoded=Base64.decode(part), value=decoded.toString();
   if(decoded.length == 0 || decoded.length > MAX_CURSOR_BYTES || value.length > MAX_CURSOR_CHARS || Base64.encode(decoded)!=part || !workspace.TextFileContent.validUtf8(decoded)) return null;
   return value;
  } catch (_:Dynamic) return null;
 }
 public static function validNext(epoch:String,current:String,next:String,count:Int):Bool
  return next == "" || (next != current && count > 0 && cursor(epoch,next) != null);
 public function get(cursor:String):Null<NativePage> {
  for(page in pages) if(page.cursor==cursor) {pages.remove(page);pages.push(page);return page;}
  return null;
 }
 public function remember(cursor:String,next:Null<String>,data:Array<Dynamic>):NativePage {
  for(existing in pages.copy()) if(existing.cursor==cursor) pages.remove(existing);
  var conversation=new CodexConversation();conversation.history(data);
  var page:NativePage={cursor:cursor,next:next,conversation:conversation};
  pages.push(page);if(pages.length>MAX_PAGES) pages.shift();return page;
 }
 public function content(turn:String,id:String,token:String,offset:Int):Null<AgentContentChunk> {
  for(page in pages) {var result=page.conversation.content(turn,id,token,offset);if(result!=null) return result;}
  return null;
 }
 public static function merge(page:NativePage,live:CodexConversation):Array<AgentActivityItem> {
  return [for(item in page.conversation.items()) {
   var current=live.current(item.turn,item.id);
   current == null ? item : current;
  }];
 }
}
