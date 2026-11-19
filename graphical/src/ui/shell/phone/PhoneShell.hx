package ui.shell.phone;

import haxeon.ui.Insets;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutDistribution;
import haxeon.ui.LayoutStyle;
import haxeon.ui.core.View;
import haxeon.ui.icons.IconName;
import haxeon.ui.widgets.KeyedView;
import haxeon.ui.widgets.controls.Button;
import haxeon.ui.widgets.controls.ButtonVariant;
import haxeon.ui.widgets.layout.Stack;
import haxeon.ui.widgets.layout.StackChild;
import haxeon.ui.widgets.navigation.BottomBar;
import haxeon.ui.widgets.navigation.BottomBarItem;
import haxeon.ui.widgets.navigation.BottomSheet;
import haxeon.ui.widgets.navigation.ChoiceItem;
import haxeon.ui.widgets.navigation.ChoiceList;
import haxeon.ui.widgets.navigation.NavigationController;
import haxeon.ui.widgets.navigation.NavigationEntry;
import haxeon.ui.widgets.navigation.NavigationStack;
import haxeon.ui.widgets.navigation.Snackbar;
import haxeon.ui.widgets.text.TextField;
import ui.ExosuitApp;
import ui.shell.Shell;
import workspace.sessions.SessionIndex.SessionEntry;
import workspace.sessions.SessionIndex.SessionKind;
import workspace.sessions.SessionIndex.SessionSectioning;

private typedef Sheet = {
	key:String,
	title:String,
	content:Void->View,
	?closed:Void->Void
}

private typedef Snack = {
	text:String,
	label:Null<String>,
	action:Null<Void->Void>,
	until:Float
}

private typedef GroupNode = {
	id:String,
	name:String,
	parent:Null<String>,
	depth:Int
}

/**
	The phone's shell (ADR 0007, docs/phone-ui/CONTRACTS.md section E): a navigation stack with a bottom bar, full-screen
	views, sheets for choices and a snackbar for notices. Back pops screens only; the filters live here (PhoneState),
	so leaving a terminal returns to the list as it was.
**/
class PhoneShell implements Shell implements PhoneHost {
	/** The device's paired machines, set by the phone factory; null on the desktop in phone form (this machine's card is shown). */
	public static var remoteMachines:Null<workspace.client.MachinesPanelSource>;

	static inline final SESSION_PREFIX = "session:";
	static inline final SNACK_SECONDS = 4.0;

	final app:ExosuitApp;
	final phoneCore:PhoneCore;
	final phoneState:PhoneState;
	final controller:NavigationController;
	final sessionsScreen:SessionsScreen;
	final allScreen:AllSessionsScreen;
	final machinesScreen:MachinesScreen;
	var tab = "sessions";
	var sheet:Null<Sheet>;
	var snack:Null<Snack>;
	var renameText = "";

	public function new(app:ExosuitApp) {
		this.app = app;
		phoneCore = new PhoneCore(app);
		phoneState = new PhoneState();
		phoneState.workspace = phoneCore.currentWorkspace();
		sessionsScreen = new SessionsScreen(this);
		allScreen = new AllSessionsScreen(this);
		machinesScreen = new MachinesScreen(this, function() return remoteMachines);
		controller = new NavigationController(rootFor("sessions"));
		app.shellBack = handleBack;
	}

	public function core():PhoneCore return phoneCore;

	public function state():PhoneState return phoneState;

	public function kind():ShellKind return Phone;

	// ---- Shell

	public function open(view:ShellView):Void {
		if (isTab(view.id)) {
			showTab(view.id == "workbench" ? "sessions" : view.id);
			return;
		}
		pushSession(view.id, view.title, entryOf(view.id), view.build());
	}

	public function focus(id:String):Void {
		if (isTab(id)) {
			showTab(id == "workbench" ? "sessions" : id);
			return;
		}
		var wanted = SESSION_PREFIX + id;
		for (entry in controller.entries) if (entry.id == wanted) {
			while (controller.top.id != wanted && controller.pop()) {}
			app.requestFrame();
			return;
		}
		var found = entryOf(id);
		if (found != null) openSession(found);
	}

