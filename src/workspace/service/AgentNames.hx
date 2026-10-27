package workspace.service;

/** Shared validation for the user-owned Workbench display name. */
class AgentNames {
 public static function normalize(value:String):Null<String> {
  if (value == null) return null;
  var name = StringTools.trim(value);
  if (name.length == 0 || name.length > 256) return null;
  for (index in 0...name.length) {
   var code = name.charCodeAt(index);
   if (code < 32 || code == 127) return null;
  }
  return name;
 }
}
