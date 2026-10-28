package app;

import haxeon.ui.LayoutFrame;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.UiContext;
import haxeon.ui.core.UiEventKind;
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
 var workflowStep:Int = 0;
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
  } else if (args.indexOf("--svg") >= 0) {
   agent.view.items = [
    {id:"user",turn:"turn",kind:"userMessage",title:"",text:"Draw a simple diagram.",detail:"",state:"completed",truncated:false},
    {id:"assistant",turn:"turn",kind:"agentMessage",title:"",text:"Here is the SVG:\n\n```svg\n<svg viewBox=\"0 0 100 60\"><rect x=\"5\" y=\"5\" width=\"90\" height=\"50\" fill=\"#3468cf\"/><circle cx=\"50\" cy=\"30\" r=\"17\" fill=\"white\"/><path d=\"M 32 30 L 45 42 L 70 17\" fill=\"none\" stroke=\"#3468cf\" stroke-width=\"4\"/></svg>\n```",detail:"",state:"completed",truncated:false}
   ];
   clickLabel = "Preview SVG";
  } else if (args.indexOf("--artifact") >= 0) {
   agent.view.items = [
    {id:"user",turn:"turn",kind:"userMessage",title:"",text:"Draft a small page.",detail:"",state:"completed",truncated:false},
    {id:"assistant",turn:"turn",kind:"agentMessage",title:"",text:"Here is the source:\n\n```html\n<!doctype html>\n<h1>Hello, Exosuit</h1>\n```",detail:"",state:"completed",truncated:false}
   ];
   if (args.indexOf("--expand-artifact") >= 0) clickLabel = "Show source";
  }
  if (args.indexOf("--models") >= 0) clickLabel = "Conversation model";
  var renderHtml = args.indexOf("--render-html") >= 0;
  var renderSvg = args.indexOf("--render-svg") >= 0;
  if (renderSvg) agent.view.items = [
   {id:"assistant",turn:"turn",kind:"agentMessage",title:"",text:"```svg\n<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 360 200\"><defs><linearGradient id=\"g\"><stop stop-color=\"#3869db\"/><stop offset=\"1\" stop-color=\"#6ad7d1\"/></linearGradient><rect id=\"tile\" width=\"100\" height=\"70\" rx=\"12\" fill=\"url(#g)\"/></defs><use href=\"#tile\" x=\"35\" y=\"35\"/><use href=\"#tile\" transform=\"translate(160 35) rotate(8 50 35)\"/><text x=\"35\" y=\"160\" font-size=\"24\">SVG gradients and reuse</text></svg>\n```",detail:"",state:"completed",truncated:false}
  ];
  if (renderHtml || renderSvg) {
   clickLabel = renderSvg ? "Open static SVG" : "Preview HTML";
   var started = Sys.time();
   host.onPoll = function() { if (Sys.time() - started > 12) host.requestClose(); };
  }
  var workflow = args.indexOf("--workflow") >= 0;
  if (workflow) {
   agent.view.supportsImageUpload = true;
   agent.uploadEnabled = true;
   workflowStep = 1;
   clickLabel = "Add image";
  }
  panel = new CodexSessionPanel(function() return agent, "session", "/repo", host.requestFrame,
   dark ? new style.Theme() : ui.ExosuitPalette.lightEditor(), new syntax.SyntaxRegistry(), null, function(_) {},
   function(_) {}, {context: function() return "/workspace/exosuit · ui-exploration", explore: function() {}, reviewChanges: function() {},
    resolveImage: function(path) return path == "fixture-icon.png" ? Sys.getCwd() + "/graphical/assets/icons/exosuit-256.png" : null,
    readContext: workflow ? function(_, done) done("class Main {}", null) : null,
    chooseImage: workflow ? function(done) done("diagram.png", sys.io.File.getBytes(Sys.getCwd() + "/graphical/assets/icons/exosuit-256.png"), null) : null,
    canCreateWorktree: workflow ? function() return true : null, newWorktree: workflow ? function() {} : null,
    canOpenGithub: workflow ? function() return true : null, githubRepository: workflow ? function() {} : null,
    canOpenPullRequest: workflow ? function() return true : null, githubPullRequest: workflow ? function() {} : null,
    previewArtifact: renderHtml || renderSvg ? function(_, source) {
     if (!ui.SessionArtifactPreview.open(host.window.rawValue(), source)) throw "Native artifact preview unavailable";
    } : null});
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
    if (workflowStep == 1) { workflowStep = 2; clickLabel = "Add workspace text"; }
    else if (workflowStep == 2) { workflowStep = 3; }
    else if (workflowStep == 4) { workflowStep = 0; }
    host.requestFrame();
   }
  }
  if (workflowStep == 3 && clickLabel == null) {
   var field:RenderNode = null;
   root.walk(function(node) { if (field == null && node.semantics != null && node.semantics.label == "Workspace text path") field = node; });
   if (field != null && contextValue.focusWidget(field.id)) {
    contextValue.text(UiEventKind.TextInput, "src/Main.hx");
    workflowStep = 4; clickLabel = "Include text"; host.requestFrame();
   }
  }
  return root;
 }
 public function diagnosticState():Dynamic return {};
 public function dispose():Void contextValue.dispose();
}
