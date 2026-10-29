package workspace.client;

import haxeon.wire.MessagePack;
import workspace.service.WorkspaceAgentProtocol.AgentView;
import workspace.service.WorkspaceAgentProtocol.AgentActivityItem;

/** Bounded, recoverable window; latest and an older reading position are independent. */
class AgentHistoryWindow {
 public static inline final MAX_ITEMS=256;
 public static inline final MAX_BYTES=4*1024*1024;
 public var loading:Bool=false;
 public var error:Null<String>;
 public var detached:Bool=false;
 public var resetRequired:Bool=false;
 public var cursor:Null<String>;
 public var epoch:Null<String>;
 public var latest:Null<AgentView>;
 public var seen:Map<String,Bool>=[];
 public var pendingDone:Null<Null<String>->Void>;
 public function new() {}
 public static function key(item:AgentActivityItem):String return item.turn.length+":"+item.turn+item.id;
 public static function sameEpoch(a:Null<String>,b:Null<String>):Bool return a != null && b != null && a == b;
 public static function within(items:Array<AgentActivityItem>):Bool {
  if (items.length > MAX_ITEMS) return false;
  try return MessagePack.encode(items).length <= MAX_BYTES catch (_:Dynamic) return false;
 }
 public static function copyView(view:AgentView):AgentView {
  var copy:AgentView=cast Reflect.copy(view);
  copy.items=view.items == null ? null : view.items.copy(); return copy;
 }
 public function status():AgentHistoryState return {loading:loading,error:error,hasOlder:cursor != null && !resetRequired,detached:detached,resetRequired:resetRequired};
 public function remember(view:AgentView):Void latest=copyView(view);
 public function reset():Null<AgentView> {
  if (latest == null) return null;
  var view=copyView(cast latest);
  cursor=view.itemsNext; epoch=view.historyEpoch; detached=false; resetRequired=false; error=null; seen=[];
  return view;
 }
 /** Merge overlapping latest entries without joining disconnected ranges. */
 public static function merge(old:Array<AgentActivityItem>, fresh:Array<AgentActivityItem>):Null<Array<AgentActivityItem>> {
  if (old.length==0) return fresh.copy();
  if (fresh.length==0) return old.copy();
  var map:Map<String,AgentActivityItem>=[], overlap=-1;
  for (item in old) map.set(key(item),item);
  for (index in 0...fresh.length) if (map.exists(key(fresh[index]))) overlap=index;
  if (overlap < 0) return null;
  var replacements:Map<String,AgentActivityItem>=[];
  for (item in fresh) replacements.set(key(item),item);
  var result:Array<AgentActivityItem>=[for(item in old) replacements.exists(key(item)) ? replacements.get(key(item)) : item];
  for(index in overlap+1...fresh.length) if (!map.exists(key(fresh[index]))) { result.push(fresh[index]); map.set(key(fresh[index]),fresh[index]); }
  return result;
 }
 public static function prepend(old:Array<AgentActivityItem>, page:Array<AgentActivityItem>):Array<AgentActivityItem> {
  var existing:Map<String,Bool>=[]; for(item in old) existing.set(key(item),true);
  var result:Array<AgentActivityItem>=[];
  for(item in page) if (!existing.exists(key(item))) {result.push(item);existing.set(key(item),true);}
  return result.concat(old);
 }
}