	public function close(id:String):Void {
		if (controller.top.id == SESSION_PREFIX + id) controller.pop();
		app.requestFrame();
	}

	public function focusedView():Null<String> {
		var top = controller.top.id;
		if (StringTools.startsWith(top, SESSION_PREFIX)) return top.substr(SESSION_PREFIX.length);
		return tab == "sessions" ? null : tab;
	}

	public function notice(text:String, ?actionLabel:String, ?action:Void->Void):Void {
		snack = {text: text, label: actionLabel, action: action, until: Sys.time() + SNACK_SECONDS};
		app.shellRedrawAt = Sys.time() + SNACK_SECONDS + 0.05;
		app.requestFrame();
	}

	public function choose(title:String, choices:Array<ShellChoice>, selected:Array<String>, multi:Bool, done:Array<String>->Void):Void {
		var items:Array<ChoiceItem> = [for (choice in choices) {id: choice.id, label: choice.label, detail: choice.detail, depth: choice.depth}];
		var chosen = selected.copy();
		showChoices("shell-choose", title, items, function() return chosen, multi, function(ids) {
			chosen = ids;
			if (!multi) {
				closeSheet(false);
				done(ids);
			}
		}, multi ? function() done(chosen) : null);
	}

	public function build():View {
		syncRoot();
		var made = phoneCore.pollNew();
		if (made != null) pushSession(made.id, made.title, entryOf(made.id), made.view);
		var waited = phoneCore.pollPending();
		if (waited != null) pushSession(waited.entry.id, waited.entry.name, waited.entry, waited.view);
		var context = app.hostContext;
		BottomBar.defaultBottomInset = context == null ? 0.0 : context.safeBottom;
		var page = new NavigationStack("phone-stack", controller, grow());
		var main:Array<KeyedView> = [new KeyedView("stack", page)];
		if (controller.depth == 1) main.push(new KeyedView("bar", bottomBar()));
		var layers = [new StackChild("main", new haxeon.ui.widgets.layout.Column("phone-main", main, grow()), 0.0, 0.0, 0, LayoutAxis.grow(), LayoutAxis.grow())];
		var current = sheet;
		if (current != null)
			layers.push(new StackChild("sheet", new BottomSheet("phone-sheet-" + current.key, current.title, current.content(), function() closeSheet(true)), 0.0, 0.0, 10,
				LayoutAxis.grow(), LayoutAxis.grow()));
		var message = snack;
		if (message != null) {
			if (Sys.time() > message.until) snack = null;
			else layers.push(new StackChild("snack", snackbar(message), 0.0, 0.0, 20, LayoutAxis.grow(), LayoutAxis.grow()));
		}
		return new Stack("phone-layers", layers, grow());
	}

	public function dispose():Void {
		app.shellBack = null;
	}

	// ---- PhoneHost

	public function openSession(entry:SessionEntry):Void {
		var view = phoneCore.open(entry);
		if (view != null) pushSession(entry.id, entry.name, entry, view);
		else notice("Opening " + entry.workspaceName + "…");
		app.requestFrame();
	}

	public function chooseScope():Void {
		var items:Array<ChoiceItem> = [{id: "*", label: "All workspaces", detail: "on " + phoneCore.machineName()}];
		for (workspace in phoneCore.workspaces())
			items.push({id: "ws:" + workspace.id, label: workspace.name, detail: phoneCore.workspaceRunning(workspace.id) ? "running" : "idle"});
		showChoices("scope", phoneCore.machineName(), items, function() return [phoneState.workspace == null ? "*" : "ws:" + phoneState.workspace], false,
			function(ids) {
				if (ids.length == 0) return;
				scopeTo(ids[0] == "*" ? null : ids[0].substr(3));
			});
	}

	public function scopeTo(workspaceId:Null<String>):Void {
		closeSheet(false);
		if (workspaceId != phoneState.workspace) phoneState.groups = [];
		phoneState.workspace = workspaceId;
		if (workspaceId != null) phoneCore.openWorkspace(workspaceId);
		showTab("sessions");
	}

