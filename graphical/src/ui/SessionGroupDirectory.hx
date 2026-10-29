package ui;

import workspace.service.WorkspaceProtocol.WorkspaceGroup;
import workspace.client.SessionLinkTarget;

/** Resolve only directories accepted by the selected provider, and retain the
 * ancestry used so an open picker cannot act on a changed group tree. */
class SessionGroupDirectory {
 public static function resolve(groups:Array<WorkspaceGroup>, root:String, id:String, provider:String):Null<{cwd:String, stamp:String}> {
  var byId:Map<String,WorkspaceGroup> = [];
  for (group in groups) byId.set(group.id, group);
  var current = byId.get(id), seen:Map<String,Bool> = [], ancestry:Array<Dynamic> = [];
  if (current == null) return null;
  while (current != null) {
   if (seen.exists(current.id)) return null;
   seen.set(current.id, true);
   ancestry.push({id:current.id, revision:current.revision, cwd:current.cwd, parent:current.parent});
   if (current.cwd != null) {
    if (current.cwd == "" || SessionLinkTarget.relativeWithin(root, current.cwd) == null) return null;
    return {cwd:current.cwd, stamp:haxe.Json.stringify(ancestry)};
   }
   // Claude and Pi currently require an explicit cwd on the selected group.
   if (provider != null && provider != "codex") return null;
   if (current.parent == null) return {cwd:root, stamp:haxe.Json.stringify(ancestry)};
   current = byId.get(current.parent);
   if (current == null) return null;
  }
  return null;
 }
}
