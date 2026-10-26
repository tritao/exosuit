package workspace.provider;

import workspace.service.WorkspaceAgentProtocol;

/** Only commands the native RPC advertises are offered; TUI-only builtins are not executable RPC prompts. */
class PiCommands {
 static function text(v:Dynamic,key:String):String {
  var value=v == null ? null : Reflect.field(v,key);
  return Std.isOfType(value,String) ? value : "";
 }
 static function validName(name:String):Bool {
  if(name.length == 0 || name.length > 128 || StringTools.startsWith(name,"/")) return false;
  for(i in 0...name.length) if(name.charCodeAt(i) <= 32 || name.charCodeAt(i) == 127) return false;
  return !~/\s/.match(name);
 }
 public static function parse(data:Dynamic):Array<AgentCommand> {
  var raw:Dynamic=data == null ? null : Reflect.field(data,"commands");
  if(!Std.isOfType(raw,Array) || (cast raw:Array<Dynamic>).length > 256) throw "Pi command catalog is invalid or exceeds 256 entries";
  var result:Array<AgentCommand>=[],seen:Map<String,Bool>=[];
  for(item in (cast raw:Array<Dynamic>)) {
   var name=text(item,"name"),source=text(item,"source");
   if(!validName(name) || (source != "skill" && source != "extension" && source != "prompt")) continue;
   var skill=source == "skill";
   if(skill && StringTools.startsWith(name,"skill:")) name=name.substr(6);
   if(!validName(name)) continue;
   var invocation=skill ? "/skill:"+name : "/"+name;
   if(seen.exists(invocation)) continue;
   seen.set(invocation,true);
   var info=Reflect.field(item,"sourceInfo"),scope=text(info,"scope").toLowerCase();
   if(scope == "global" || scope == "personal") scope="user";
   if(scope == "workspace" || scope == "local") scope="project";
   result.push({name:name,description:text(item,"description").substr(0,512),kind:skill ? "skill" : source == "prompt" ? "prompt" : "command",
    invocation:invocation,scope:scope == "user" || scope == "project" ? scope : null});
  }
  result.sort(function(a,b) return Reflect.compare(a.invocation,b.invocation));
  return result;
 }
}