	public function chooseGroups():Void {
		var nodes = groupNodes();
		var items:Array<ChoiceItem> = [for (node in nodes) {id: node.id, label: node.name, depth: node.depth}];
		showChoices("groups", "Group", items, function() return phoneState.groups, true, function(ids) {
			var before = phoneState.groups;
			var result = ids.copy();
			// A parent selects its children, and clearing it clears them.
			for (id in ids) if (before.indexOf(id) < 0) for (child in descendants(nodes, id)) if (result.indexOf(child) < 0) result.push(child);
			for (id in before) if (ids.indexOf(id) < 0) for (child in descendants(nodes, id)) result.remove(child);
			phoneState.groups = result;
		});
	}

	public function chooseKinds():Void {
		var items:Array<ChoiceItem> = [
			{id: "claude", label: "Claude"},
			{id: "codex", label: "Codex"},
			{id: "terminal", label: "Terminal"},
			{id: "chat", label: "Chat"}
		];
		showChoices("kinds", "Kind", items, function() return [for (k in phoneState.kinds) (k : String)], true, function(ids) {
			phoneState.kinds = [for (id in ids) (cast id : SessionKind)];
		});
	}

	public function chooseWorkspaces():Void {
		var items:Array<ChoiceItem> = [for (workspace in phoneCore.workspaces()) {id: workspace.id, label: workspace.name}];
		showChoices("workspaces", "Workspace", items, function() return phoneState.workspaces, true, function(ids) phoneState.workspaces = ids);
	}

	public function chooseSectioning(all:Bool):Void {
		var options = all ? [SessionSectioning.State, SessionSectioning.Workspace, SessionSectioning.Group, SessionSectioning.Day, SessionSectioning.None] : [SessionSectioning.Group, SessionSectioning.State, SessionSectioning.Day, SessionSectioning.None];
		var items:Array<ChoiceItem> = [for (option in options) {id: PhoneState.sectioningLabel(option), label: capital(PhoneState.sectioningLabel(option))}];
		var current = all ? phoneState.allSectioning : phoneState.sessionsSectioning;
		showChoices("sections-" + (all ? "all" : "ws"), "Sections", items, function() return [PhoneState.sectioningLabel(current)], false, function(ids) {
			if (ids.length == 0) return;
			for (option in options) if (PhoneState.sectioningLabel(option) == ids[0]) {
				if (all) phoneState.allSectioning = option; else phoneState.sessionsSectioning = option;
			}
			closeSheet(false);
		});
	}

	public function sessionMenu(entry:SessionEntry):Void {
		var items:Array<ChoiceItem> = [
			{id: "rename", label: "Rename"},
			{id: "restart", label: "Restart"},
			{id: "stop", label: "Stop"},
			{id: "move", label: "Move to group"}
		];
		showChoices("session-menu", entry.name, items, function() return [], false, function(ids) {
			if (ids.length == 0) return;
			closeSheet(false);
			sessionAction(entry, ids[0]);
		}, null, false);
	}

	public function newSession():Void {
		var wanted = phoneState.workspace;
		if (wanted == null || phoneCore.currentWorkspace() != wanted) {
			if (wanted == null) notice("Choose a workspace first");
			else {
				phoneCore.openWorkspace(wanted);
				notice("Opening " + phoneCore.workspaceName(wanted) + "… try again in a moment");
			}
			return;
		}
		var items:Array<ChoiceItem> = [{id: "claude", label: "Claude"}, {id: "codex", label: "Codex"}, {id: "terminal", label: "Terminal"}];
		showChoices("new-session", "New session", items, function() return [], false, function(ids) {
			if (ids.length == 0) return;
			closeSheet(false);
			phoneCore.create(ids[0] == "terminal" ? SessionKind.Terminal : ids[0] == "codex" ? SessionKind.Codex : SessionKind.Claude);
			notice("Starting…");
		}, null, false);
	}

