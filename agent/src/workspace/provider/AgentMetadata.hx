package workspace.provider;

import workspace.service.WorkspaceAgentProtocol.AgentRecord;
import workspace.service.WorkspaceProtocol.WorkspaceGroup;

/** Durable Workbench metadata edits never operate on the native session. */
class AgentMetadata {
 public static function rename(record:AgentRecord, expected:Null<String>, value:String, save:Void->Void):Null<String> {
  var name = workspace.service.AgentNames.normalize(value);
  if (name == null) return "invalid_name";
  if (record.name != expected) return "conflict";
  if (record.name == name) return null;
  var previous = record.name;
  record.name = name;
  try save() catch (error:Dynamic) {record.name = previous; throw error;}
  return null;
 }
 public static function move(record:AgentRecord, expected:Null<String>, target:String,
   groups:Array<WorkspaceGroup>, save:Void->Void):Null<String> {
  if (expected != record.group) return "conflict";
  if (!Lambda.exists(groups, function(group) return group.id == target)) return "unknown_group";
  if (record.group == target) return null;
  var previous = record.group;
  record.group = target;
  try save() catch (error:Dynamic) {record.group = previous; throw error;}
  return null;
 }
}
