package workspace.client;

import workspace.service.WorkspaceAgentProtocol;

/** Complete the first composer token only; commands are inserted, never sent on selection. */
class AgentCommandCompletion {
 public static function matches(commands:Null<Array<AgentCommand>>,prompt:String):Array<AgentCommand> {
  if(commands == null || prompt.length == 0 || (prompt.charAt(0) != "/" && prompt.charAt(0) != "$")) return [];
  if(~/\s/.match(prompt)) return [];
  var skills=prompt.charAt(0) == "$",query=prompt.toLowerCase(),result:Array<AgentCommand>=[];
  for(command in commands) {
   if(skills && command.kind != "skill") continue;
   var token=skills ? "$"+command.name : command.invocation;
   if(StringTools.startsWith(token.toLowerCase(),query)) result.push(command);
   if(result.length == 8) break;
  }
  return result;
 }
 public static function insert(command:AgentCommand):String return command.invocation+" ";
 public static function label(command:AgentCommand,skills:Bool):String {
  var name=skills ? "$"+command.name : command.invocation;
  if(command.scope != null) name += " · "+command.scope;
  var description=~/\s+/g.replace(command.description," ");
  return name+(description == "" ? "" : " — "+description.substr(0,100));
 }
}
