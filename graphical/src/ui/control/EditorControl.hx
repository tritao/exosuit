package ui.control;

import editor.Document;
import haxeon.platform.event.EventSubscription;
import haxeon.ui.core.UiContext;
import nativekit.ffi.NativeKit;
import nativekit.ffi.NativeKitTypes;
import exohost.ExohostLink;
import exohost.control.ControlError;
import ui.ExosuitApp;
import ui.TerminalPane;
import ui.UiEditorTab;

private typedef Answer = (Null<Dynamic>, Null<ControlError>) -> Void;

private typedef Waiting = {
	var ready:Void->Null<Dynamic>;
	var until:Float;
	var answer:Answer;
	var what:String;
}

/**
	The window's side of the control plane (docs/design/exohostctl/TDD-exosuit-ctl.md §8): the methods exohost routes to this
	window over its link, each one the path a user's action takes, so a program drives the product's own logic.

	- Pragtical control protocol v1: `window.focus`, `editor.open {path, line?, column?}`, `editor.documents`,
	  `editor.save {path? | document_id?}`, `project.add {path}`, `project.change {path}`; the events `document.opened`
	  and `project.changed`.
	- `exosuit.quit {mode}` (prompt, recover, save).
	- T1, reading: `exosuit.ui.snapshot {state?}` (devtools.UiSnapshot, plus the app's state when asked),
	  `exosuit.state.get {path?}` (ExosuitDiagnostics.automationState, or one field of it); the event `exosuit.ui.changed`.
	- T2, commands: `exosuit.commands.list {available?}`, `exosuit.command.run {name}`.
	- T3, workspaces and windows: `exosuit.workspace.open {id}`, `exosuit.context.switch {context}`,
	  `exosuit.window.new {context?, paths?}`, `exosuit.folder.add {path, workspace?}`.
	- T4, terminals and sessions, through what a Workbench row's menu does: `exosuit.terminals.list`,
	  `exosuit.terminal.create {workspace?, group?}`, `exosuit.terminal.open|send|read {id, text?}`, `exosuit.agents.list`,
	  `exosuit.agent.create {workspace?, group?, provider?}`; the event `exosuit.terminal.output`.
	- T5, dialogs: `exosuit.dialogs.list`, `exosuit.dialog.answer {id, paths? | choice?}` (DrivenDialogs).
	- T6, element input into the window's own event queue (SyntheticInput): `exosuit.ui.activate`, `exosuit.ui.focus`,
	  `exosuit.ui.type {text}`, `exosuit.ui.key {chord}`, `exosuit.ui.hover`, `exosuit.ui.scroll`,
	  `exosuit.ui.drag {from, to}`. An element is named by
	  its snapshot `element_id`, or a point by `x` and `y` in the snapshot's logical pixels; `fx`, `fy` pick a point
	  inside an element (fractions of its size, 0.5 by default).

	A method that changes something answers once it is done, under exohost's 10 s request timeout. One that acts like the
	user answers `busy` while the user's own input is recent (SyntheticInput).
**/
@:access(ui.ExosuitApp)
@:access(controller.FileController)
class EditorControl {
	static inline final WAIT_SECONDS = 9.5;

	final app:ExosuitApp;
	final link:ExohostLink;
	final input:SyntheticInput;
	final dialogs:DrivenDialogs;
	final ui:UiContext;
	final focusSubscription:Null<EventSubscription>;
	final waiting:Array<Waiting> = [];
	/** Documents by the id this window gives them (`document:<n>`), stable for the process. */
	final documents:Array<Document> = [];
	var lastFrame = -1;
	var lastChangedAt = 0.0;
	var changes = 0;
	final terminalRows:Map<String, String> = [];
	var terminalSequence = 0;
	var lastTerminalCheck = 0.0;

