package workspace.provider;

import workspace.service.WorkspaceAgentProtocol.AgentRecord;
import workspace.service.WorkspaceProtocol.WorkspaceGroup;

/** Durable Workbench metadata edits never operate on the native session. */
class AgentMetadata {
 public static function rename(record:AgentRecord, expected:Null<String>, value:String, save:Void->Void):Null<String> {
  if (record.nameMetadata != null && record.nameMetadata.pending != null) return "busy";
  var name = workspace.service.AgentNames.normalize(value);
  if (name == null) return "invalid_name";
  if (record.name != expected) return "conflict";
  if (record.name == name) return null;
  var previous = record.name, previousMetadata = record.nameMetadata;
  record.name = name;
  if (previousMetadata != null) record.nameMetadata = {source:"workbench",nativeName:previousMetadata.nativeName};
  try save() catch (error:Dynamic) {record.name = previous;record.nameMetadata = previousMetadata;throw error;}
  return null;
 }
 /** Moves to `target`, and with `order` places it there; `order` alone re-orders within the current group. */
 public static function move(record:AgentRecord, expected:Null<String>, target:String,
   groups:Array<WorkspaceGroup>, save:Void->Void, ?order:Int):Null<String> {
  if (expected != record.group) return "conflict";
  if (!workspace.service.WorkspaceProtocol.knownGroup(target, groups)) return "unknown_group";
  if (!workspace.service.WorkspaceProtocol.validOrder(order)) return "invalid_order";
  if (record.group == target && (order == null || record.order == order)) return null;
  var previous = record.group, previousOrder = record.order;
  record.group = target;
  if (order != null) record.order = order;
  try save() catch (error:Dynamic) {record.group = previous; record.order = previousOrder; throw error;}
  return null;
 }
}