	public function showTab(id:String):Void {
		tab = id;
		controller.replaceRoot(rootFor(id));
		app.requestFrame();
	}

	public function back():Void {
		controller.pop();
		app.requestFrame();
	}

	public function refresh():Void app.requestFrame();

	// ---- navigation

	function handleBack():Bool {
		if (sheet != null) {
			closeSheet(true);
			return true;
		}
		if (!controller.handleBack()) return false;
		app.requestFrame();
		return true;
	}

	static function isTab(id:String):Bool return id == "files" || id == "search" || id == "machines" || id == "sessions" || id == "workbench";

	/** The list root follows the scope: All sessions for the machine, Sessions for one workspace. */
	function syncRoot():Void {
		if (controller.depth != 1) return;
		var wanted = rootFor(tab);
		if (controller.top.id != wanted.id) controller.replaceRoot(wanted);
	}

	function rootFor(id:String):NavigationEntry {
		switch id {
			case "files": return {id: "files", build: function() return panelScreen("Files", "files")};
			case "search": return {id: "search", build: function() return panelScreen("Search", "search")};
			case "machines": return {id: "machines", build: function() return machinesScreen};
			default:
				return phoneState.workspace == null ? {id: "all-sessions", build: allScreen.build} : {id: "sessions", build: sessionsScreen.build};
		}
	}

	/** The existing Files or Search panel, full screen under a heading. */
	function panelScreen(title:String, panelId:String):View {
		var panel:View = phoneCore.panel(panelId);
		if (panel == null) panel = PhoneUi.text(title + " is not available.", 15, PhoneUi.SECONDARY);
		var body = PhoneUi.column("panel-body", [PhoneUi.kv("panel", panel)], function(s) {
			s.width = LayoutAxis.grow();
			s.height = LayoutAxis.grow();
		});
		return PhoneChrome.screen(panelId + "-screen", [PhoneUi.kv("heading", PhoneChrome.heading(title)), PhoneUi.kv("rule", PhoneUi.rule("rule")), PhoneUi.kv("body", body)]);
	}

	function pushSession(id:String, title:String, entry:Null<SessionEntry>, panel:View):Void {
		var key = SESSION_PREFIX + id;
		if (controller.top.id == key) return;
		var screen = new TerminalScreen(this, title, entry, panel);
		controller.push({id: key, build: screen.build});
		app.requestFrame();
	}

	function entryOf(id:String):Null<SessionEntry> {
		for (entry in phoneCore.index().entries) if (entry.id == id) return entry;
		return null;
	}

	function bottomBar():View {
		var items:Array<BottomBarItem> = [
			{id: "sessions", icon: IconName.Terminal, label: "Sessions"},
			{id: "files", icon: IconName.FolderClosed, label: "Files"},
			{id: "search", icon: IconName.Search, label: "Search"},
			{id: "machines", icon: IconName.Remote, label: "Machines"}
		];
		return new BottomBar("phone-bar", items, tab, showTab);
	}

	// ---- sheets

	function closeSheet(dismissed:Bool):Void {
		var closing = sheet;
		sheet = null;
		var done = closing == null ? null : closing.closed;
		if (dismissed && done != null) done();
		app.requestFrame();
	}

	/**
		A ChoiceList sheet. `selected` is read on every build; `onChange` gets the new selection; `closed` runs when a
		multi-select sheet is dismissed.
	**/
	function showChoices(key:String, title:String, items:Array<ChoiceItem>, selected:Void->Array<String>, multi:Bool, onChange:Array<String>->Void,
			?closed:Void->Void, searchable:Bool = true):Void {
		sheet = {
			key: key,
			title: title,
			content: function() return new ChoiceList("choices-" + key, items, selected(), multi, function(ids) {
				onChange(ids);
				app.requestFrame();
			}, searchable ? "Search" : null),
			closed: closed
		};
		app.requestFrame();
	}

