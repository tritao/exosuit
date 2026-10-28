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
		ButtonThemeTestMain.main();
		SidebarLayoutTestMain.main();
		StatusBarTestMain.main();
		CodexMarkdownLayoutMain.main();
		SessionProjectionTestMain.main();
		var fonts = FontCollection.create();
		fonts.add("../../haxeon/packages/ui/vendor/skribidi/example/data/IBMPlexSans-Regular.ttf");
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
		fonts.dispose();
		trace("PASS: session rendering and provider actions across themes and widths");
		return 0;
	}
}