	public function new(app:ExosuitApp, link:ExohostLink, input:SyntheticInput, dialogs:DrivenDialogs) {
		this.app = app;
		this.link = link;
		this.input = input;
		this.dialogs = dialogs;
		ui = app.context();
		input.requestFrame = app.requestFrame;
		link.onRequest = handle;
		var host = app.hostContext;
		// The window took the OS focus: it is now the most recently used window, where exohost routes calls without a target.
		focusSubscription = host == null ? null : host.events.listen(function(event) {
			switch event {
				case WindowStateChanged(_, flags) if (flags.contains(WindowStateFlags.Active)):
					link.focused();
				case _:
			}
		});
	}

	/**
		Moves synthetic input along, answers calls that wait for something, and sends the events subscribers want. A
		failure here is reported, never thrown: driving the window must not take it down.
	**/
	public function poll():Void {
		try pollControl() catch (error:Dynamic) app.application.reportError("control", Std.string(error));
	}

	function pollControl():Void {
		input.poll();
		dialogs.poll();
		var now = Sys.time();
		var index = waiting.length;
		while (index-- > 0) {
			var item = waiting[index];
			var result:Null<Dynamic> = null;
			try result = item.ready() catch (error:Dynamic) {
				waiting.splice(index, 1);
				item.answer(null, ControlError.internal(Std.string(error)));
				continue;
			}
			if (result != null) {
				waiting.splice(index, 1);
				item.answer(result, null);
			} else if (now >= item.until) {
				waiting.splice(index, 1);
				item.answer(null, ControlError.retry("timeout", item.what + " did not happen in time"));
			}
		}
		if (link.wants("exosuit.ui.changed")) {
			var metrics = ui.frameMetrics, frame = metrics == null ? -1 : metrics.frameNumber;
			if (frame != lastFrame && now - lastChangedAt >= 0.1) {
				lastFrame = frame;
				lastChangedAt = now;
				link.emit("exosuit.ui.changed", {seq: ++changes, at: now, frame: frame});
			}
		}
		if (link.wants("exosuit.terminal.output") && now - lastTerminalCheck >= 0.1) {
			lastTerminalCheck = now;
			for (tab in app.host.allTerminalTabs()) {
				var pane = pane(tab);
				if (pane == null || tab.disposed) continue;
				var rows:Array<String> = pane.diagnosticState().lines;
				var text = rows.join("\n");
				if (terminalRows.get(tab.resourceId) != text) {
					terminalRows.set(tab.resourceId, text);
					link.emit("exosuit.terminal.output", {id: tab.resourceId, sequence: ++terminalSequence});
				}
			}
		}
	}

