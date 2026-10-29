package app;

import haxeon.ui.FontCollection;
import haxeon.ui.LayoutFrame;
import haxeon.ui.LayoutSession;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.UiContext;
import ui.SessionDiffView;

@:access(ui.CodexMarkdownView)
@:access(ui.SessionDiffView)
class SessionDiffRegressionMain {
  static function find(root:RenderNode, label:String):RenderNode {
    var found:RenderNode = null;
    root.walk(function(node) { if (found == null && node.semantics != null && node.semantics.label == label) found = node; });
    if (found == null) throw "Missing: " + label;
    return found;
  }
  static function main():Int {
    var fonts = FontCollection.create();
    fonts.add("../../haxeon/packages/ui/vendor/skribidi/example/data/IBMPlexSans-Regular.ttf");
    var session = LayoutSession.create(), context = new UiContext(session, fonts);
    var first = "--- a/first.txt\n+++ b/first.txt\n@@ -1 +1 @@\n-old first\n+new first\n";
    var second = "--- a/second.txt\n+++ b/second.txt\n@@ -1 +1 @@\n-old second\n+new second\n";
    var opened:Null<String> = null;
    var view = new SessionDiffView(first + second, function(path) opened = path, [
      {path:"first.txt",kind:"update",offset:0,length:first.length,truncated:false},
      {path:"second.txt",kind:"update",offset:999999,length:second.length,truncated:false}
    ]);
    var root = context.submit(view, new LayoutFrame(800, 1400));
    find(root, "Full patch · file metadata incomplete");
    find(root, "Diff line 4");
    var rawPresent = false;
    root.walk(function(node) {
      var semantics = node.semantics;
      if (semantics != null) {
        var value = semantics.value;
        if (value != null && value.indexOf("+new second") >= 0) rawPresent = true;
      }
    });
    if (!rawPresent) throw "Missing unmatched patch in fallback";
    var open = find(root, "Open file"), bounds = open.globalBounds();
    context.pointerDown(bounds.x + bounds.width / 2, bounds.y + bounds.height / 2, 0);
    context.pointerUp(bounds.x + bounds.width / 2, bounds.y + bounds.height / 2, 0);
    if (opened != "first.txt") throw "Valid file association was lost";
    var rawPatch = "--- a/file.txt\r\n+++ b/file.txt\r\n@@ -1 +1 @@\r\n-old\r\n+new\r\n";
    var markdown = new ui.CodexMarkdownView("```diff\r\n" + rawPatch + "```\r\n", new style.Theme(), new syntax.SyntaxRegistry());
    context.submit(markdown, new LayoutFrame(800, 1400));
    var projected = markdown.diffs.get("block-0");
    if (projected == null || projected.copySource != rawPatch || projected.source.indexOf("\r") >= 0)
      throw "Diff copy source lost CRLF or trailing newline";
    var streaming = "@@ -1 +1 @@\r\n-old\r\n+new";
    markdown.update("```patch\r\n" + streaming);
    context.submit(markdown, new LayoutFrame(800, 1400));
    if (projected.copySource != streaming) throw "Streaming diff copy source was not updated";
    var conversation = new workspace.provider.CodexConversation();
    var large = StringTools.rpad("@@ -1 +1 @@\n-old\n+", "x", 3000);
    conversation.put("turn", {id:"changes", type:"fileChange", changes:[
      {path:"first.txt", kind:{type:"update"}, diff:large},
      {path:"second.txt", kind:{type:"update"}, diff:second}
    ]}, true);
    var item = conversation.items()[0];
    if (item.files == null || item.files.length != 2 || item.files[1].path != "second.txt"
      || item.files[1].length != 0 || item.files[1].offset != item.detail.length || !item.files[1].truncated
      || item.detail.length > 2048 || !item.truncated) throw "Patch budget hid later file summaries";
    root = context.submit(new ui.SessionChangeSummaryView(item.files, item.detail), new LayoutFrame(800, 1400));
    find(root, "update  ·  partial  ·  preview unavailable");
    context.dispose(); session.dispose(); fonts.dispose();
    return 0;
  }
}
