package app;

import workspace.provider.CodexConversation;
import workspace.service.WorkspaceAgentProtocol.AgentActivityItem;
import workspace.service.WorkspaceAgentProtocol.AgentFileChange;
import haxeon.wire.MessagePack;

class SessionProjectionTestMain {
  static function require(value:Bool, message:String):Void { if (!value) throw message; }
  public static function main():Int {
    var conversation = new CodexConversation();
    var first = "@@ -1 +1 @@\n-old\n+new", second = "@@ -0,0 +1 @@\n+created";
    conversation.put("turn", {id:"edit", type:"fileChange", changes:[
      {path:"src/First.hx", kind:{type:"update"}, diff:first},
      {path:"src/Second.hx", kind:{type:"add"}, diff:second}
    ]}, true);
    var item = conversation.items()[0];
    var files:Array<AgentFileChange> = cast item.files;
    require(files != null && files.length == 2, "Lost reported file associations");
    require(item.detail.substr(files[0].offset, files[0].length) == first, "First file patch misattributed");
    require(item.detail.substr(files[1].offset, files[1].length) == second, "Second file patch misattributed");
    var roundTrip:AgentActivityItem = MessagePack.decode(MessagePack.encode(item));
    var decodedFiles:Array<AgentFileChange> = cast roundTrip.files;
    require(decodedFiles != null && decodedFiles.length == 2 && decodedFiles[1].path == "src/Second.hx", "File metadata lost over wire");
    var legacy:AgentActivityItem = {id:"old", turn:"t", kind:"agentMessage", title:"", text:"hello", detail:"", state:"completed", truncated:false};
    var restored:AgentActivityItem = MessagePack.decode(MessagePack.encode(legacy));
    require(restored.files == null && restored.text == "hello", "Legacy wire compatibility changed");
    var large = ""; for (_ in 0...3000) large += "x";
    conversation.put("turn", {id:"large", type:"fileChange", changes:[{path:"large.txt", kind:{type:"update"}, diff:large}]}, true);
    var bounded = conversation.items()[1];
    var boundedFiles:Array<AgentFileChange> = cast bounded.files;
    require(bounded.truncated && bounded.detail.length == 2048 && boundedFiles[0].truncated,
      "Patch bounds and truncation are inconsistent");
    require(boundedFiles[0].offset + boundedFiles[0].length <= bounded.detail.length, "Patch slice exceeds retained source");
    var many:Array<Dynamic> = [];
    for (index in 0...24) many.push({path:"file-" + index + ".txt", kind:{type:"update"}, diff:""});
    conversation.put("turn", {id:"many", type:"fileChange", changes:many}, true);
    var manyFiles:Array<AgentFileChange> = cast conversation.items()[2].files;
    require(manyFiles.length == 8 && conversation.items()[2].truncated, "Metadata is unbounded");
    trace("PASS: structured file associations, bounded patch slices, truncation and legacy wire compatibility");
    return 0;
  }
}