	function handle(method:String, params:Dynamic, answer:Answer):Void {
		switch method {
			case "exosuit.quit":
				app.quitWindow(text(params, "mode", "prompt"), answer);
			case "window.focus":
				var host = app.hostContext;
				if (!Std.isOfType(host, haxeon.ui.host.DesktopUiHostContext)) {
					answer(null, new ControlError("unsupported", "this window cannot be raised"));
					return;
				}
				var desktop:haxeon.ui.host.DesktopUiHostContext = cast host;
				NativeKit.nk_window_restore(desktop.window);
				NativeKit.nk_window_activate(desktop.window);
				link.focused();
				answer({focused: true}, null);
			case "editor.open":
				var path = requirePath(params, answer);
				if (path == null) return;
				var folder = sys.FileSystem.exists(path) && sys.FileSystem.isDirectory(path);
				// A folder opens as its workspace, the one that holds it or else a new one, even when the window is on
				// another (openFolderWorkspace). Without exohost's catalog the window shows it as a loose folder.
				if (folder && app.machineClient != null && app.machineClient.machine != null) {
					app.folderOpening = null;
					app.openFolderWorkspace(path, true);
				} else
					app.openArgument(path, integer(params, "line"), integer(params, "column"));
				app.requestFrame();
				var opened:Dynamic = {path: path};
				var document = documentAt(path);
				if (document != null) opened.document_id = documentId(document);
				link.emit("document.opened", opened);
				answer(opened, null);
			case "editor.documents":
				answer({documents: [for (document in app.application.documents.documents) describeDocument(document)]}, null);
			case "editor.save":
				save(params, answer);
			case "project.add" | "exosuit.folder.add":
				var path = requirePath(params, answer);
				if (path == null) return;
				var workspaceId = text(params, "workspace", app.workbenchActions.currentWorkspace());
				var entry = app.workbenchActions.workspaceById(workspaceId);
				if (entry == null) {
					answer(null, new ControlError("not_found", workspaceId == null ? "this window has no workspace open" : "no workspace " + workspaceId));
					return;
				}
				app.workbenchActions.addFolder(entry, path, function(failure) {
					if (failure != null) {
						answer(null, ControlError.internal(failure));
						return;
					}
					link.emit("project.changed", {path: path, workspace: entry.id});
					answer({path: path, workspace: entry.id}, null);
				});
			case "project.change":
				var path = requirePath(params, answer);
				if (path == null) return;
				if (!sys.FileSystem.exists(path) || !sys.FileSystem.isDirectory(path)) {
					answer(null, new ControlError("invalid_argument", path + " is not a folder"));
					return;
				}
				// The model's one rule: the workspace that holds the folder, or a new one named after it (INTENT 3).
				app.openArgument(path);
				app.requestFrame();
				link.emit("project.changed", {path: path});
				answer({path: path, status: "confirmed"}, null);
			case "exosuit.ui.snapshot":
				var picture:Dynamic = devtools.UiSnapshot.capture(ui);
				picture.at = Sys.time();
				picture.windowId = link.windowId;
				if (Reflect.field(params, "state") == true) picture.state = app.diagnostics.automationState();
				answer(picture, null);
			case "exosuit.state.get":
				var state:Dynamic = app.diagnostics.automationState();
				var path = text(params, "path", null);
				if (path != null)
					for (field in path.split(".")) {
						state = state == null ? null : Reflect.field(state, field);
					}
				answer({state: state}, null);
			case "exosuit.commands.list":
				installCommands();
				var available = Reflect.field(params, "available") == true;
				var listed:Array<Dynamic> = [];
				for (id in ui.commands.ids()) {
					var command = ui.commands.get(id);
					if (command == null) continue;
					var enabled = command.isEnabled(ui.commandContext);
					if (available && !enabled) continue;
					listed.push({name: id, label: command.label, enabled: enabled});
				}
				answer({commands: listed}, null);
			case "exosuit.command.run":
				var name = text(params, "name", null);
				installCommands();
				if (name == null || ui.commands.get(name) == null) {
					answer(null, new ControlError("not_found", "no command " + name));
					return;
				}
				if (!input.begin(answer)) return;
				var before = dialogs.list().length;
				var ran = ui.commands.execute(name);
				app.requestFrame();
				answer(prompted({ran: ran}, before), null);
			case "exosuit.workspace.open":
				var id = text(params, "id", null);
				if (app.workbenchActions.workspaceById(id) == null) {
					answer(null, new ControlError("not_found", "exohost lists no workspace " + id));
					return;
				}
				app.workbenchActions.openById(id);
				answer({opened: id}, null);
			case "exosuit.context.switch":
				switchContext(text(params, "context", null), answer);
			case "exosuit.window.new":
				var paths:Array<String> = [];
				var listed:Dynamic = Reflect.field(params, "paths");
				if (Std.isOfType(listed, Array))
					for (item in (listed : Array<Dynamic>)) if (Std.isOfType(item, String)) paths.push(item);
				var failure = workspace.NewWindow.open(text(params, "context", app.application.activeContext.key()), paths);
				if (failure != null) answer(null, ControlError.internal(failure));
				else answer({started: true}, null);
			case "exosuit.terminals.list":
				var state:Dynamic = app.diagnostics.automationState();
				var open = [for (tab in app.host.allTerminalTabs()) if (!tab.disposed) tab.resourceId];
				var terminals:Array<Dynamic> = state.terminals;
				answer({terminals: [for (terminal in terminals) {id: terminal.id, name: terminal.name, group: terminal.group, order: terminal.order,
					state: terminal.state, agentProvider: terminal.agentProvider, open: open.indexOf(terminal.id) >= 0}]}, null);
			case "exosuit.agents.list":
				var state:Dynamic = app.diagnostics.automationState();
				answer({agents: state.agents}, null);
			case "exosuit.terminal.create" | "exosuit.agent.create":
				create(method == "exosuit.terminal.create", params, answer);
			case "exosuit.terminal.open":
				var id = text(params, "id", null);
				withTerminal(id, answer, function(pane) return {id: id});
			case "exosuit.terminal.send":
				var id = text(params, "id", null), typed = text(params, "text", null);
				if (typed == null) {
					answer(null, new ControlError("invalid_argument", "terminal.send needs text"));
					return;
				}
				if (!input.begin(answer)) return;
				withTerminal(id, answer, function(pane) {
					pane.sendText(typed);
					return {id: id, sent: typed.length};
				});
			case "exosuit.terminal.read":
				var id = text(params, "id", null);
				withTerminal(id, answer, function(pane) {
					var state:Dynamic = pane.diagnosticState();
					return {id: id, rows: state.lines, cursor: {row: state.cursorRow, col: state.cursorColumn}, loading: state.loading,
						win32Input: state.win32Input};
				});
			case "exosuit.dialogs.list":
				answer({dialogs: dialogs.list()}, null);
			case "exosuit.dialog.answer":
				var listed:Dynamic = Reflect.field(params, "paths");
				var paths:Null<Array<String>> = Std.isOfType(listed, Array) ? [for (item in (listed : Array<Dynamic>)) Std.string(item)] : null;
				if (!input.begin(answer)) return;
				var failure = dialogs.answer(text(params, "id", ""), paths, text(params, "choice", null));
				app.requestFrame();
				if (failure != null) answer(null, failure);
				else answer({answered: true}, null);
			case "exosuit.ui.activate":
				var point = target(params, answer);
				if (point == null) return;
				var before = dialogs.list().length;
				input.click(point.x, point.y, text(params, "button", "left"), clampCount(integer(params, "count")), function(result, error) {
					answer(error == null ? prompted(result, before) : null, error);
				});
			case "exosuit.ui.focus":
				var id = integer(params, "element_id");
				var node = id == null ? null : devtools.UiSnapshot.find(ui, id);
				if (node == null) {
					answer(null, new ControlError("not_found", "no visible element " + id));
					return;
				}
				if (!input.begin(answer)) return;
				var focused = ui.focus.focus(node.id);
				app.requestFrame();
				answer({focused: focused}, null);
			case "exosuit.ui.type":
				var typed = text(params, "text", null);
				if (typed == null) answer(null, new ControlError("invalid_argument", "ui.type needs text"));
				else input.type(typed, answer);
			case "exosuit.ui.key":
				var chord = text(params, "chord", null);
				if (chord == null) {
					answer(null, new ControlError("invalid_argument", "ui.key needs a chord"));
					return;
				}
				var before = dialogs.list().length;
				input.key(chord, function(result, error) answer(error == null ? prompted(result, before) : null, error));
			case "exosuit.ui.hover":
				var point = target(params, answer);
				if (point == null) return;
				input.hover(point.x, point.y, answer);
			case "exosuit.ui.scroll":
				var point = target(params, answer);
				if (point == null) return;
				var notches = integer(params, "notches");
				input.scroll(point.x, point.y, notches == null ? -3 : notches, answer);
			case "exosuit.ui.drag":
				var from = target(Reflect.field(params, "from"), answer);
				if (from == null) return;
				var to = target(Reflect.field(params, "to"), answer);
				if (to == null) return;
				input.drag(from.x, from.y, to.x, to.y, answer);
			default:
				answer(null, new ControlError("unsupported", method + " is not a method of an Exosuit window"));
		}
	}