	function snackbar(message:Snack):View {
		var bar = new Snackbar("phone-snack", message.text, message.label, function() {
			var action = message.action;
			snack = null;
			if (action != null) action();
			app.requestFrame();
		});
		return PhoneUi.column("snack-holder", [new KeyedView("bar", bar)], function(s) {
			s.width = LayoutAxis.stretch();
			s.height = LayoutAxis.stretch();
			s.childDistribution = LayoutDistribution.End;
			s.padding = new Insets(12, 0, 12, 84);
		});
	}

	// ---- session actions

	function sessionAction(entry:SessionEntry, action:String):Void {
		if (!phoneCore.canOperate(entry)) {
			notice("This session cannot be changed from here.");
			return;
		}
		switch action {
			case "rename":
				renameText = entry.name;
				sheet = {key: "rename", title: "Rename", content: function() return renameSheet(entry)};
				app.requestFrame();
			case "restart":
				notice(phoneCore.restart(entry) ? "Restarting " + entry.name : "Could not restart.");
			case "stop":
				notice(phoneCore.stop(entry) ? "Stopping " + entry.name : "Could not stop.");
			case "move":
				var groups = phoneCore.groupsOf(entry.workspaceId);
				var items:Array<ChoiceItem> = [{id: "", label: "No group"}];
				for (group in groups) items.push({id: group.id, label: group.name, depth: group.depth});
				showChoices("move", "Move to group", items, function() return [], false, function(ids) {
					if (ids.length == 0) return;
					closeSheet(false);
					notice(phoneCore.move(entry, ids[0]) ? "Moved " + entry.name : "Could not move.");
				});
			default:
		}
	}

	function renameSheet(entry:SessionEntry):View {
		var field = new TextField("rename-field", renameText, function(value) {
			renameText = value;
			app.requestFrame();
		}, null, "Name");
		field.style.width = LayoutAxis.stretch();
		var save = new Button("Save", null, function() {
			closeSheet(false);
			notice(phoneCore.rename(entry, renameText) ? "Renamed" : "Could not rename.");
		}, "rename-save", StringTools.trim(renameText) != "", ButtonVariant.Primary);
		return PhoneUi.column("rename-content", [PhoneUi.kv("field", field), PhoneUi.kv("save", save)], function(s) {
			s.width = LayoutAxis.stretch();
			s.padding = new Insets(16, 8, 16, 16);
			s.childGap = 12;
		});
	}

	// ---- groups

	/** The groups of the sessions in scope, parents before children, as the Group sheet lists them. */
	function groupNodes():Array<GroupNode> {
		var found:Map<String, GroupNode> = [];
		var order:Array<String> = [];
		for (entry in phoneCore.index().entries) {
			if (phoneState.workspace != null && entry.workspaceId != phoneState.workspace) continue;
			for (i in 0...entry.groupPath.length) {
				var id = entry.groupPath[i];
				if (found.exists(id)) continue;
				found.set(id, {id: id, name: i < entry.groupNames.length ? entry.groupNames[i] : id, parent: i == 0 ? null : entry.groupPath[i - 1], depth: i});
				order.push(id);
			}
		}
		var result:Array<GroupNode> = [];
		var walk:(Null<String>) -> Void = null;
		walk = function(parent:Null<String>) {
			var children:Array<GroupNode> = [];
			for (id in order) {
				var node = found.get(id);
				if (node != null && node.parent == parent) children.push(node);
			}
			children.sort(function(a, b) return a.name < b.name ? -1 : a.name > b.name ? 1 : 0);
			for (child in children) {
				result.push(child);
				walk(child.id);
			}
		};
		walk(null);
		return result;
	}

	static function descendants(nodes:Array<GroupNode>, id:String):Array<String> {
		var result:Array<String> = [];
		var pending = [id];
		while (pending.length > 0) {
			var parent = pending.pop();
			for (node in nodes) if (node.parent == parent) {
				result.push(node.id);
				pending.push(node.id);
			}
		}
		return result;
	}

	static function capital(value:String):String return value.substr(0, 1).toUpperCase() + value.substr(1);

	static function grow():LayoutStyle {
		var style = new LayoutStyle();
		style.width = LayoutAxis.grow();
		style.height = LayoutAxis.grow();
		return style;
	}
}
