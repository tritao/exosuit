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
@:access(ui.ScmBranchController)
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
	static function activate(context:UiContext,node:RenderNode):Void {
		require(context.focusWidget(node.id),"Control is not keyboard focusable");
		context.key(UiEventKind.KeyDown,UiKey.Enter);
	}
	static function checkSendIcon(root:RenderNode,label:String):Void {
		var button=find(root,label);
		require(button.children.length>0,"Send button icon is missing");
		var bounds=button.globalBounds(),icon=button.children[0].globalBounds();
		var dx=icon.x+icon.width/2-(bounds.x+bounds.width/2),dy=icon.y+icon.height/2-(bounds.y+bounds.height/2);
		require(Math.abs(dx)<0.6 && Math.abs(dy)<0.6,label+" icon is off center: "+dx+","+dy);
	}
	static function checkComposerActions(root:RenderNode,queued:Bool):Void {
		var names=queued ? ["Add image","Add workspace text","Steer now","Queue message"] : ["Add image","Add workspace text","Send"];
		var previous:Null<haxeon.ui.Rect>=null, center:Null<Float>=null;
		for (label in names) {
			var node=find(root,label), bounds=node.globalBounds(), y=bounds.y+bounds.height/2;
			if (center==null) center=y; else require(Math.abs(y-center)<0.6,label+" is vertically misaligned");
			if (previous!=null) require(Math.abs(bounds.x-(previous.x+previous.width)-6)<0.6,label+" has incorrect action spacing");
			previous=bounds;
			if (label!="Steer now") checkSendIcon(root,label);
		}
	}
	static function settingValue(root:RenderNode,label:String,value:String):Void {
		var semantics:haxeon.ui.semantics.Semantics=cast find(root,label).semantics;
		require(semantics.value==value && (semantics.states & haxeon.ui.semantics.AccessibilityState.HasPopup)!=0,
			"Setting menu lost its accessible value or popup state: "+label);
	}
	static function selectMenu(items:Array<haxeon.ui.widgets.overlays.MenuItem>,label:String):Void {
		if (items != null) for (item in items) if (item.label==label && item.enabled) {item.onSelect();return;}
		throw "Missing menu item: "+label;
	}
	static function chooseMenu(items:Array<haxeon.ui.widgets.overlays.MenuItem>, label:String):Void {
		if (items != null) for (item in items) if (item.label == label && item.enabled) { item.onSelect(); return; }
		throw "Missing menu action: " + label;
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
		var groups:Array<workspace.service.WorkspaceProtocol.WorkspaceGroup> = [
			{id:"parent",name:"Parent",cwd:"C:/workspace/project",parent:null,revision:1,order:0},
			{id:"child",name:"Child",cwd:null,parent:"parent",revision:1,order:0},
			{id:"root",name:"Root",cwd:null,parent:null,revision:1,order:0}
		];
		var inherited = ui.SessionGroupDirectory.resolve(groups,"C:/workspace","child","codex");
		require(inherited != null && inherited.cwd == "C:/workspace/project", "Codex group did not inherit its parent directory");
		var workspaceRoot = ui.SessionGroupDirectory.resolve(groups,"C:/workspace","root","codex");
		require(workspaceRoot != null && workspaceRoot.cwd == "C:/workspace", "Codex root group did not resolve to workspace root");
		require(ui.SessionGroupDirectory.resolve(groups,"C:/workspace","child","claude") == null
			&& ui.SessionGroupDirectory.resolve(groups,"C:/workspace","root","pi") == null, "Provider unsupported inherited directory offered");
		groups[0].revision = 2;
		var updated = ui.SessionGroupDirectory.resolve(groups,"C:/workspace","child","codex");
		var oldStamp = inherited == null ? "" : inherited.stamp;
		require(updated != null && updated.stamp != oldStamp, "Ancestor update did not invalidate offered directory");
		groups[0].parent = "child"; groups[0].cwd = null;
		require(ui.SessionGroupDirectory.resolve(groups,"C:/workspace","child","codex") == null, "Cyclic group ancestry was offered");
		groups[0].parent = null; groups[0].cwd = "C:/outside";
		require(ui.SessionGroupDirectory.resolve(groups,"C:/workspace","child","codex") == null, "Out-of-workspace ancestor was offered");
        var staleBranchSourceReads=0;
        var staleBranch=new ui.ScmBranchController(null,function() {staleBranchSourceReads++;throw "Stale scope reached source";},
          function(_) throw "Stale scope checked repository",function(_) {},function() {},function(_) {},function() return "test");
        staleBranch.open(null,function() return false);
        staleBranch.createPrompt(null,function() return false);
        staleBranch.checkout(null,null,"refs/heads/main",function() return false);
        staleBranch.create(null,null,"new-branch",function() return false);
        require(staleBranchSourceReads==0,"Stale branch operation accessed its source");
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
			checkSendIcon(root,"Send");
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
			checkSendIcon(root,"Send");
			activate(context, find(root, "Send"));
			require(client.actions.indexOf("prompt:Hello agent:null") >= 0, "Send did not deliver composer text");
			root = build();
			settingValue(root,"Permissions · " + workspace.client.CodexPermissions.labelForRecord(null,null,null) + "  ▾",workspace.client.CodexPermissions.labelForRecord(null,null,null));
			activate(context, find(root, "Permissions · " + workspace.client.CodexPermissions.labelForRecord(null, null, null) + "  ▾"));
			require(menu != null && menu.length > 0, "Permissions menu did not open");
			root = build();
			activate(context, find(root, "Conversation model"));
			selectMenu(menu,"Test model");
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
		var commits = 0, mayCommit = true, answerMenu:Array<haxeon.ui.widgets.overlays.MenuItem> = null;
		var answerPanel = new CodexSessionPanel(function() return answerClient, "session", "/repo", function() {},
			new style.Theme(), new syntax.SyntaxRegistry(), function(items, _, _) answerMenu = items, function(_) {}, null,
			{context:function() return "Project", explore:function() {}, reviewChanges:function() {},
			 canCommitChanges:function() return mayCommit, commitChanges:function() commits++});
		function answerBuild():RenderNode return answerContext.submit(answerPanel, new LayoutFrame(1000, 900));
		var answerRoot = answerBuild();
		click(answerContext, find(answerRoot, "Repository actions"), 1000, 900); chooseMenu(answerMenu, "Commit changes");
		require(commits == 1 && answerClient.actions.length == 0, "Commit navigation performed an agent action");
		mayCommit = false; answerRoot = answerBuild();
		var foundCommit = false; answerRoot.walk(function(node) { if (node.semantics != null && node.semantics.label == "Repository actions") foundCommit = true; });
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
		for (requestWidth in [320.0, 420.0]) {
			var reviewClient = new FakeAgent();
			for (i in 0...20) reviewClient.view.items.push({id:"history-" + i,turn:"turn",kind:"agentMessage",title:"",text:"Earlier transcript message",detail:"",state:"completed",truncated:false});
			var reviewContext = new UiContext(null, fonts, ui.ExosuitPalette.theme(true));
			var reviewPanel = new CodexSessionPanel(function() return reviewClient, "session", "/repo", function() {},
				new style.Theme(), new syntax.SyntaxRegistry(), function(_, _, _) {}, function(_) {});
			function reviewBuild():RenderNode return reviewContext.submit(reviewPanel, new LayoutFrame(requestWidth, 900));
			reviewBuild(); reviewBuild(); reviewPanel.transcriptScroll.jumpTo(0, 0); reviewBuild();
			reviewClient.view.requests = [{id:"long-request",method:"item/tool/requestUserInput",detail:"Details",reviewable:true,
				questions:[for (i in 0...8) {id:"q" + i,header:"Question " + i,question:"Choose a response",multiple:false,secret:false,allowOther:false,
					options:[{label:"One",description:""},{label:"Two",description:""}]}]}];
			var reviewRoot = reviewBuild(); reviewRoot = reviewBuild();
			require(reviewPanel.transcriptScroll.offsetY <= 2, "New request displaced a reader reviewing earlier history");
			var reviewAction = find(reviewRoot, "Review request");
			require(reviewContext.focusWidget(reviewAction.id), "Review request cannot receive keyboard focus");
			reviewContext.key(UiEventKind.KeyDown, UiKey.Enter); reviewRoot = reviewBuild();
			var requestHeading = find(reviewRoot, "Input needed").globalBounds();
			var requestViewport = reviewPanel.transcriptViewport.globalBounds();
			require(requestHeading.y >= requestViewport.y && requestHeading.y + requestHeading.height <= requestViewport.y + requestViewport.height,
				"Review request did not reveal the heading at " + requestWidth);
			find(reviewRoot, "Codex prompt");
			reviewContext.dispose();
		}
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
		historyClient.history.hasOlder = true; scroll.jumpTo(0, 0); historyRoot = historyBuild();
		click(historyContext, find(historyRoot, "Load earlier messages"), 800, 600);
		historyRoot = historyBuild(); require(!find(historyRoot, "Loading earlier messages…").enabled, "History load allowed a duplicate request");
		var oldItem = history.historyNodes.get("turn:entry0"), oldY = oldItem.globalBounds().y;
		var older:Array<workspace.service.WorkspaceAgentProtocol.AgentActivityItem> = [];
		for (i in 0...5) older.push({id:"older" + i,turn:"turn",kind:"agentMessage",title:"",text:"Older message",detail:"",state:"completed",truncated:false});
		var existingHistory:Array<workspace.service.WorkspaceAgentProtocol.AgentActivityItem> = cast historyClient.view.items;
		historyClient.view.items = older.concat(existingHistory); historyClient.history.loading = false;
		var historyDone:Null<String>->Void = cast historyClient.historyDone; historyDone(null);
		historyBuild(); historyRoot = historyBuild();
		require(Math.abs(history.historyNodes.get("turn:entry0").globalBounds().y - oldY) <= 1, "Prepending history moved the first visible message");
		historyClient.history.error = "Unable to load history"; scroll.jumpTo(0, 0); historyRoot = historyBuild();
		find(historyRoot, "Unable to load history"); find(historyRoot, "Retry earlier messages");
		historyClient.history.resetRequired = true; historyClient.history.detached = true; historyRoot = historyBuild();
		click(historyContext, find(historyRoot, "Return to latest messages"), 800, 600);
		require(historyClient.historyResets == 1, "Invalidated history did not offer reset");
		historyBuild(); historyBuild();
		require(scroll.maxScrollY - scroll.offsetY <= 2, "History reset did not return to latest messages");
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
        var sentContext=new UiContext(null,fonts,ui.ExosuitPalette.theme(true)), sentLoads=0, sentOpens=0;
        var sentPending:Null<(Null<haxe.io.Bytes>,Null<String>)->Void>=null;
        var sentView=new ui.SessionMessageImageView("sent-test","opaque",function(done) {sentLoads++;sentPending=done;},function(_) sentOpens++,function() {});
        var sentRoot=sentContext.submit(sentView,new LayoutFrame(500,300));
        require(sentLoads==0,"Sent image loaded without user action");
        click(sentContext,find(sentRoot,"Preview image"),500,300);
        sentRoot=sentContext.submit(sentView,new LayoutFrame(500,300));find(sentRoot,"Loading image…");
        var sentDone:(Null<haxe.io.Bytes>,Null<String>)->Void=cast sentPending;sentDone(null,"This sent image is no longer available");
        sentRoot=sentContext.submit(sentView,new LayoutFrame(500,300));find(sentRoot,"This sent image is no longer available");
        click(sentContext,find(sentRoot,"Retry image preview"),500,300);
        sentDone=cast sentPending;sentDone(rasterBytes,null);
        sentRoot=sentContext.submit(sentView,new LayoutFrame(500,300));find(sentRoot,"Sent image, 16 by 16 pixels");
        click(sentContext,find(sentRoot,"Open image"),500,300);sentDone=cast sentPending;sentDone(rasterBytes,null);
        require(sentLoads==3 && sentOpens==1,"Sent image open did not use explicit scoped bytes");
        sentContext.dispose();
        var staleContext=new UiContext(null,fonts,ui.ExosuitPalette.theme(true)),staleFrames=0;
        var staleView=new ui.SessionMessageImageView("sent-stale","opaque",function(done) sentPending=done,function(_) throw "Unmounted image opened",function() staleFrames++);
        var staleRoot=staleContext.submit(staleView,new LayoutFrame(500,300));click(staleContext,find(staleRoot,"Open image"),500,300);
        staleContext.dispose();var framesBefore=staleFrames;sentDone=cast sentPending;sentDone(rasterBytes,null);
        require(staleFrames==framesBefore,"Unmounted sent image accepted a late callback");
        var sentClient=new FakeAgent();
        sentClient.view.items=[{id:"user",turn:"turn",kind:"userMessage",title:"",text:"Inspect",detail:"",state:"completed",truncated:false,images:[{id:"opaque-id"},{id:null}]}];
        var sentPanelContext=new UiContext(null,fonts,ui.ExosuitPalette.theme(true)),sentPanelOpens=0;
        var sentPanel=new CodexSessionPanel(function() return sentClient,"session","/repo",function() {},new style.Theme(),new syntax.SyntaxRegistry(),
          function(_,_,_) {},function(_) {},null,{context:function() return "Project",explore:function() {},reviewChanges:function() {},
           openMessageImage:function(turn,item,imageId,bytes) {require(turn=="turn" && item=="user" && imageId=="opaque-id" && bytes.length==rasterBytes.length,"Sent image open identity changed");sentPanelOpens++;}});
        var sentPanelRoot=sentPanelContext.submit(sentPanel,new LayoutFrame(500,700));
        find(sentPanelRoot,"Sent image is unavailable");
        click(sentPanelContext,find(sentPanelRoot,"Open image"),500,700);
        require(sentClient.imageRequestIdentity=="session:turn:user:opaque-id","Sent image request was not scoped to the activity");
        var panelDone:(Null<haxe.io.Bytes>,Null<String>)->Void=cast sentClient.pendingImage;panelDone(rasterBytes,null);
        require(sentPanelOpens==1,"Sent image open did not reach the host");sentPanelContext.dispose();
        var nativeClient=new FakeAgent(), nativeLoads=0, nativeOpen:Null<String>=null;
        nativeClient.record.cwd="/repo/project";
        nativeClient.view.items=[
          {id:"native",turn:"turn",kind:"imageGeneration",title:"Generated image",text:"",detail:"",state:"completed",truncated:false,imagePath:"../assets/output.png"},
          {id:"outside",turn:"turn",kind:"imageView",title:"Viewed image",text:"",detail:"",state:"completed",truncated:false,imagePath:"/outside/private.png"}
        ];
        var nativeContext=new UiContext(null,fonts,ui.ExosuitPalette.theme(true));
        var nativePanel=new CodexSessionPanel(function() return nativeClient,"session","/repo",function() {},new style.Theme(),new syntax.SyntaxRegistry(),
          function(_,_,_) {},function(_) {},function(path) nativeOpen=path,
          {context:function() return "Project",explore:function() {},reviewChanges:function() {},
           loadImage:function(path,done) {require(path=="/repo/assets/output.png","Native image used the wrong workspace path");nativeLoads++;done(rasterBytes,null);}});
        var nativeRoot=nativeContext.submit(nativePanel,new LayoutFrame(500,900));
        find(nativeRoot,"Image preview is unavailable in this workspace");
        require(nativeLoads==0,"Native image loaded before an explicit action");
        click(nativeContext,find(nativeRoot,"Preview image"),500,900);
        require(nativeLoads==1,"Native image did not use workspace file callback");
        nativeRoot=nativeContext.submit(nativePanel,new LayoutFrame(500,900));
        find(nativeRoot,"Generated image, 16 by 16 pixels");
        click(nativeContext,find(nativeRoot,"Open image"),500,900);
        require(nativeOpen=="/repo/assets/output.png","Native image open did not preserve validated path");nativeContext.dispose();
        for (outputDark in [true,false]) for (outputWidth in [320.0,1000.0]) {
        var outputClient=new FakeAgent();
        outputClient.view.items=[{id:"command",turn:"turn",kind:"commandExecution",title:"Command",text:"npm test",
          detail:"/repo\nExit code: 1\nfailed    test",state:"failed",truncated:false}];
        var outputContext=new UiContext(null,fonts,ui.ExosuitPalette.theme(outputDark));
        var outputPanel=new CodexSessionPanel(function() return outputClient,"session","/repo",function() {},new style.Theme(),new syntax.SyntaxRegistry(),
          function(_,_,_) {},function(_) {});
        var outputRoot=outputContext.submit(outputPanel,new LayoutFrame(outputWidth,700));
        var failed=find(outputRoot,"Failed"), failedBounds=failed.globalBounds(), danger=outputContext.buildContext.theme.tokens.danger;
        require(failedBounds.width>0 && failedBounds.x>=0 && failedBounds.x+failedBounds.width<=outputWidth
          && failed.layout.textColor.red==danger.red && failed.layout.textColor.green==danger.green && failed.layout.textColor.blue==danger.blue,
          "Command failure status was clipped or lost its error color");
        var disclosure=find(outputRoot,"Show details");
        require(outputContext.focusWidget(disclosure.id),"Command disclosure was not keyboard focusable");
        outputContext.key(UiEventKind.KeyDown,UiKey.Enter);
        outputRoot=outputContext.submit(outputPanel,new LayoutFrame(outputWidth,700));
        require(find(outputRoot,"Tool output").focusable,"Expanded command lost selectable output");
        find(outputRoot,"Copy output");find(outputRoot,"Hide details");outputContext.dispose();
        }
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
        for (footerDark in [true,false]) for (footerWidth in [320.0,1000.0,1920.0,2560.0,5120.0]) {
          var footerClient=new FakeAgent(),worktreeCalls=0,branchCalls=0,worktreeAllowed=true,branchAllowed=true;
          footerClient.record.cwd="/repo/worktrees/ui-exploration";
          footerClient.view.supportsImageUpload=true;
          var footerContext=new UiContext(null,fonts,ui.ExosuitPalette.theme(footerDark));
          var footerPanel=new CodexSessionPanel(function() return footerClient,"session","/repo",function() {},new style.Theme(),new syntax.SyntaxRegistry(),
            function(_,_,_) {},function(_) {},null,{context:function() return "Project",explore:function() {},reviewChanges:function() {},
              worktreeLabel:function() return "ui-exploration",branchLabel:function() return "feature/chat",
              canSelectWorktree:function() return worktreeAllowed,canSelectBranch:function() return branchAllowed,
              selectWorktree:function() worktreeCalls++,selectBranch:function() branchCalls++,
              chooseImage:function(done) done(null,null,null),readContext:function(_,done) done(null,"Unavailable")});
          var footerHeight=footerWidth>=2560 ? 1440.0 : footerWidth>=1920 ? 1080.0 : 900.0;
          function footerBuild():RenderNode return footerContext.submit(footerPanel,new LayoutFrame(footerWidth,footerHeight));
          var footerRoot=footerBuild();checkHorizontalBounds(footerRoot,footerWidth);
          checkComposerActions(footerRoot,false);
          footerPanel.prompt="message";footerRoot=footerBuild();checkComposerActions(footerRoot,false);
          footerClient.control=false;footerRoot=footerBuild();checkComposerActions(footerRoot,false);
          footerClient.control=true;footerPanel.prompt="";footerRoot=footerBuild();
          var joinedFrame:RenderNode=null,draftSurface:RenderNode=null,joinedFooter:RenderNode=null;
          footerRoot.walk(function(node) {
            if(node.styleKey=="codex-composer-frame") joinedFrame=node;
            if(node.styleKey=="codex-composer") draftSurface=node;
            if(node.styleKey=="agent-workspace-strip") joinedFooter=node;
          });
          require(joinedFrame!=null && draftSurface!=null && joinedFooter!=null
            && joinedFrame.children.indexOf(draftSurface)>=0 && joinedFrame.children.indexOf(joinedFooter)>=0,
            "Composer and workspace footer do not share their outer frame");
          var frameBounds=joinedFrame.globalBounds(),draftBounds=draftSurface.globalBounds(),footerBounds=joinedFooter.globalBounds();
          require(Math.abs(footerBounds.y-(draftBounds.y+draftBounds.height)-1)<0.2
            && Math.abs(draftBounds.x-footerBounds.x)<0.2 && Math.abs(draftBounds.width-footerBounds.width)<0.2
            && footerBounds.y+footerBounds.height<=frameBounds.y+frameBounds.height+0.1,
            "Composer/footer divider or shared edge is not contiguous");
          if (footerWidth>=1920) {
            var composer:RenderNode=null,strip:RenderNode=null,message:RenderNode=null;
            footerRoot.walk(function(node) {
              if(node.styleKey=="codex-composer-frame") composer=node;
              if(node.styleKey=="agent-workspace-strip") strip=node;
              if(node.styleKey=="codex-message-turn:user") message=node;
            });
            require(composer!=null && strip!=null && message!=null,"Wide session reading regions are missing");
            var cb=composer.globalBounds(),sb=strip.globalBounds(),mb=message.globalBounds();
            require(cb.width<=880.1 && sb.width<=880.1 && mb.width<=880.1
              && Math.abs(cb.x+cb.width/2-footerWidth/2)<2 && Math.abs(sb.x+sb.width/2-footerWidth/2)<2,
              "Wide composer or reading measure escaped its centered bounds");
          }
          settingValue(footerRoot,"Select worktree",footerClient.record.cwd);settingValue(footerRoot,"Select branch","feature/chat");
          var worktreeBounds=find(footerRoot,"Select worktree").globalBounds();
          footerContext.pointerMove(worktreeBounds.x+worktreeBounds.width/2,worktreeBounds.y+worktreeBounds.height/2);
          footerContext.animations.advance(config.Settings.DEFAULT_TOOLTIP_DELAY+0.1);
          footerRoot=footerBuild();
          var fullDirectoryTip=false;
          footerRoot.walk(function(node) {
            if (node.styleType != "tooltip" || !node.layout.style.visible) return;
            node.walk(function(child) { if (child.layout.text == footerClient.record.cwd) fullDirectoryTip=true; });
          });
          require(fullDirectoryTip,"Worktree tooltip did not expose the complete session directory");
          activate(footerContext,find(footerRoot,"Select worktree"));activate(footerContext,find(footerRoot,"Select branch"));
          require(worktreeCalls==1 && branchCalls==1,"Footer keyboard actions did not invoke host callbacks");
          worktreeAllowed=false;branchAllowed=false;
          activate(footerContext,find(footerRoot,"Select worktree"));activate(footerContext,find(footerRoot,"Select branch"));
          require(worktreeCalls==1 && branchCalls==1,"Stale footer controls ignored capability changes");
          footerRoot=footerBuild();
          require(!find(footerRoot,"Select worktree").enabled && !find(footerRoot,"Select branch").enabled,
            "Unavailable footer actions remained enabled");
          worktreeAllowed=true;branchAllowed=true;footerRoot=footerBuild();footerClient.record.thread="another-thread";
          activate(footerContext,find(footerRoot,"Select worktree"));activate(footerContext,find(footerRoot,"Select branch"));
          require(worktreeCalls==1 && branchCalls==1,"Stale footer controls followed a replaced session");
          footerClient.record.thread="thread";footerClient.record.state="working";
          footerClient.view.supportsQueue=true;footerClient.view.inputToken="input";footerRoot=footerBuild();
          checkComposerActions(footerRoot,true);
          footerPanel.prompt="queued message";footerRoot=footerBuild();checkComposerActions(footerRoot,true);
          footerContext.dispose();
        }
        var modelClient=new FakeAgent();modelClient.deferModelSettings=true;
        modelClient.record.preferredModel="test-model";modelClient.record.preferredEffort="low";
        modelClient.view.models.push({model:"other-model",name:"Other model",supportedEfforts:["low","high"]});
        var modelContext=new UiContext(null,fonts,ui.ExosuitPalette.theme(true)), modelMenu:Array<haxeon.ui.widgets.overlays.MenuItem>=null;
        var modelPanel=new CodexSessionPanel(function() return modelClient,"session","/repo",function() {},new style.Theme(),new syntax.SyntaxRegistry(),function(items,_,_) modelMenu=items,function(_) {});
        function modelBuild():RenderNode return modelContext.submit(modelPanel,new LayoutFrame(1000,900));
        var modelRoot=modelBuild();activate(modelContext,find(modelRoot,"Conversation model"));selectMenu(modelMenu,"Other model");
        modelRoot=modelBuild();require(modelClient.modelBusy && modelPanel.selectedModel=="test-model" && modelPanel.selectedEffort=="low",
          "Pending model selection changed the displayed provider settings");
        settingValue(modelRoot,"Conversation model","Test model");settingValue(modelRoot,"Reasoning effort","Low");
        modelClient.finishModelSettings(false);modelRoot=modelBuild();
        require(modelPanel.selectedModel=="test-model" && modelPanel.selectedEffort=="low","Rejected model selection was displayed");
        settingValue(modelRoot,"Conversation model","Test model");settingValue(modelRoot,"Reasoning effort","Low");
        activate(modelContext,find(modelRoot,"Conversation model"));selectMenu(modelMenu,"Other model");
        modelClient.finishModelSettings(true);modelRoot=modelBuild();
        require(modelPanel.selectedModel=="other-model" && modelPanel.selectedEffort=="","Accepted model selection was not reconciled");
        settingValue(modelRoot,"Conversation model","Other model");settingValue(modelRoot,"Reasoning effort","Model default");
        activate(modelContext,find(modelRoot,"Reasoning effort"));selectMenu(modelMenu,"High effort");
        modelRoot=modelBuild();require(modelPanel.selectedEffort=="","Pending effort was displayed before acceptance");
        settingValue(modelRoot,"Reasoning effort","Model default");
        modelClient.finishModelSettings(false);modelRoot=modelBuild();require(modelPanel.selectedEffort=="","Rejected effort was displayed");
        settingValue(modelRoot,"Reasoning effort","Model default");
        activate(modelContext,find(modelRoot,"Reasoning effort"));selectMenu(modelMenu,"High effort");
        modelClient.finishModelSettings(true);modelRoot=modelBuild();require(modelPanel.selectedEffort=="high","Accepted effort was not reconciled");
        settingValue(modelRoot,"Reasoning effort","High");
        modelClient.record.preferredModel="test-model";modelClient.record.preferredEffort="low";modelRoot=modelBuild();
        require(modelPanel.selectedModel=="test-model" && modelPanel.selectedEffort=="low","External model settings did not update the selectors");
        activate(modelContext,find(modelRoot,"Conversation model"));
        var beforeStale=modelClient.actions.length;modelClient.catalogRoot="/different";selectMenu(modelMenu,"Other model");
        require(modelClient.actions.length==beforeStale,"Stale model menu changed settings in another workspace");
        modelClient.catalogRoot="/repo";modelRoot=modelBuild();
        activate(modelContext,find(modelRoot,"Reasoning effort"));
        modelClient.record.preferredModel="other-model";selectMenu(modelMenu,"High effort");
        require(modelClient.actions.length==beforeStale,"Stale effort menu applied to a changed model");
        modelClient.record.preferredModel="unlisted-model";modelRoot=modelBuild();
        settingValue(modelRoot,"Conversation model","unlisted-model");
        modelContext.dispose();
		var draftClient = new FakeAgent(), draftContext = new UiContext(null, fonts, ui.ExosuitPalette.theme(true));
		draftClient.view.supportsImageUpload = true; draftClient.uploadEnabled = true;
		var fixtureImage = sys.io.File.getBytes("../../graphical/assets/icons/exosuit-16.png");
        var cancelClient=new FakeAgent();cancelClient.view.supportsImageUpload=true;cancelClient.deferUpload=true;
        var pickerDone:Null<(Null<String>,Null<haxe.io.Bytes>,Null<String>)->Void>=null;
        var cancelContext=new UiContext(null,fonts,ui.ExosuitPalette.theme(true));
        var cancelPanel=new CodexSessionPanel(function() return cancelClient,"session","/repo",function() {},new style.Theme(),new syntax.SyntaxRegistry(),function(_,_,_) {},function(_) {},null,
          {context:function() return "Project",explore:function() {},reviewChanges:function() {},
           chooseImage:function(done) pickerDone=done,pasteImage:function() return {bytes:fixtureImage,error:null}});
        function cancelBuild():RenderNode return cancelContext.submit(cancelPanel,new LayoutFrame(1000,900));
        var cancelRoot=cancelBuild();activate(cancelContext,find(cancelRoot,"Add image"));
        cancelRoot=cancelBuild();find(cancelRoot,"Adding image…");click(cancelContext,find(cancelRoot,"Cancel image upload"),1000,900);
        cancelRoot=cancelBuild();var stillAdding=false;
        cancelRoot.walk(function(node) {if(node.semantics!=null && node.semantics.label=="Adding image…") stillAdding=true;});
        require(!stillAdding,"Cancelled upload still shows a pending status");
        var finishPicker:(Null<String>,Null<haxe.io.Bytes>,Null<String>)->Void=cast pickerDone;finishPicker("late.png",fixtureImage,null);
        require(cancelClient.pendingUpload==null && cancelPanel.imageDrafts.length==0,"Cancelled picker started a late upload");
        cancelRoot=cancelBuild();require(cancelContext.focusWidget(find(cancelRoot,"Codex prompt").id),"Cannot focus paste cancellation fixture");
        cancelContext.key(UiEventKind.KeyDown,UiKey.V,UiModifier.Control);cancelRoot=cancelBuild();
        click(cancelContext,find(cancelRoot,"Cancel image upload"),1000,900);
        var finishUpload:(Null<String>,Null<String>)->Void=cast cancelClient.pendingUpload;finishUpload("late-paste",null);
        require(cancelClient.removedImages.indexOf("late-paste")>=0 && cancelPanel.imageDrafts.length==0,"Cancelled pasted upload was retained");
        cancelClient.pendingUpload=null;cancelRoot=cancelBuild();click(cancelContext,find(cancelRoot,"Add image"),1000,900);
        finishPicker=cast pickerDone;finishPicker("photo.png",fixtureImage,null);
        cancelClient.record.thread="other-thread";finishUpload=cast cancelClient.pendingUpload;finishUpload("stale-picker",null);
        require(cancelClient.removedImages.indexOf("stale-picker")>=0 && cancelPanel.imageDrafts.length==0,
          "Session replacement retained a stale image upload");cancelContext.dispose();
		var requestedPath:String = null; var clipboardBytes:Null<haxe.io.Bytes> = null; var pasteReads = 0;
		var worktreeOpens = 0, githubOpens = 0, pullRequestOpens = 0, availableActions = true;
		var repositoryMenu:Array<haxeon.ui.widgets.overlays.MenuItem> = null;
		var draftPanel = new CodexSessionPanel(function() return draftClient, "session", "/repo", function() {},
			new style.Theme(), new syntax.SyntaxRegistry(), function(items, _, _) repositoryMenu = items, function(_) {}, null,
			{context:function() return "Project", explore:function() {}, reviewChanges:function() {},
			 readContext:function(path, done) { requestedPath = path; done("actual contents\n", null); },
			 chooseImage:function(done) done("photo.png", fixtureImage, null),
             pasteImage:function() { pasteReads++; return {bytes:clipboardBytes, error:null}; },
			 canCreateWorktree:function() return availableActions, newWorktree:function() worktreeOpens++,
			 canOpenGithub:function() return availableActions, githubRepository:function() githubOpens++,
			 canOpenPullRequest:function() return availableActions, githubPullRequest:function() pullRequestOpens++});
		function draftBuild():RenderNode return draftContext.submit(draftPanel, new LayoutFrame(1000, 1000));
		var draftRoot = draftBuild();
		var repositoryButton = find(draftRoot, "Repository actions");
		require(draftContext.focusWidget(repositoryButton.id), "Repository actions cannot receive keyboard focus");
		draftContext.key(UiEventKind.KeyDown, UiKey.Enter);
		chooseMenu(repositoryMenu, "New worktree"); chooseMenu(repositoryMenu, "Open GitHub"); chooseMenu(repositoryMenu, "Open pull request page");
		require(worktreeOpens == 1 && githubOpens == 1 && pullRequestOpens == 1, "Workspace actions did not invoke their callbacks");
		availableActions = false; chooseMenu(repositoryMenu, "New worktree");
		require(worktreeOpens == 1, "Stale repository action bypassed its capability check");
		availableActions = true; draftClient.record.cwd = "/repo/other"; chooseMenu(repositoryMenu, "Open GitHub");
		require(githubOpens == 1, "Repository menu followed a moved session");
		draftClient.record.cwd = "/repo"; draftClient.control = false; draftRoot = draftBuild();
		click(draftContext, find(draftRoot, "Repository actions"), 1000, 1000); chooseMenu(repositoryMenu, "Open GitHub");
		require(githubOpens == 2, "Read-only repository navigation became unavailable");
		draftClient.control = true; availableActions = false;
		draftRoot = draftBuild();
		var unavailableVisible = false;
		draftRoot.walk(function(node) { if (node.semantics != null && node.semantics.label == "Repository actions") unavailableVisible = true; });
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
        var planClient=new FakeAgent(),planContext=new UiContext(null,fonts,ui.ExosuitPalette.theme(true));
        planClient.view.supportsMessageContent=true;
        planClient.messageContent="## Implementation plan\n\n1. Inspect the **current code**.\n2. Update [source](src/Main.hx).";
        planClient.view.items=[{id:"native-plan",turn:"turn",kind:"plan",title:"Plan",text:"Plan preview",detail:"",state:"completed",truncated:true,contentToken:"plan-token"}];
        var planOpened:Null<String>=null;
        var planPanel=new CodexSessionPanel(function() return planClient,"session","/repo",function() {},new style.Theme(),new syntax.SyntaxRegistry(),function(_,_,_) {},function(_) {},function(path) planOpened=path);
        var planRoot=planContext.submit(planPanel,new LayoutFrame(1000,1000));
        require(planClient.contentRequests==1,"Latest native plan did not retrieve its full source");
        find(planRoot,"Implementation plan");find(planRoot,"Copy plan");
        click(planContext,find(planRoot,"source"),1000,1000);
        require(planOpened=="src/Main.hx","Native plan file link did not use IDE navigation");
        planContext.dispose();
        for (imageInput in [{provider:"pi",action:"prompt"},{provider:"pi",action:"queue"},{provider:"pi",action:"steer"},{provider:"claude",action:"prompt"}]) {
          var imageAction=imageInput.action;
          var piImageClient = new FakeAgent();piImageClient.record.provider=imageInput.provider;
          piImageClient.record.state=imageAction=="prompt" ? "idle" : "working";
          piImageClient.view.supportsImageUpload=true;piImageClient.uploadEnabled=true;
          piImageClient.view.supportsQueue=imageInput.provider=="pi";piImageClient.view.supportsSteering=imageInput.provider=="pi";piImageClient.view.inputToken="input";
          var piImageContext=new UiContext(null,fonts,ui.ExosuitPalette.theme(true));
          var piImagePanel=new CodexSessionPanel(function() return piImageClient,"session","/repo",function() {},new style.Theme(),new syntax.SyntaxRegistry(),function(_,_,_) {},function(_) {},null,
            {context:function() return "Project",explore:function() {},reviewChanges:function() {},
             chooseImage:function(done) done("pi-photo.png",fixtureImage,null),pasteImage:function() return {bytes:fixtureImage,error:null}});
          var piImageRoot=piImageContext.submit(piImagePanel,new LayoutFrame(1000,1000));
          click(piImageContext,find(piImageRoot,"Add image"),1000,1000);
          require(piImagePanel.imageDrafts.length==1,"Negotiated provider capability did not enable image picker: "+imageInput.provider);
          piImageRoot=piImageContext.submit(piImagePanel,new LayoutFrame(1000,1000));
          piImageClient.acceptActions=false;
          click(piImageContext,find(piImageRoot,imageAction=="prompt" ? "Send" : imageAction=="queue" ? "Queue message" : "Steer now"),1000,1000);
          require(piImageClient.actions.length==1 && piImageClient.actions[0].indexOf(imageAction+"::")==0
            && piImageClient.lastImageIds!=null && piImageClient.lastImageIds[0]=="opaque-image" && piImagePanel.imageDrafts.length==1,
            "Pi image-only action lost image scope or failed draft retention: "+imageAction);
          piImageClient.view.supportsImageUpload=false;
          piImageRoot=piImageContext.submit(piImagePanel,new LayoutFrame(1000,1000));
          find(piImageRoot,"Image input is unavailable; remove images or reconnect.");
          require(!find(piImageRoot,imageAction=="prompt" ? "Send" : imageAction=="queue" ? "Queue message" : "Steer now").enabled,
            "Unavailable image capability left submission enabled");
          piImageContext.dispose();
        }
		fonts.dispose();
		trace("PASS: session rendering and provider actions across themes and widths");
		return 0;
	}
}