	/** `result` with `prompted`: the dialog the action opened, which waits for `exosuit.dialog.answer`. */
	function prompted(result:Dynamic, before:Int):Dynamic {
		var listed = dialogs.list();
		var value:Dynamic = result == null ? {} : result;
		if (listed.length > before) value.prompted = listed[listed.length - 1].id;
		return value;
	}

	/** Saves every document, or the one named by `path` or `document_id`. */
	function save(params:Dynamic, answer:Answer):Void {
		var id = text(params, "document_id", null), path = text(params, "path", null);
		if (id == null && path == null) {
			app.application.files.saveAll(function(saved) {
				if (saved) answer({saved: true}, null);
				else answer(null, new ControlError("permission_denied", "a document was not saved"));
			});
			return;
		}
		var document:Null<Document> = null;
		for (candidate in app.application.documents.documents)
			if (id != null && documentId(candidate) == id || path != null && candidate.hasBackingPath() && workspace.PathKey.same(candidate.requirePath(), path))
				document = candidate;
		if (document == null) {
			answer(null, new ControlError("not_found", "no open document " + (id != null ? id : path)));
			return;
		}
		if (app.application.files.saveDocument(document)) answer({saved: true, document_id: documentId(document)}, null);
		else answer(null, ControlError.internal("could not save " + document.title));
	}

