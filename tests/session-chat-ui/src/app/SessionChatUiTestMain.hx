package app;

import haxeon.ui.FontCollection;
import haxeon.ui.LayoutFrame;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.UiContext;
import haxeon.ui.core.UiEventKind;
import haxeon.ui.core.UiKey;
import haxeon.ui.core.UiModifier;
import haxeon.ui.semantics.AccessibilityRole;
import workspace.client.WorkspaceAgentClient;
import workspace.client.AgentSessionDefaults;
import workspace.service.WorkspaceAgentProtocol;
import ui.CodexSessionPanel;


@:access(app.ButtonThemeTestMain)
@:access(app.CodexMarkdownLayoutMain)
@:access(app.SidebarLayoutTestMain)
@:access(app.StatusBarTestMain)
@:access(haxeon.ui.core.StateStore)
@:access(ui.CodexMarkdownView)
@:access(ui.CodexSessionPanel)
class SessionChatUiTestMain {
	static function require(value:Bool, message:String):Void { if (!value) throw message; }
	static function find(root:RenderNode, label:String):RenderNode {
		var found:RenderNode = null;
		root.walk(function(node) { if (found == null && node.semantics != null && node.semantics.label == label) found = node; });
		if (found == null) throw "Missing control: " + label;
		return found;
	}
	static function click(context:UiContext, node:RenderNode, width:Float, height:Float):Void {
		var b = node.globalBounds();
		var semantics:haxeon.ui.semantics.Semantics = cast node.semantics;
		require(b.width >= 20 && b.height >= 20 && b.x >= -0.1 && b.x + b.width <= width + 0.1
			&& b.y >= -0.1 && b.y + b.height <= height + 0.1, "Control outside viewport: " + semantics.label + " " + b.x + "," + b.y + "," + b.width + "," + b.height + " in " + width + "x" + height);
		context.pointerDown(b.x + b.width / 2, b.y + b.height / 2, 0);
		context.pointerUp(b.x + b.width / 2, b.y + b.height / 2, 0);
	}
	static function checkHorizontalBounds(root:RenderNode, width:Float):Void {
		root.walk(function(node) {
			if (!node.layout.style.visible || !node.focusable || node.resolved == null) return;
			var b = node.globalBounds();
			var semantics:haxeon.ui.semantics.Semantics = cast node.semantics;
			require(b.x >= -0.1 && b.x + b.width <= width + 0.1,
				"Horizontal overflow at " + width + ": " + (semantics == null ? node.styleType : semantics.label) + " " + b.x + "," + b.width);
		});
	}
	static function main():Int {
		for (remote in ["https://github.com/example/project.git", "git@github.com:example/project.git", "ssh://git@github.com/example/project"])
			require(scm.GithubRemote.repository(remote) == "https://github.com/example/project", "GitHub origin parsing failed");
		for (remote in ["https://user:secret@github.com/example/project", "https://github.com.evil.test/example/project", "https://github.com/example/project?token=x", "file:///tmp/project"])
			require(scm.GithubRemote.repository(remote) == null, "Unsafe GitHub origin accepted");
		require(scm.GithubRemote.pullRequestPage("https://github.com/example/project", "feature/name") == "https://github.com/example/project/compare/feature%2Fname?expand=1", "Branch was not encoded for GitHub");
		require(scm.GithubRemote.pullRequestPage("https://evil.test/x/y", "main") == null
			&& scm.GithubRemote.pullRequestPage("https://github.com/example/project", "bad\nbranch") == null, "Unsafe pull request URL accepted");
		ButtonThemeTestMain.main();
		SidebarLayoutTestMain.main();
		StatusBarTestMain.main();
		CodexMarkdownLayoutMain.main();
		SessionProjectionTestMain.main();
		var fonts = FontCollection.create();
		fonts.add("../../haxeon/packages/ui/vendor/skribidi/example/data/IBMPlexSans-Regular.ttf");
		SessionQuestionFormTest.run(fonts);
		for (dark in [true, false]) for (width in [320.0, 420.0, 1000.0]) {
			var height = 900.0, client = new FakeAgent(), menu:Array<haxeon.ui.widgets.overlays.MenuItem> = null;
			var opened:String = null, files = 0, changes = 0;
			var context = new UiContext(null, fonts, ui.ExosuitPalette.theme(dark));
			context.setStyleSheet(ui.ExosuitPalette.styleSheet(context.buildContext.theme, dark));
			var panel = new CodexSessionPanel(function() return client, "session", "/repo", function() {},
				dark ? new style.Theme() : ui.ExosuitPalette.lightEditor(), new syntax.SyntaxRegistry(),
				function(items, _, _) menu = items, function(_) {}, function(link) opened = link,
				{context:function() return "Project", explore:function() files++, reviewChanges:function() changes++});
			function build():RenderNode return context.submit(panel, new LayoutFrame(width, height));
			var root = build();
			checkHorizontalBounds(root, width);
			find(root, "You"); find(root, "Codex"); find(root, "Copy message");
			click(context, find(root, "Files"), width, height);
			click(context, find(root, "Review changes"), width, height);
			require(files == 1 && changes == 1, "Workspace navigation did not reach callbacks");
			click(context, find(root, "useful result"), width, height);
			require(opened == "src/Main.hx:12", "Session link did not route its destination");
			var field = find(root, "Codex prompt");
			require(context.focusWidget(field.id), "Cannot focus composer");
			context.text(UiEventKind.TextInput, "Hello agent");
			root = build();
			click(context, find(root, "Send"), width, height);
			require(client.actions.indexOf("prompt:Hello agent:null") >= 0, "Send did not deliver composer text");
			root = build();
			click(context, find(root, "Permissions · " + workspace.client.CodexPermissions.labelForRecord(null, null, null) + "  ▾"), width, height);
			require(menu != null && menu.length > 0, "Permissions menu did not open");
			root = build();
			click(context, find(root, "Conversation model"), width, height);
			root = build();
			click(context, find(root, "Test model"), width, height);
			require(client.chosenModel == "test-model", "Model choice did not reach provider");
			client.record.state = "working";
			root = build();
			click(context, find(root, "Stop"), width, height);
			require(client.actions.indexOf("stop::null") >= 0, "Stop did not reach provider");
			client.record.state = "idle";
			client.view.requests = [{id:"approval", method:"item/commandExecution/requestApproval", detail:"Run tests", reviewable:true}];
			root = build();
			click(context, find(root, "Approve once"), width, height);
			require(client.actions.indexOf("approve::approval") >= 0, "Approval did not reach provider");
			click(context, find(root, "Decline"), width, height);
			require(client.actions.indexOf("decline::approval") >= 0, "Decline did not reach provider");
			context.dispose();
		}
		for (provider in ["claude", "pi"]) {
			var client = new FakeAgent(); client.record.provider = provider;
			client.record.permissionMode = provider == "pi" ? "supervised" : "default";
			var context = new UiContext(null, fonts, ui.ExosuitPalette.theme(true));
			context.setStyleSheet(ui.ExosuitPalette.styleSheet(context.buildContext.theme, true));
			var panel = new CodexSessionPanel(function() return client, "session", "/repo", function() {},
				new style.Theme(), new syntax.SyntaxRegistry(), function(_, _, _) {}, function(_) {});
			function build():RenderNode return context.submit(panel, new LayoutFrame(1000, 900));
			var root = build(), field = find(root, provider == "pi" ? "Pi prompt" : "Claude prompt");
			require(context.focusWidget(field.id), "Cannot focus provider prompt");
			context.text(UiEventKind.TextInput, "First line");
			context.key(UiEventKind.KeyDown, UiKey.Enter, UiModifier.Shift);
			context.text(UiEventKind.TextInput, "Second line");
			root = build();
			client.acceptActions = false;
			context.key(UiEventKind.KeyDown, UiKey.Enter);
			require(client.actions.indexOf("prompt:First line\nSecond line:null") >= 0, "Enter/Shift+Enter lost multiline prompt");
			root = build();
			var promptSemantics:haxeon.ui.semantics.Semantics = cast find(root, provider == "pi" ? "Pi prompt" : "Claude prompt").semantics;
			require(promptSemantics.value == "First line\nSecond line", "Rejected prompt was cleared");
			if (provider == "pi") {
				client.record.state = "working"; client.view.supportsQueue = true; client.view.supportsSteering = true; client.view.inputToken = "token";
				root = build();
				click(context, find(root, "Queue message"), 1000, 900);
				click(context, find(root, "Steer now"), 1000, 900);
				require(client.actions.indexOf("queue:First line\nSecond line:null") >= 0, "Queue did not preserve the draft");
				require(client.actions.indexOf("steer:First line\nSecond line:null") >= 0, "Steer did not preserve the draft");
			}
			client.control = false; root = build();
			require(!find(root, provider == "pi" ? "Pi prompt" : "Claude prompt").enabled, "Read-only prompt remained enabled");
			client.control = true; client.view.connectionState = "disconnected"; root = build();
			require(!find(root, provider == "pi" ? "Pi prompt" : "Claude prompt").enabled, "Disconnected prompt remained enabled");
			context.dispose();
		}
		var answerClient = new FakeAgent();
		answerClient.view.requests = [{id:"question", method:"item/tool/requestUserInput", detail:"Choose", reviewable:true, inputKind:"text"}];
		var answerContext = new UiContext(null, fonts, ui.ExosuitPalette.theme(true));
		var commits = 0, mayCommit = true;
		var answerPanel = new CodexSessionPanel(function() return answerClient, "session", "/repo", function() {},
			new style.Theme(), new syntax.SyntaxRegistry(), function(_, _, _) {}, function(_) {}, null,
			{context:function() return "Project", explore:function() {}, reviewChanges:function() {},
			 canCommitChanges:function() return mayCommit, commitChanges:function() commits++});
		function answerBuild():RenderNode return answerContext.submit(answerPanel, new LayoutFrame(1000, 900));
		var answerRoot = answerBuild();
		click(answerContext, find(answerRoot, "Commit changes"), 1000, 900);
		require(commits == 1 && answerClient.actions.length == 0, "Commit navigation performed an agent action");
		mayCommit = false; answerRoot = answerBuild();
		var foundCommit = false; answerRoot.walk(function(node) { if (node.semantics != null && node.semantics.label == "Commit changes") foundCommit = true; });
		require(!foundCommit, "Unavailable commit action was shown");
		require(answerContext.focusWidget(find(answerRoot, "Codex prompt").id), "Cannot focus answer draft");
		answerContext.text(UiEventKind.TextInput, "My answer"); answerRoot = answerBuild();
		answerClient.acceptActions = false;
		click(answerContext, find(answerRoot, "Answer using prompt"), 1000, 900);
		require(answerClient.actions.indexOf("answer:My answer:question") >= 0 && answerPanel.prompt == "My answer", "Rejected answer lost draft or request identity");
		answerClient.acceptActions = true; answerClient.deferAcceptance = true;
		answerRoot = answerBuild(); click(answerContext, find(answerRoot, "Answer using prompt"), 1000, 900);
		require(answerContext.focusWidget(find(answerRoot, "Codex prompt").id), "Cannot edit pending answer");
		answerContext.text(UiEventKind.TextInput, " edited");
		var answerAccepted:Void->Void = cast answerClient.pendingAcceptance; answerAccepted();
		require(answerPanel.prompt == "My answer edited", "Answer acknowledgement cleared a later edit");
		answerClient.deferAcceptance = false; answerRoot = answerBuild();
		click(answerContext, find(answerRoot, "Answer using prompt"), 1000, 900);
		require(answerPanel.prompt == "", "Accepted unchanged answer remained in composer");
		answerClient.control = false; answerRoot = answerBuild();
		require(!find(answerRoot, "Cancel").enabled, "Read-only user can cancel a pending request");
		answerContext.dispose();
		var piDialogClient = new FakeAgent(); piDialogClient.record.provider = "pi";
		piDialogClient.view.requests = [{id:"pick", method:"item/tool/requestUserInput", detail:"Pick a mode", reviewable:true,
			inputKind:"select", options:["safe = exact", "fast"]}];
		var piDialogContext = new UiContext(null, fonts, ui.ExosuitPalette.theme(true));
		var piDialog = new CodexSessionPanel(function() return piDialogClient, "session", "/repo", function() {},
			new style.Theme(), new syntax.SyntaxRegistry(), function(_, _, _) {}, function(_) {});
		function piDialogBuild():RenderNode return piDialogContext.submit(piDialog, new LayoutFrame(320, 900));
		piDialog.prompt = "Keep this draft";
		var piRoot = piDialogBuild(); piDialogClient.acceptActions = false;
		click(piDialogContext, find(piRoot, "Choose safe = exact"), 320, 900);
		require(piDialogClient.actions.indexOf("answer:safe = exact:pick") >= 0 && piDialog.prompt == "Keep this draft", "Pi choice changed draft or response");
		piRoot = piDialogBuild(); click(piDialogContext, find(piRoot, "Choose safe = exact"), 320, 900);
		require(piDialogClient.actions.length == 2, "Rejected Pi choice could not be retried");
		piDialogClient.control = false; piRoot = piDialogBuild();
		require(!find(piRoot, "Choose fast").enabled && !find(piRoot, "Cancel").enabled, "Read-only Pi choice remained enabled");
		piDialogClient.control = true; piDialogClient.view.requests[0].reviewable = false; piRoot = piDialogBuild();
		require(!find(piRoot, "Choose fast").enabled && find(piRoot, "Cancel").enabled, "Unreviewable Pi choice could be submitted");
		piDialogClient.view.requests = [{id:"confirm", method:"item/commandExecution/requestApproval", detail:"Continue?", reviewable:true, inputKind:"confirm"}];
		piRoot = piDialogBuild(); click(piDialogContext, find(piRoot, "Confirm"), 320, 900);
		click(piDialogContext, find(piRoot, "Cancel"), 320, 900);
		require(piDialogClient.actions.indexOf("approve::confirm") >= 0 && piDialogClient.actions.indexOf("decline::confirm") >= 0, "Pi confirmation did not preserve action mapping");
		piDialogClient.view.requests = [{id:"legacy", method:"item/tool/requestUserInput", detail:"Choose", reviewable:true, inputKind:"select"}];
		find(piDialogBuild(), "Answer using prompt");
		piDialogContext.dispose();
		var questionsClient = new FakeAgent();
		questionsClient.view.requests = [{id:"structured", method:"item/tool/requestUserInput", detail:"Full provider detail", reviewable:true,
			questions:[{id:"mode",header:"Mode",question:"Which mode?",multiple:false,secret:false,allowOther:false,
				options:[{label:"Safe",description:""},{label:"Fast",description:""}]}]}];
		questionsClient.view.requestsOmitted = 2;
		var questionsContext = new UiContext(null, fonts, ui.ExosuitPalette.theme(true));
		var questionsPanel = new CodexSessionPanel(function() return questionsClient, "session", "/repo", function() {},
			new style.Theme(), new syntax.SyntaxRegistry(), function(_, _, _) {}, function(_) {});
		function questionsBuild():RenderNode return questionsContext.submit(questionsPanel, new LayoutFrame(1000, 900));
		questionsPanel.prompt = "Unsent composer";
		var questionsRoot = questionsBuild();
		find(questionsRoot, "2 additional requests waiting. Resolve a displayed request to continue.");
		var detailsVisible = false;
		questionsRoot.walk(function(node) { if (node.semantics != null && node.semantics.label == "Full provider detail") detailsVisible = true; });
		require(!detailsVisible, "Structured request duplicated its raw details by default");
		click(questionsContext, find(questionsRoot, "Request details"), 1000, 900); questionsRoot = questionsBuild();
		find(questionsRoot, "Full provider detail");
		click(questionsContext, find(questionsRoot, "Hide request details"), 1000, 900); questionsRoot = questionsBuild();
		click(questionsContext, find(questionsRoot, "Safe"), 1000, 900); questionsRoot = questionsBuild();
		click(questionsContext, find(questionsRoot, "Submit answers"), 1000, 900);
		require(questionsClient.actions.length == 1 && questionsClient.actions[0].indexOf("answer-questions:") == 0
			&& questionsClient.actions[0].indexOf('"Safe"') >= 0 && questionsPanel.prompt == "Unsent composer", "Structured answer lost identity or modified composer");
		questionsRoot = questionsBuild(); require(find(questionsRoot, "Submit answers").enabled, "Unacknowledged structured answer was lost on rebuild");
		questionsClient.view.requests = []; questionsBuild();
		require(!questionsPanel.questionForms.exists("structured"), "Resolved question retained its draft");
		require(!questionsPanel.expandedRequestDetails.exists("structured"), "Resolved request retained disclosure state");
		questionsContext.dispose();
		var historyClient = new FakeAgent();
		var historyContext = new UiContext(null, fonts, ui.ExosuitPalette.theme(true));
		historyContext.setStyleSheet(ui.ExosuitPalette.styleSheet(historyContext.buildContext.theme, true));
		var history = new CodexSessionPanel(function() return historyClient, "session", "/repo", function() {},
			new style.Theme(), new syntax.SyntaxRegistry(), function(_, _, _) {}, function(_) {});
		function historyBuild():RenderNode return historyContext.submit(history, new LayoutFrame(800, 600));
		function appendHistory(start:Int, end:Int):Void {
			for (i in start...end) historyClient.view.items.push({id:"entry" + i, turn:"turn", kind:"agentMessage",
				title:"", text:"A new response with enough content to create a scrollable conversation.", detail:"", state:"completed", truncated:false});
		}
		historyBuild(); appendHistory(0, 15); historyBuild(); var historyRoot = historyBuild();
		var scroll = history.transcriptScroll;
		require(scroll.maxScrollY > 0 && scroll.maxScrollY - scroll.offsetY <= 2, "New overflow did not follow the latest message");
		appendHistory(15, 20); historyBuild(); historyBuild();
		require(scroll.maxScrollY - scroll.offsetY <= 2, "New output did not follow the latest message");
		scroll.jumpTo(0, 0); historyBuild();
		appendHistory(20, 25); historyBuild(); historyRoot = historyBuild();
		require(scroll.offsetY <= 2 && scroll.maxScrollY > 2, "New output moved a reader away from older history");
		click(historyContext, find(historyRoot, "Jump to latest"), 800, 600);
		historyBuild();
		require(scroll.maxScrollY - scroll.offsetY <= 2, "Jump to latest did not reach the end");
		historyContext.dispose();
		var imageContext = new UiContext(null, fonts, ui.ExosuitPalette.theme(true));
		imageContext.setStyleSheet(ui.ExosuitPalette.styleSheet(imageContext.buildContext.theme, true));
		var imageOpened:String = null;
		var image = new ui.SessionImageView("image-test", "Diagram", "images/flow.png", null,
			function(path) imageOpened = path, function() {});
		var imageRoot = imageContext.submit(image, new LayoutFrame(500, 300));
		click(imageContext, find(imageRoot, "Preview image"), 500, 300);
		imageRoot = imageContext.submit(image, new LayoutFrame(500, 300));
		find(imageRoot, "Image preview is unavailable for this location");
		click(imageContext, find(imageRoot, "Open image"), 500, 300);
		require(imageOpened == "images/flow.png", "Image fallback lost its destination");
        imageContext.dispose();
        var rasterBytes=sys.io.File.getBytes("../../graphical/assets/icons/exosuit-16.png");
        var embedded="data:image/png;base64,"+haxe.crypto.Base64.encode(rasterBytes);
        var dataContext=new UiContext(null,fonts,ui.ExosuitPalette.theme(true));
        var dataView=new ui.SessionImageView("embedded","Icon",embedded,null,function(_) throw "Data URL opened externally",function(){});
        var dataRoot=dataContext.submit(dataView,new LayoutFrame(500,300));
        click(dataContext,find(dataRoot,"Preview image"),500,300);
        dataRoot=dataContext.submit(dataView,new LayoutFrame(500,300));
        find(dataRoot,"Icon, 16 by 16 pixels"); dataContext.dispose();
        var remoteContext=new UiContext(null,fonts,ui.ExosuitPalette.theme(true)), remoteFrames=0;
        var pendingImage:Null<(Null<haxe.io.Bytes>,Null<String>)->Void>=null;
        var remoteView=new ui.SessionImageView("remote","Remote","assets/test.png",null,null,function() remoteFrames++,function(_,done) pendingImage=done);
        var remoteRoot=remoteContext.submit(remoteView,new LayoutFrame(500,300));
        click(remoteContext,find(remoteRoot,"Preview image"),500,300);
        require(pendingImage != null,"Remote preview did not request workspace bytes");
        remoteContext.dispose(); var beforeLate=remoteFrames;
        var lateImage:(Null<haxe.io.Bytes>,Null<String>)->Void=cast pendingImage; lateImage(rasterBytes,null);
        require(remoteFrames == beforeLate,"Unmounted image accepted a late load callback");
		var summaryContext = new UiContext(null, fonts, ui.ExosuitPalette.theme(true));
		var summaryOpened:String = null;
		var firstPatch = "@@ -1 +1 @@\n-old\n+new\n", secondPatch = "@@ -1 +1,2 @@\n keep\n+extra\n";
		var summary = new ui.SessionChangeSummaryView([
			{path:"src/Main.hx", kind:"update", offset:0, length:firstPatch.length, truncated:false},
			{path:"README.md", kind:"update", offset:firstPatch.length, length:secondPatch.length, truncated:true},
			{path:"invalid.txt", kind:"update", offset:9999, length:2, truncated:false}
		], firstPatch + secondPatch, function(path) summaryOpened = path);
		var summaryRoot = summaryContext.submit(summary, new LayoutFrame(500, 300));
		find(summaryRoot, "update  +1  −1"); find(summaryRoot, "update  +1  −0  ·  partial");
		find(summaryRoot, "update  ·  preview unavailable");
		click(summaryContext, find(summaryRoot, "README.md"), 500, 300);
		require(summaryOpened == "README.md", "Changed file summary opened the wrong file");
		summaryContext.dispose();
        var longClient = new FakeAgent(), longContext = new UiContext(null, fonts, ui.ExosuitPalette.theme(true));
        var htmlSource = "<main>"; var padding="x"; for (_ in 0...13) padding += padding;
        htmlSource += padding + "</main>"; var fullResponse="```html\n" + htmlSource + "\n```";
        longClient.messageContent = fullResponse; longClient.view.supportsMessageContent = true;
        longClient.view.items = [{id:"long",turn:"turn",kind:"agentMessage",title:"Codex",text:fullResponse.substr(0,4096),detail:"",state:"completed",truncated:true,contentToken:"v1"}];
        var previewed:String = null;
        var longPanel = new CodexSessionPanel(function() return longClient,"session","/repo",function() {},new style.Theme(),new syntax.SyntaxRegistry(),
          function(_,_,_) {},function(_) {},null,{context:function() return "Project", explore:function() {}, reviewChanges:function() {}, previewArtifact:function(_,source) previewed=source});
        function longBuild():RenderNode return longContext.submit(longPanel,new LayoutFrame(1000,1000));
        var longRoot=longBuild(); longRoot=longBuild();
        var renderedLong:ui.CodexMarkdownView = cast longPanel.markdown.get("turn:long");
        require(longClient.contentRequests == 1 && renderedLong.value == fullResponse, "Latest completed message was not fully loaded");
        find(longRoot,"Copy message"); click(longContext,find(longRoot,"Preview HTML"),1000,1000);
        require(previewed != null && StringTools.trim(previewed) == htmlSource, "HTML preview received clipped content");
        longClient.deferContent=true;
        longClient.view.items.push({id:"later",turn:"turn",kind:"agentMessage",title:"Codex",text:"preview",detail:"",state:"completed",truncated:true,contentToken:"old"});
        longRoot=longBuild();
        require(longClient.pendingContent != null, "New completed message did not begin loading");
        longClient.view.items[1].contentToken="new";
        var late:(Null<String>,Bool,Null<String>)->Void = cast longClient.pendingContent; late("stale response",false,null);
        require(!longPanel.loadedContent.exists("turn:later"), "Stale message snapshot replaced a newer revision");
        longContext.dispose();
        var oldClient=new FakeAgent(), oldContext=new UiContext(null,fonts,ui.ExosuitPalette.theme(true));
        oldClient.view.supportsMessageContent=true; oldClient.messageContent="older full response";
        oldClient.view.items=[{id:"older",turn:"turn",kind:"agentMessage",title:"Codex",text:"older preview",detail:"",state:"completed",truncated:true,contentToken:"old"},
          {id:"newer",turn:"turn",kind:"agentMessage",title:"Codex",text:"newer response",detail:"",state:"completed",truncated:false}];
        var oldPanel=new CodexSessionPanel(function() return oldClient,"session","/repo",function(){},new style.Theme(),new syntax.SyntaxRegistry(),function(_,_,_){},function(_){});
        function oldBuild():RenderNode return oldContext.submit(oldPanel,new LayoutFrame(1000,1000));
        var oldRoot=oldBuild();
        require(oldClient.contentRequests == 0,"Older response loaded automatically");
        find(oldRoot,"Copy preview"); click(oldContext,find(oldRoot,"Load full response"),1000,1000);
        oldRoot=oldBuild(); var oldRendered:ui.CodexMarkdownView=cast oldPanel.markdown.get("turn:older");
        require(oldClient.contentRequests == 1 && oldRendered.value == "older full response", "Older response did not load on request");
        oldContext.dispose();
		var draftClient = new FakeAgent(), draftContext = new UiContext(null, fonts, ui.ExosuitPalette.theme(true));
		draftClient.view.supportsImageUpload = true; draftClient.uploadEnabled = true;
		var fixtureImage = sys.io.File.getBytes("../../graphical/assets/icons/exosuit-16.png");
		var requestedPath:String = null; var clipboardBytes:Null<haxe.io.Bytes> = null; var pasteReads = 0;
		var worktreeOpens = 0, githubOpens = 0, pullRequestOpens = 0, availableActions = true;
		var draftPanel = new CodexSessionPanel(function() return draftClient, "session", "/repo", function() {},
			new style.Theme(), new syntax.SyntaxRegistry(), function(_, _, _) {}, function(_) {}, null,
			{context:function() return "Project", explore:function() {}, reviewChanges:function() {},
			 readContext:function(path, done) { requestedPath = path; done("actual contents\n", null); },
			 chooseImage:function(done) done("photo.png", fixtureImage, null),
             pasteImage:function() { pasteReads++; return {bytes:clipboardBytes, error:null}; },
			 canCreateWorktree:function() return availableActions, newWorktree:function() worktreeOpens++,
			 canOpenGithub:function() return availableActions, githubRepository:function() githubOpens++,
			 canOpenPullRequest:function() return availableActions, githubPullRequest:function() pullRequestOpens++});
		function draftBuild():RenderNode return draftContext.submit(draftPanel, new LayoutFrame(1000, 1000));
		var draftRoot = draftBuild();
		click(draftContext, find(draftRoot, "New worktree"), 1000, 1000);
		click(draftContext, find(draftRoot, "Open GitHub"), 1000, 1000);
		click(draftContext, find(draftRoot, "Open pull request page"), 1000, 1000);
		require(worktreeOpens == 1 && githubOpens == 1 && pullRequestOpens == 1, "Workspace actions did not invoke their callbacks");
		availableActions = false; draftRoot = draftBuild();
		var unavailableVisible = false;
		draftRoot.walk(function(node) { if (node.semantics != null && node.semantics.label == "New worktree") unavailableVisible = true; });
		require(!unavailableVisible, "Unavailable worktree action remained visible");
		click(draftContext, find(draftRoot, "Add workspace text"), 1000, 1000);
		draftRoot = draftBuild();
		require(draftContext.focusWidget(find(draftRoot, "Workspace text path").id), "Cannot focus context path");
		draftContext.text(UiEventKind.TextInput, "src/Main.hx");
		draftRoot = draftBuild(); click(draftContext, find(draftRoot, "Include text"), 1000, 1000);
		require(requestedPath == "src/Main.hx" && draftPanel.textContext.length == 1, "Workspace text was not read into the draft");
		draftRoot = draftBuild(); click(draftContext, find(draftRoot, "Add image"), 1000, 1000);
		require(draftPanel.imageDrafts.length == 1, "Image upload did not enter the draft");
		draftRoot = draftBuild(); find(draftRoot, "photo.png preview");
        var firstThumbnail:Null<haxeon.ui.Image> = null;
        for (stateId in draftContext.stateStore.paths.keys()) {
          var statePath = draftContext.stateStore.paths.get(stateId);
          if (statePath != null && statePath.indexOf("draft-thumbnail") >= 0 && draftContext.stateStore.values.exists(stateId))
            firstThumbnail = cast Reflect.field(draftContext.stateStore.values.get(stateId), "image");
        }
        require(firstThumbnail != null && !firstThumbnail.isDisposed(), "Thumbnail texture was not created");
        require(draftContext.focusWidget(find(draftRoot, "Codex prompt").id), "Cannot focus context draft");
		draftContext.text(UiEventKind.TextInput, "Explain"); draftRoot = draftBuild();
		draftClient.acceptActions = false; click(draftContext, find(draftRoot, "Send"), 1000, 1000);
		require(draftClient.actions[0].indexOf("actual contents") >= 0 && draftClient.actions[0].indexOf("src/Main.hx") >= 0, "Sent only a path instead of file contents");
		require(draftClient.lastImageIds != null && draftClient.lastImageIds[0] == "opaque-image", "Image handle did not reach provider action");
		require(draftPanel.prompt == "Explain" && draftPanel.textContext.length == 1 && draftPanel.imageDrafts.length == 1, "Rejected send lost draft context");
		draftClient.acceptActions = true; draftClient.deferAcceptance = true;
		draftRoot = draftBuild(); click(draftContext, find(draftRoot, "Send"), 1000, 1000);
		draftPanel.prompt = "Edited while sending";
		var accepted:Void->Void = cast draftClient.pendingAcceptance; accepted();
		require(draftPanel.prompt == "Edited while sending" && draftPanel.textContext.length == 0 && draftPanel.imageDrafts.length == 0
			&& draftClient.removedImages.indexOf("opaque-image") >= 0, "Late acknowledgement lost edited text or retained submitted attachments");
		draftClient.deferAcceptance = false; draftRoot = draftBuild();
        require(firstThumbnail.isDisposed(), "Acknowledged image thumbnail was not disposed");
        click(draftContext, find(draftRoot, "Send"), 1000, 1000);
		require(draftPanel.prompt == "" && draftPanel.textContext.length == 0, "Accepted send did not clear the unchanged draft");
		draftRoot = draftBuild(); require(draftContext.focusWidget(find(draftRoot, "Codex prompt").id), "Cannot focus paste composer");
        var textPasteReachedField = false;
        try draftContext.key(UiEventKind.KeyDown, UiKey.V, UiModifier.Control) catch (_:Dynamic) textPasteReachedField = true;
        require(textPasteReachedField && pasteReads == 1 && draftPanel.imageDrafts.length == 0, "Text paste was treated as an image");
        clipboardBytes = fixtureImage;
        draftContext.key(UiEventKind.KeyDown, UiKey.V, UiModifier.Control);
        require(draftPanel.imageDrafts.length == 1 && draftPanel.imageDrafts[0].name == "Pasted image.png", "Image paste did not attach to draft");
		draftRoot = draftBuild(); find(draftRoot, "Pasted image.png preview"); click(draftContext, find(draftRoot, "Send"), 1000, 1000);
		require(draftClient.actions[draftClient.actions.length - 1] == "prompt::null"
			&& draftClient.lastImageIds != null && draftClient.lastImageIds[0] == "opaque-image", "Image-only send invented text or lost its image");
        draftRoot = draftBuild(); click(draftContext, find(draftRoot, "Add image"), 1000, 1000);
        draftRoot = draftBuild();
        var removedThumbnail:Null<haxeon.ui.Image> = null;
        for (stateId in draftContext.stateStore.paths.keys()) {
          var statePath = draftContext.stateStore.paths.get(stateId);
          if (statePath != null && statePath.indexOf("draft-thumbnail") >= 0 && draftContext.stateStore.values.exists(stateId))
            removedThumbnail = cast Reflect.field(draftContext.stateStore.values.get(stateId), "image");
        }
        require(removedThumbnail != null && !removedThumbnail.isDisposed(), "Remove test thumbnail missing");
        click(draftContext, find(draftRoot, "Remove image"), 1000, 1000); draftRoot = draftBuild();
        require(removedThumbnail.isDisposed(), "Removed thumbnail was not disposed");
        click(draftContext, find(draftRoot, "Add image"), 1000, 1000); draftRoot = draftBuild();
        var unmountedThumbnail:Null<haxeon.ui.Image> = null;
        for (stateId in draftContext.stateStore.paths.keys()) {
          var statePath = draftContext.stateStore.paths.get(stateId);
          if (statePath != null && statePath.indexOf("draft-thumbnail") >= 0 && draftContext.stateStore.values.exists(stateId))
            unmountedThumbnail = cast Reflect.field(draftContext.stateStore.values.get(stateId), "image");
        }
        require(unmountedThumbnail != null && !unmountedThumbnail.isDisposed(), "Unmount test thumbnail missing");
        draftContext.dispose();
        require(unmountedThumbnail.isDisposed(), "Unmounted thumbnail was not disposed");
		fonts.dispose();
		trace("PASS: session rendering and provider actions across themes and widths");
		return 0;
	}
}
