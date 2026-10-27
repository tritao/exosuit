package app;

import haxeon.ui.LayoutFrame;
import haxeon.ui.core.UiEvent;
import haxeon.ui.core.UiEventKind;
import haxeon.ui.widgets.overlays.MenuItem;
import ui.TerminalContextActions;
import workspace.service.WorkspaceTerminalProtocol.TerminalRecord;

private class TerminalFixture implements ui.TerminalPanel {
	public var stops = 0;
	public var closes = 0;
	public function new() {}
	public function poll():Void {}
	public function terminate(force:Bool):Void stops++;
	public function close():Void closes++;
	public function status():String return "running";
	public function workspaceName():Null<String> return null;
	public function columns():Int return 80;
	public function rows():Int return 24;
	public function build(context:haxeon.ui.core.BuildContext):haxeon.ui.core.RenderNode
		return new haxeon.ui.widgets.text.Text("fixture terminal").build(context);
}

@:access(ui.ExosuitApp)
@:access(ui.CommandMenu)
class TerminalContextMenuTestMain {
	static function require(value:Bool, message:String):Void { if (!value) throw message; }
	static function item(items:Array<MenuItem>, key:String):MenuItem {
		for (entry in items) if (entry.key == "terminal-" + key) return entry;
		throw "missing terminal action " + key;
	}
	static function action(app:ui.ExosuitApp, key:String):MenuItem {
		var menu:ui.CommandMenu = cast app.contextMenu;
		var entries:Array<MenuItem> = cast menu.customItems;
		return item(entries,key);
	}
	static function main():Int {
		var record:TerminalRecord = {id:"fixture", name:"Terminal 1", group:"work", cwd:"/tmp", instance:"test",
			state:"running", exitCode:0, available:true, revision:haxe.Int64.ofInt(1)};
		var calls:Array<String> = [];
		var run = function(action:String) { calls.push(action); };
		var running = TerminalContextActions.build(record, true, true, false, run);
		require(item(running,"stop").enabled && item(running,"close").enabled && item(running,"close").label=="Close Terminal", "running terminal lacked close action");
		require(![for (entry in running) entry.key].contains("terminal-restart"), "running terminal offered restart");
		for (entry in TerminalContextActions.build(record, true, false, false, run))
			if (["terminal-open","terminal-editor","terminal-panel"].indexOf(entry.key) < 0)
				require(!entry.enabled, "read-only terminal offered a mutation");
		for (entry in TerminalContextActions.build(record, true, true, true, run)) require(!entry.enabled, "busy catalog offered an action");
		record.state = "starting";
		require(item(TerminalContextActions.build(record,true,true,false,run),"close").enabled, "starting terminal lacked close action");
		record.state = "exited";
		require(item(TerminalContextActions.build(record,true,true,false,run),"restart").enabled,"ended terminal lacked restart");
		for (entry in TerminalContextActions.build(record,true,false,false,run))
			require(entry.key != "terminal-restart","read-only terminal offered restart");
		require(!item(TerminalContextActions.build(record,true,true,true,run),"restart").enabled,"busy terminal offered restart");
		record.state = "lost"; record.available = false;
		var lost = TerminalContextActions.build(record,true,true,false,run);
		require(item(lost,"close").enabled && ![for (entry in lost) entry.key].contains("terminal-stop") && ![for (entry in lost) entry.key].contains("terminal-open"),
			"lost terminal actions confused attachment, process state, and removal");
		item(lost,"restart").onSelect();
		item(lost,"close").onSelect();
		require(calls.join(",") == "restart,close", "lost terminal removal did not reach its action");

		var catalog:workspace.service.WorkspaceTerminalProtocol.TerminalCatalog = {
			instance:"restarted-daemon", groups:[], terminals:[record], next:null
		};
		require(TerminalContextActions.isCurrent(record,catalog,"restarted-daemon"), "retained terminal from an earlier daemon could not be managed");
		require(!TerminalContextActions.isCurrent(record,catalog,"previous-daemon"), "stale menu survived a daemon replacement");

		var rootGroup:workspace.service.WorkspaceProtocol.WorkspaceGroup = {id:"root",name:"Root",cwd:"/tmp",revision:1};
		var childGroup:workspace.service.WorkspaceProtocol.WorkspaceGroup = {id:"child",name:"Child",cwd:null,parent:"root",revision:1};
		catalog.workspaceRoot = "/tmp"; catalog.groups = [rootGroup,childGroup];
		var agentCatalog:workspace.service.WorkspaceAgentProtocol.AgentCatalog = {instance:"restarted-daemon",root:"/tmp",records:[],status:"ready"};
		require(!ui.GroupContextActions.canParent("root","child",catalog.groups) && !ui.GroupContextActions.canParent("child","child",catalog.groups),
			"group move picker allowed a cycle");
		require(ui.GroupContextActions.canParent("child",null,catalog.groups), "group could not move to top level");
		require(!ui.GroupContextActions.empty("root",catalog,agentCatalog) && !ui.GroupContextActions.empty("work",catalog,agentCatalog),
			"group removal ignored a child or terminal");
		require(!ui.GroupContextActions.empty("child",catalog,null) && ui.GroupContextActions.empty("child",catalog,agentCatalog),
			"group removal did not require a complete empty projection");

		var fonts = haxeon.ui.FontCollection.create();
		fonts.add("../../haxeon/packages/ui/vendor/skribidi/example/data/IBMPlexSans-Regular.ttf");
		TerminalRestartTests.run(fonts);
		var app = new ui.ExosuitApp(fonts, ui.ExosuitPalette.theme(false), null, null, null, null, false,
			function(_, _, _) return new TerminalFixture());
		var firstPanel = new TerminalFixture(), secondPanel = new TerminalFixture();
		var first = new ui.UiTerminalTab("first", "First", "/tmp", firstPanel);
		var second = new ui.UiTerminalTab("second", "Second", "/tmp", secondPanel);
		app.host.panelTerminals.push(first); app.host.panelTerminals.push(second);
		app.host.activePanelTerminalIndex = 1;
		app.openTerminalPanel();
		var root = app.submit(new LayoutFrame(900,600));
		var header:haxeon.ui.core.RenderNode = null;
		root.walk(function(node) {
			if (node.semantics != null && node.semantics.role == haxeon.ui.semantics.AccessibilityRole.Tab && node.semantics.label == "First") header = node;
		});
		require(header != null, "missing terminal tab header");
		var bounds = header.globalBounds();
		app.ui.pointerDown(bounds.x + bounds.width / 2,bounds.y + bounds.height / 2,1);
		app.ui.pointerUp(bounds.x + bounds.width / 2,bounds.y + bounds.height / 2,1);
		require(app.contextMenu != null, "terminal tab right-click did not open resource actions");
		var event = new UiEvent(UiEventKind.PointerDown, root.id,100,100,0,0,1);
		action(app,"rename").onSelect();
		app.host.commandView.textInput("Renamed");
		app.host.commandView.keyPressed(platform.Platform.KEY_ENTER,0);
		require(first.title == "Renamed" && second.title == "Second", "rename targeted the active terminal instead of the clicked terminal");
		app.showTerminalContextMenu(first,event);
		action(app,"editor").onSelect();
		require(app.host.terminalPaneFor(first) != null && app.host.panelTerminals.indexOf(first) < 0 && firstPanel.closes == 0,
			"move to editor duplicated or closed the terminal");
		app.showTerminalContextMenu(first,event);
		action(app,"panel").onSelect();
		require(app.host.terminalPaneFor(first) == null && app.host.panelTerminals.indexOf(first) >= 0 && firstPanel.closes == 0,
			"move to panel duplicated or closed the terminal");
		app.showTerminalContextMenu(first,event);
		action(app,"stop").onSelect();
		require(firstPanel.stops == 1 && secondPanel.stops == 0, "stop targeted a different terminal");
		app.host.activePanelTerminalIndex = app.host.panelTerminals.indexOf(second);
		app.showTerminalContextMenu(first,event);
		action(app,"close").onSelect();
		require(firstPanel.closes == 1 && firstPanel.stops == 2 && secondPanel.closes == 0 && app.host.panelTerminals.indexOf(first) < 0 && app.host.activePanelTerminal() == second,
			"closing a view affected a different terminal");
		TerminalCloseTests.run(app);
		app.dispose();
		fonts.dispose();
		Sys.println("PASS: terminal action permissions, lifecycle states, clicked targets, rename, placement, stop and close");
		return 0;
	}
}