	/** New Terminal or New Agent Session as a Workbench row does it; answers with what appeared once it is there. */
	function create(terminal:Bool, params:Dynamic, answer:Answer):Void {
		var panel = app.workbenchPanel;
		if (panel == null) {
			answer(null, new ControlError("unsupported", "the Workbench is not ready in this window"));
			return;
		}
		var workspaceId = text(params, "workspace", null);
		if (workspaceId != null && app.workbenchActions.workspaceById(workspaceId) == null) {
			answer(null, new ControlError("not_found", "exohost lists no workspace " + workspaceId));
			return;
		}
		var before = tabKeys();
		if (!input.begin(answer)) return;
		panel.make(workspaceId, text(params, "group", workspace.service.WorkspaceProtocol.ROOT_GROUP), terminal, text(params, "provider", null));
		app.requestFrame();
		wait(terminal ? "a new terminal" : "a new agent session", answer, function() {
			for (key => value in tabKeys())
				if (!before.exists(key)) return value;
			return null;
		});
	}

	/** Every open terminal and agent tab, by `kind:id`: what `create` answers with. */
	function tabKeys():Map<String, Dynamic> {
		var result:Map<String, Dynamic> = [];
		for (tab in app.host.allTerminalTabs())
			if (!tab.disposed) result.set("terminal:" + tab.resourceId, {kind: "terminal", id: tab.resourceId, title: tab.title});
		for (pane in app.host.panes)
			for (item in pane.items)
				switch item {
					case Agent(agent): result.set("agent:" + agent.resource, {kind: "agent", id: agent.resource, title: agent.title});
					default:
				}
		return result;
	}

	/** Runs `action` on the open terminal `id`; a terminal of the workspace's catalog that is not open is opened first. */
	function withTerminal(id:Null<String>, answer:Answer, action:TerminalPane->Dynamic):Void {
		if (id == null) {
			answer(null, new ControlError("invalid_argument", "a terminal id is needed"));
			return;
		}
		var open = openTerminal(id);
		if (open != null) {
			answer(action(open), null);
			return;
		}
		var client = app.workbenchClient, catalog = client == null ? null : client.terminalCatalog();
		var record = catalog == null ? null : Lambda.find(catalog.terminals, function(item) return item.id == id);
		if (record == null) {
			answer(null, new ControlError("not_found", "no terminal " + id + " in this window's workspace"));
			return;
		}
		app.terminalTabs.openCatalogTerminal(client, record);
		app.requestFrame();
		wait("terminal " + id + " to open", answer, function() {
			var pane = openTerminal(id);
			return pane == null ? null : action(pane);
		});
	}

	function openTerminal(id:String):Null<TerminalPane> {
		for (tab in app.host.allTerminalTabs())
			if (!tab.disposed && (tab.resourceId == id || tab.id == id)) return pane(tab);
		return null;
	}

	static function pane(tab:UiTerminalTab):Null<TerminalPane>
		return Std.isOfType(tab.panel, TerminalPane) ? cast tab.panel : null;

