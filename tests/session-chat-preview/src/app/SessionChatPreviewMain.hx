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
  var width = args.indexOf("--wide") >= 0 ? 1000 : args.indexOf("--narrow") >= 0 ? 320 : 420;
  var options = new DesktopUiHostOptions();
  options.title = "Exosuit UI exploration";
  options.applicationId = "Exosuit.UiExploration";
  options.width = width; options.height = 900;
  return DesktopUiHost.run(options, function(host) return new PreviewApplication(host, dark, args));
 }
}

@:access(ui.CodexSessionPanel)
private class PreviewApplication implements DesktopUiApplication {
 final contextValue:UiContext;
 final panel:CodexSessionPanel;
 final agent:FakeAgent;
 final host:DesktopUiHostContext;
 var clickLabel:Null<String>;
 var workflowStep:Int = 0;
 var keyboardReview:Bool = false;
 var keyboardLabel:String = "Review request";
 var reviewFrames:Int = 0;
 var historyMode:Bool = false;
 var historyActivate:Bool = false;
 var historyFrames:Int = 0;
 var historyStarted:Float = 0;
 var sentImagePreview:Bool = false;
 var sentImageFrames:Int = 0;
 var menuItems:Null<Array<haxeon.ui.widgets.overlays.MenuItem>>;
 var menuLayer:Bool = false;
 var menuX:Float = 0;
 var menuY:Float = 0;
 var pendingPreview:Null<(Null<haxe.io.Bytes>, Null<String>)->Void>;
 public function new(host:DesktopUiHostContext, dark:Bool, args:Array<String>) {
  this.host = host;
  keyboardReview = args.indexOf("--review-request") >= 0;
  // Match the IDE's explicit monospace registration; system UI fallbacks alone
  // do not provide a monospace family in this standalone preview.
  host.fonts.add(Sys.getCwd() + "/haxeon/packages/ui/vendor/skribidi/example/data/IBMPlexMono-Regular.ttf", haxeon.ui.FontFamily.Monospace);
  if (args.indexOf("--tool-output") >= 0) {
   var mono = haxeon.ui.TextLayout.create(host.fonts, "iiiiWWWW", 200,
    new haxeon.ui.TextStyle(13, haxeon.ui.FontFamily.Monospace), new haxeon.ui.ParagraphStyle(haxeon.ui.TextWrap.None));
   var iWidth = mono.caret(new haxeon.ui.TextLayout.TextPosition(1, 0)).x - mono.caret(new haxeon.ui.TextLayout.TextPosition(0, 0)).x;
   var wWidth = mono.caret(new haxeon.ui.TextLayout.TextPosition(5, 0)).x - mono.caret(new haxeon.ui.TextLayout.TextPosition(4, 0)).x;
   mono.dispose();
   if (Math.abs(iWidth - wWidth) > 0.05 || iWidth <= 0) throw "Preview monospace face has unequal advances";
   Sys.println("PASS: native monospace i/W advances " + iWidth + " / " + wWidth);
  }
  contextValue = new UiContext(null, host.fonts, ui.ExosuitPalette.theme(dark));
  contextValue.setStyleSheet(ui.ExosuitPalette.styleSheet(contextValue.buildContext.theme, dark));
  agent = new FakeAgent();
  agent.view.items = [
   {id:"user",turn:"turn",kind:"userMessage",title:"",text:"Please inspect this project and explain the change.",detail:"",state:"completed",truncated:false},
   {id:"tool",turn:"turn",kind:"commandExecution",title:"Run tests",text:"",detail:"Running the test suite",state:"completed",truncated:false},
   {id:"assistant",turn:"turn",kind:"agentMessage",title:"",text:"## Findings\n\nThe project is ready for review. The key change is in `src/app.hx`.\n\n```haxe\ntrace(\"Hello from Exosuit\");\n```",detail:"",state:"completed",truncated:false}
  ];
  historyMode = args.indexOf("--history") >= 0;
  historyActivate = args.indexOf("--history-loaded") >= 0;
  if (historyMode) {
   agent.history.hasOlder = true;
   agent.view.items = [for (i in 0...12) {id:"history-" + i,turn:"turn",kind:"agentMessage",title:"",text:"Current page message " + (i + 1) + ": the visible conversation stays in place.",detail:"",state:"completed",truncated:false}];
   host.onPoll = function() {
    if (agent.historyDone != null && historyStarted > 0 && Sys.time() - historyStarted > 0.3) {
     var before:Array<workspace.service.WorkspaceAgentProtocol.AgentActivityItem> = cast agent.view.items;
     var older:Array<workspace.service.WorkspaceAgentProtocol.AgentActivityItem> = [for (i in 0...5) {id:"old-" + i,turn:"turn",kind:"agentMessage",title:"",text:"Earlier page message " + (i + 1),detail:"",state:"completed",truncated:false}];
     agent.view.items = older.concat(before); agent.history.loading = false; agent.history.hasOlder = false;
     var done:Null<String>->Void = cast agent.historyDone; agent.historyDone = null; done(null); host.requestFrame();
    }
   };
  }
  if (args.indexOf("--sent-image") >= 0) {
   sentImagePreview = args.indexOf("--sent-image-preview") >= 0;
   agent.view.items = [
    {id:"sent-user",turn:"sent-turn",kind:"userMessage",title:"",text:"Please review this image.",detail:"",state:"completed",truncated:false,images:[{id:"opaque-image-fixture"}]},
    {id:"sent-reply",turn:"sent-turn",kind:"agentMessage",title:"",text:"I can inspect the attached image.",detail:"",state:"completed",truncated:false}
   ];
   host.onPoll = function() {
    if (agent.pendingImage != null) {
     var done:(Null<haxe.io.Bytes>,Null<String>)->Void = cast agent.pendingImage; agent.pendingImage = null;
     if (agent.imageRequestIdentity != "session:sent-turn:sent-user:opaque-image-fixture") done(null,"Image identity mismatch");
     else done(sys.io.File.getBytes(Sys.getCwd()+"/graphical/assets/icons/exosuit-256.png"),null);
    }
   };
  }
  if (args.indexOf("--emphasis") >= 0) agent.view.items = [
   {id:"emphasis",turn:"turn",kind:"agentMessage",title:"",text:"## Review summary\n\nThis is normal text, **strong emphasis**, *italic emphasis*, and ***bold italic***.\n\nThe **important [linked result](src/Main.hx)** remains actionable.",detail:"",state:"completed",truncated:false}
  ];
  if (args.indexOf("--tool-output") >= 0) {
   var commandFailed = args.indexOf("--tool-failed") >= 0;
   agent.view.items = [
    {id:"command",turn:"turn",kind:"commandExecution",title:"Run command",text:"npm run test -- --verbose",detail:commandFailed ? "cwd: /workspace/project\nexit: 1\n\nFAIL src/example.test.ts\nTests: 1 failed" : "cwd: /workspace/project\nexit: 0\n\n> test\niiiiiiiiiiii\nWWWWWWWWWWWW\nPASS src/example.test.ts\n  ✓ preserves a long output line with details that should remain horizontally scrollable\n\nTests: 1 passed",state:commandFailed ? "failed" : "completed",truncated:false}
   ];
   clickLabel = "Show details";
  }
  var nativeImagePlan = args.indexOf("--native-image-plan") >= 0;
  if (nativeImagePlan) {
   agent.view.items = [
    {id:"plan",turn:"turn",kind:"plan",title:"Plan",text:"## Implementation plan\n\nFirst **inspect** the source, then *verify* the result.",detail:"",state:"completed",truncated:false},
    {id:"generated",turn:"turn",kind:"imageGeneration",title:"Generated image",text:"",detail:"",state:"completed",truncated:false,imagePath:"/repo/generated.png"}
   ];
   clickLabel = "Preview image";
  }
  var inlineImages = args.indexOf("--inline-images") >= 0;
  var remoteImage = args.indexOf("--remote-image") >= 0;
  if ((inlineImages && remoteImage) || nativeImagePlan) host.onPoll = function() {
   if (pendingPreview != null) {
    var done:(Null<haxe.io.Bytes>, Null<String>)->Void = cast pendingPreview; pendingPreview=null;
    done(sys.io.File.getBytes(Sys.getCwd()+"/graphical/assets/icons/exosuit-256.png"),null);
   }
  };
  if (inlineImages) {
   var imagePath=Sys.getCwd()+"/graphical/assets/icons/exosuit-256.png";
   var imageDestination=remoteImage ? "fixture-remote.png" : "data:image/png;base64,"+haxe.crypto.Base64.encode(sys.io.File.getBytes(imagePath));
   agent.view.items = [
    {id:"user",turn:"turn",kind:"userMessage",title:"",text:"Show the project icon in context.",detail:"",state:"completed",truncated:false},
    {id:"assistant",turn:"turn",kind:"agentMessage",title:"",text:"Here is the project icon ![Exosuit icon]("+imageDestination+") and the surrounding explanation stays visible.",detail:"",state:"completed",truncated:false}
   ];
   clickLabel="Preview image";
  } else if (args.indexOf("--diff") >= 0 || args.indexOf("--rich") >= 0 || args.indexOf("--summary") >= 0) {
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
  if (args.indexOf("--questions") >= 0) {
   agent.view.items = [{id:"assistant",turn:"turn",kind:"agentMessage",title:"",text:"Before I continue, I need your preferences.",detail:"",state:"completed",truncated:false}];
   agent.view.requests=[{id:"question-fixture",method:"item/tool/requestUserInput",detail:"Select your preferences",reviewable:true,questions:[
    {id:"approach",header:"Approach",question:"How should I make the change?",multiple:false,secret:false,allowOther:true,
     options:[{label:"Minimal",description:"Keep the scope focused"},{label:"Thorough",description:"Include related cleanup"}]},
    {id:"checks",header:"Validation",question:"Which checks should I run?",multiple:true,secret:false,allowOther:true,
     options:[{label:"Build",description:"Compile the application"},{label:"Tests",description:"Run the test suite"}]}
   ]}];
  }
  if (args.indexOf("--pi-choice") >= 0) {
   agent.record.provider="pi";
   agent.view.items=[{id:"assistant",turn:"turn",kind:"agentMessage",title:"",text:"Select a deployment target.",detail:"",state:"completed",truncated:false}];
   agent.view.requests=[{id:"pi-select",method:"item/tool/requestUserInput",detail:"Choose one destination",reviewable:true,
    inputKind:"select",options:["Development","Staging","Production"]}];
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
  var workflow = args.indexOf("--workflow") >= 0 || args.indexOf("--repository-menu") >= 0;
  var composerPreview = args.indexOf("--composer") >= 0;
  var workspaceCapabilities = workflow || composerPreview;
  menuLayer = workflow;
  if (composerPreview) {
   agent.view.supportsImageUpload = true; agent.uploadEnabled = true;
   agent.view.models = [{model:"fixture-model", name:"Codex model", supportedEfforts:["low", "medium", "high"]}];
   agent.view.currentModel = "fixture-model"; agent.view.currentEffort = "high";
  }
  if (workflow) {
   agent.view.supportsImageUpload = true;
   agent.uploadEnabled = true;
   workflowStep = 1;
   clickLabel = "Add image";
  }
  if (args.indexOf("--repository-menu") >= 0) { workflowStep = 0; clickLabel = null; keyboardReview = true; keyboardLabel = "Repository actions"; }
  panel = new CodexSessionPanel(function() return agent, "session", "/repo", host.requestFrame,
   dark ? new style.Theme() : ui.ExosuitPalette.lightEditor(), new syntax.SyntaxRegistry(), function(items, event, valid) {
    if (valid()) {
     menuX=event.x; menuY=event.y;
     if (contextValue.root != null && (event.kind == UiEventKind.KeyDown || event.kind == UiEventKind.Activate)) {
      var trigger=contextValue.root.find(event.target);
      if (trigger != null && trigger.resolved != null) { var bounds=trigger.globalBounds(); menuX=bounds.x; menuY=bounds.y+bounds.height; }
     }
     menuItems = items; host.requestFrame();
    }
   }, function(_) {},
   function(_) {}, {context: function() return "/workspace/exosuit · ui-exploration", explore: function() {}, reviewChanges: function() {},
    resolveImage: function(path) return path == "fixture-icon.png" ? Sys.getCwd() + "/graphical/assets/icons/exosuit-256.png" : null,
    loadImage: (inlineImages && remoteImage) || nativeImagePlan ? function(path,done) {
     if (path == "fixture-remote.png" || (nativeImagePlan && path == "/repo/generated.png")) pendingPreview=done;
     else done(null,"Image unavailable");
    } : null,
    readContext: workspaceCapabilities ? function(_, done) done("class Main {}", null) : null,
    chooseImage: workspaceCapabilities ? function(done) done("diagram.png", sys.io.File.getBytes(Sys.getCwd() + "/graphical/assets/icons/exosuit-256.png"), null) : null,
    canCreateWorktree: workspaceCapabilities ? function() return true : null, newWorktree: workspaceCapabilities ? function() {} : null,
    canCommitChanges: workflow ? function() return true : null, commitChanges: workflow ? function() {} : null,
    canOpenGithub: workflow ? function() return true : null, githubRepository: workflow ? function() {} : null,
    canOpenPullRequest: workflow ? function() return true : null, githubPullRequest: workflow ? function() {} : null,
    previewArtifact: renderHtml || renderSvg ? function(_, source) {
     if (!ui.SessionArtifactPreview.open(host.window.rawValue(), source)) throw "Native artifact preview unavailable";
    } : null});
  if (composerPreview) panel.prompt = "Can you review the changes and run the relevant tests?";
 }
 public function context():UiContext return contextValue;
 public function submit(frame:LayoutFrame):RenderNode {
  var view:haxeon.ui.core.View = panel;
  if (menuLayer) {
   var layers:Array<haxeon.ui.widgets.layout.StackChild> = [new haxeon.ui.widgets.layout.StackChild("content",panel,0,0,0,haxeon.ui.LayoutAxis.grow(),haxeon.ui.LayoutAxis.grow())];
   if (menuItems != null) layers.push(new haxeon.ui.widgets.layout.StackChild("menu",new haxeon.ui.widgets.overlays.Menu("preview-repository",menuItems,menuX,menuY,function() {menuItems=null;host.requestFrame();}),0,0,40));
   view = new haxeon.ui.widgets.layout.Stack("preview-overlay",layers);
  }
  var root = contextValue.submit(view, frame);
  if (sentImagePreview) {
   sentImageFrames++;
   if (sentImageFrames < 4) host.requestFrame();
   else {
    var preview:RenderNode = null;
    root.walk(function(node) { if (preview == null && node.semantics != null && node.semantics.label == "Preview image") preview = node; });
    if (preview != null && contextValue.focusWidget(preview.id)) {
     sentImagePreview = false; contextValue.key(UiEventKind.KeyDown, haxeon.ui.core.UiKey.Enter); host.requestFrame();
    }
   }
  }
  if (historyMode && historyFrames < 8) {
   historyFrames++;
   if (historyFrames == 3) panel.transcriptScroll.jumpTo(0, 0);
   if (historyFrames == 6 && historyActivate) {
    var load:RenderNode = null;
    root.walk(function(node) { if (load == null && node.semantics != null && node.semantics.label == "Load earlier messages") load = node; });
    if (load != null && contextValue.focusWidget(load.id)) {
     historyStarted = Sys.time(); contextValue.key(UiEventKind.KeyDown, haxeon.ui.core.UiKey.Enter);
    }
   }
   host.requestFrame();
  }
  if (keyboardReview) {
   reviewFrames++;
   if (reviewFrames < 4) host.requestFrame();
   else {
    var review:RenderNode = null;
    root.walk(function(node) { if (review == null && node.semantics != null && node.semantics.label == keyboardLabel) review = node; });
    if (review != null && contextValue.focusWidget(review.id)) {
     keyboardReview = false;
     contextValue.key(UiEventKind.KeyDown, haxeon.ui.core.UiKey.Enter);
     host.requestFrame();
    }
   }
  }
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
