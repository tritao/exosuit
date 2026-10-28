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
    var pi = new workspace.provider.PiConversation();
    var arguments = '{"path":"src/Pi.hx","oldText":"old","newText":"new"}';
    pi.put("edit","t","tool","edit","",arguments,"inProgress");
    pi.put("edit","t","tool","edit","Successfully replaced text","","completed");
    var patch = "--- src/Pi.hx\n+++ src/Pi.hx\n@@ -1 +1 @@\n-old\n+new\n";
    pi.toolPatch("edit","t",{details:{patch:patch,diff:"-1 old\n+1 new"}});
    var projected = pi.page();
    require(projected.length == 2 && projected[0].detail == arguments && projected[0].text == "Successfully replaced text",
      "Pi patch projection erased original tool input/output");
    require(projected[1].kind == "fileChange" && projected[1].detail == patch && projected[1].files[0].path == "src/Pi.hx",
      "Pi edit patch lost actual source or file attribution");
    pi.toolPatch("edit","t",{details:{patch:patch}});
    require(pi.page().length == 2,"Replayed Pi completion duplicated its patch");
    pi.put("failed","t","tool","edit","Failed",arguments,"failed");
    pi.toolPatch("failed","t",{details:{patch:patch}});
    require(pi.page().length == 3,"Failed edit was presented as a completed file change");
    pi.put("legacy","t","tool","edit","Done",arguments,"completed");
    pi.toolPatch("legacy","t",{details:{diff:"-1 old\n+1 new"}});
    require(pi.page().length == 4,"Pi display-oriented diff was mistaken for a unified patch");
    var longPatch = patch; for (_ in 0...250) longPatch += " context line\n";
    pi.toolPatch("edit","t",{details:{patch:longPatch}});
    var retained = pi.page()[1];
    require(retained.detail.length == 2048 && retained.truncated && retained.files[0].truncated,
      "Pi patch retention exceeded its bound or hid partial status");
    var restoredPi = new workspace.provider.PiConversation(pi.snapshot());
    var restoredPatch = restoredPi.page()[1];
    require(restoredPatch.files[0].path == "src/Pi.hx" && restoredPatch.files[0].length <= restoredPatch.detail.length
      && restoredPatch.files[0].truncated,"Pi restart lost bounded patch metadata");
    var claude = new workspace.provider.ClaudeConversation();
    claude.put("tool","t","tool","Edit","",arguments,"inProgress");
    claude.put("tool","t","tool","Tool","Edit succeeded","","completed");
    require(claude.page()[0].title == "Edit" && claude.page()[0].detail == arguments && claude.page()[0].text == "Edit succeeded",
      "Claude tool completion erased its arguments or result");
    claude.put("bounded","t","tool","Edit","",longPatch,"inProgress");
    claude.put("bounded","t","tool","Tool","Done","","completed");
    require(claude.page()[1].truncated && claude.page()[1].detail.length == 2048,
      "Claude completion hid retained-input truncation");
    var longText = "```html\n"; for (_ in 0...13000) longText += "é"; longText += "\n```";
    conversation.put("content-turn", {id:"reply", type:"agentMessage", text:longText}, true);
    var reply:AgentActivityItem = null; for (value in conversation.items()) if (value.id == "reply") reply=value;
    require(reply != null && reply.truncated && reply.contentToken != null && reply.text.length <= 4096, "Long response preview or token missing");
    var offset = 0, assembled = haxe.io.Bytes.alloc(haxe.io.Bytes.ofString(longText).length);
    while (offset < assembled.length) {
      var chunk = conversation.content("content-turn", "reply", reply.contentToken, offset);
      if (chunk == null) throw "Missing content chunk";
      var part:workspace.service.WorkspaceAgentProtocol.AgentContentChunk = cast chunk;
      require(part.offset == offset && !part.partial && part.bytes.length <= 24*1024, "Invalid bounded content chunk");
      require(MessagePack.encode(part).length < 65536, "Content response exceeds relay frame");
      assembled.blit(offset,part.bytes,0,part.bytes.length); offset += part.bytes.length;
    }
    require(assembled.toString() == longText && assembled.toString().indexOf("\n```") > 4096, "Full closed fence did not survive chunk assembly");
    var streamed = new CodexConversation();
    streamed.put("stream-turn",{id:"stream",type:"agentMessage",text:""},false);
    var segment="z"; for (_ in 0...13) segment+=segment;
    streamed.delta("stream-turn","stream","agentMessage",segment);
    streamed.delta("stream-turn","stream","agentMessage","tail after clipped preview");
    streamed.finish("stream-turn","completed");
    var liveItem = streamed.items()[0], livePart=streamed.content("stream-turn","stream",liveItem.contentToken,0);
    require(livePart != null && livePart.bytes.toString() == segment + "tail after clipped preview", "Streaming used clipped preview instead of retained content");
    var prior = reply.contentToken;
    conversation.put("content-turn", {id:"reply", type:"agentMessage", text:longText+"updated"}, true);
    require(conversation.content("content-turn", "reply", prior, 0) == null, "Changed snapshot accepted a stale token");
    require(conversation.content("other-turn", "reply", prior, 0) == null, "Content escaped turn identity");
    var almost="x"; for (_ in 0...18) almost+=almost; almost=almost.substr(0,256*1024-1);
    var cacheToken=workspace.provider.AgentContentCache.replace("utf8-boundary",almost);
    cacheToken=workspace.provider.AgentContentCache.append("utf8-boundary","😀");
    cacheToken=workspace.provider.AgentContentCache.append("utf8-boundary","Z");
    var tail=workspace.provider.AgentContentCache.chunk("utf8-boundary",cacheToken,256*1024-2);
    require(tail != null && tail.partial && tail.total == 256*1024-1 && tail.bytes.toString() == "x", "Truncated UTF-8 prefix accepted later bytes");
    var oversize = "x"; for (_ in 0...19) oversize += oversize;
    conversation.put("content-turn", {id:"oversize", type:"agentMessage", text:oversize}, true);
    var big:AgentActivityItem = null; for (value in conversation.items()) if (value.id == "oversize") big=value;
    var partial = conversation.content("content-turn", "oversize", big.contentToken, 0);
    require(partial != null && partial.partial && partial.total == 256*1024, "Large content did not report bounded partial snapshot");
    trace("PASS: structured file associations, bounded patch slices, full-message chunks and legacy wire compatibility");
    return 0;
  }
}