	function switchContext(key:Null<String>, answer:Answer):Void {
		var parsed = key == null ? null : workspace.ContextKey.parse(key);
		if (parsed == null) {
			answer(null, new ControlError("invalid_argument", "a context is machine/workspace/group"));
			return;
		}
		var active = app.application.activeContext;
		for (info in active.recent)
			if (info.key() == key) {
				app.contexts.switchToContext(info);
				answer({context: key}, null);
				return;
			}
		var entry = app.workbenchActions.workspaceById(parsed.workspace);
		if (entry == null) {
			answer(null, new ControlError("not_found", "exohost lists no workspace " + parsed.workspace));
			return;
		}
		if (parsed.group.length == 0)
			app.contexts.switchToContext(new workspace.ContextInfo(active.machineId, entry.id, "", entry.name, entry.name, ""));
		else
			app.workbenchActions.goTo(entry, function() app.contexts.focusGroupIfKnown(parsed.group));
		app.requestFrame();
		answer({context: key}, null);
	}

	/** A point to act on: an element (`element_id`, with `fx`, `fy`) or `x`, `y`; null after answering why not. */
	function target(params:Dynamic, answer:Answer):Null<{x:Float, y:Float}> {
		if (params == null) {
			answer(null, new ControlError("invalid_argument", "an element_id or x and y are needed"));
			return null;
		}
		var id = integer(params, "element_id");
		if (id != null) {
			var node = devtools.UiSnapshot.find(ui, id);
			if (node == null) {
				answer(null, new ControlError("not_found", "no visible element " + id));
				return null;
			}
			var bounds = node.globalBounds();
			return {x: bounds.x + bounds.width * fraction(params, "fx"), y: bounds.y + bounds.height * fraction(params, "fy")};
		}
		var x = number(params, "x"), y = number(params, "y");
		if (x == null || y == null) {
			answer(null, new ControlError("invalid_argument", "an element_id or x and y are needed"));
			return null;
		}
		return {x: x, y: y};
	}

	function wait(what:String, answer:Answer, ready:Void->Null<Dynamic>):Void
		waiting.push({ready: ready, until: Sys.time() + WAIT_SECONDS, answer: answer, what: what});

	function installCommands():Void
		CommandBridge.install(ui.commands, app.application.commands, app.application.keymap, app.application.context);

	function describeDocument(document:Document):Dynamic
		return {document_id: documentId(document), path: document.hasBackingPath() ? document.requirePath() : null, modified: document.dirty,
			saved: !document.dirty, title: document.title};

	function documentId(document:Document):String {
		var index = documents.indexOf(document);
		if (index < 0) {
			documents.push(document);
			index = documents.length - 1;
		}
		return "document:" + (index + 1);
	}

	function documentAt(path:String):Null<Document> {
		for (document in app.application.documents.documents)
			if (document.hasBackingPath() && workspace.PathKey.same(document.requirePath(), path)) return document;
		return null;
	}

	static function requirePath(params:Dynamic, answer:Answer):Null<String> {
		var path = text(params, "path", null);
		if (path == null || path.length == 0) {
			answer(null, new ControlError("invalid_argument", "a path is needed"));
			return null;
		}
		return path;
	}

	static function text(params:Dynamic, field:String, fallback:Null<String>):Null<String> {
		var value:Dynamic = params == null ? null : Reflect.field(params, field);
		return Std.isOfType(value, String) ? value : fallback;
	}

	static function number(params:Dynamic, field:String):Null<Float> {
		var value:Dynamic = params == null ? null : Reflect.field(params, field);
		return Std.isOfType(value, Float) || Std.isOfType(value, Int) ? (value : Float) : null;
	}

	static function integer(params:Dynamic, field:String):Null<Int> {
		var value = number(params, field);
		return value == null ? null : Std.int(value);
	}

	static function fraction(params:Dynamic, field:String):Float {
		var value = number(params, field);
		return value == null ? 0.5 : Math.max(0.0, Math.min(1.0, value));
	}

	static function clampCount(count:Null<Int>):Int
		return count == null || count < 1 ? 1 : count > 3 ? 3 : count;

	public function dispose():Void {
		if (focusSubscription != null) focusSubscription.dispose();
		input.dispose();
		for (item in waiting) item.answer(null, ControlError.internal("the window closed"));
		waiting.resize(0);
	}
}
