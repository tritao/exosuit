package app;

import haxeon.ui.LayoutFrame;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.UiContext;
import haxeon.ui.host.DesktopUiApplication;
import haxeon.ui.host.DesktopUiHost;
import haxeon.ui.host.DesktopUiHostContext;
import haxeon.ui.host.DesktopUiHostOptions;
import ui.CodexSessionPanel;

/** Deterministic native fixture for guarded, serialized visual capture. */
class SessionChatPreviewMain {
 static function main():Int {
  var args = Sys.args();
  var dark = args.indexOf("--light") < 0;
  var width = args.indexOf("--wide") >= 0 ? 1000 : 420;
  var options = new DesktopUiHostOptions();
  options.title = "Exosuit UI exploration";
  options.applicationId = "Exosuit.UiExploration";
  options.width = width; options.height = 900;
  return DesktopUiHost.run(options, function(host) return new PreviewApplication(host, dark, args));
 }
}

private class PreviewApplication implements DesktopUiApplication {
 final contextValue:UiContext;
 final panel:CodexSessionPanel;
 final agent:FakeAgent;
 final host:DesktopUiHostContext;
 var clickLabel:Null<String>;
 public function new(host:DesktopUiHostContext, dark:Bool, args:Array<String>) {
  this.host = host;
  contextValue = new UiContext(null, host.fonts, ui.ExosuitPalette.theme(dark));
  contextValue.setStyleSheet(ui.ExosuitPalette.styleSheet(contextValue.buildContext.theme, dark));
  agent = new FakeAgent();
  agent.view.items = [
   {id:"user",turn:"turn",kind:"userMessage",title:"",text:"Please inspect this project and explain the change.",detail:"",state:"completed",truncated:false},
   {id:"tool",turn:"turn",kind:"commandExecution",title:"Run tests",text:"",detail:"Running the test suite",state:"completed",truncated:false},
   {id:"assistant",turn:"turn",kind:"agentMessage",title:"",text:"## Findings\n\nThe project is ready for review. The key change is in `src/app.hx`.\n\n```haxe\ntrace(\"Hello from Exosuit\");\n```",detail:"",state:"completed",truncated:false}
  ];
  if (args.indexOf("--diff") >= 0 || args.indexOf("--rich") >= 0 || args.indexOf("--summary") >= 0) {
   var first = "--- a/src/Main.hx\n+++ b/src/Main.hx\n@@ -1,2 +1,2 @@\n-old()\n+new()\n";
   var second = "--- a/README.md\n+++ b/README.md\n@@ -1 +1 @@\n-old docs\n+new docs\n";
   agent.view.items = [
    {id:"user",turn:"turn",kind:"userMessage",title:"",text:"Review these changes.",detail:"",state:"completed",truncated:false},
    {id:"change",turn:"turn",kind:"fileChange",title:"Changed files",text:"",detail:first + second,state:"completed",truncated:false,
     files:[{path:"src/Main.hx",kind:"update",offset:0,length:first.length,truncated:false},
      {path:"README.md",kind:"update",offset:first.length,length:second.length,truncated:false}]},
    {id:"assistant",turn:"turn",kind:"agentMessage",title:"",text:"Summary:\n\n```diff\n@@ -1 +1 @@\n-old\n+new\n```",detail:"",state:"completed",truncated:false}
   ];
   if (args.indexOf("--summary") < 0) clickLabel = "Show details";
  } else if (args.indexOf("--image") >= 0) {
   agent.view.items = [
    {id:"user",turn:"turn",kind:"userMessage",title:"",text:"Show the project icon.",detail:"",state:"completed",truncated:false},
    {id:"assistant",turn:"turn",kind:"agentMessage",title:"",text:"Here is the icon:\n\n![Exosuit icon](fixture-icon.png)",detail:"",state:"completed",truncated:false}
   ];
   if (args.indexOf("--load-image") >= 0) clickLabel = "Preview image";
  }
  if (args.indexOf("--models") >= 0) clickLabel = "Conversation model";
  panel = new CodexSessionPanel(function() return agent, "session", "/repo", host.requestFrame,
   dark ? new style.Theme() : ui.ExosuitPalette.lightEditor(), new syntax.SyntaxRegistry(), null, function(_) {},
   function(_) {}, {context: function() return "/workspace/exosuit · ui-exploration", explore: function() {}, reviewChanges: function() {},
    resolveImage: function(path) return path == "fixture-icon.png" ? Sys.getCwd() + "/graphical/assets/icons/exosuit-256.png" : null});
 }
 public function context():UiContext return contextValue;
 public function submit(frame:LayoutFrame):RenderNode {
  var root = contextValue.submit(panel, frame);
  var label = clickLabel;
  if (label != null) {
   var target:RenderNode = null;
   root.walk(function(node) { if (target == null && node.semantics != null && node.semantics.label == label) target = node; });
   if (target != null) {
    clickLabel = null;
    var bounds = target.globalBounds();
    contextValue.pointerDown(bounds.x + bounds.width / 2, bounds.y + bounds.height / 2, 0);
    contextValue.pointerUp(bounds.x + bounds.width / 2, bounds.y + bounds.height / 2, 0);
    host.requestFrame();
   }
  }
  return root;
 }
 public function diagnosticState():Dynamic return {};
 public function dispose():Void contextValue.dispose();
}
