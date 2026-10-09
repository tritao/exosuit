package app;

import command.CommandContext;
import command.CommandRegistry;
import controller.LanguageController;
import core.FocusManager;
import editor.BufferPosition;
import platform.Platform;
import process.ProcessManager;
import testing.model.ModelTextMetrics;
import style.Theme;
import syntax.BuiltinSyntax;
import syntax.SyntaxRegistry;
import sys.io.File;
import testing.model.ModelWorkbenchHost;
import workspace.Workspace;

class LanguageControllerTestMain {
	static function require(condition:Bool, message:String):Void {
		if (!condition) throw message;
	}

	static function pump(controller:LanguageController, condition:Void->Bool, timeout:Float):Void {
		var deadline = Sys.time() + timeout;
		while (!condition() && Sys.time() < deadline) controller.update(Sys.time());
		require(condition(), "language controller condition timed out");
	}

	static function folderLifecycle(workspace:Workspace, root:ModelWorkbenchHost, context:CommandContext, processes:ProcessManager, fake:String, directory:String):Void {
		var log = directory + "/server-events.jsonl";
		File.saveContent(log, "");
		var value = new config.Settings(); value.haxeonCommand = ["python3", fake, "--events", log];
		var errors:Array<String> = [];
		var controller = new LanguageController(workspace, root, context, new CommandRegistry(), processes, "python3",
			(source, message) -> errors.push(message), [fake], true, () -> value);
		pump(controller, () -> { var service = controller.sessionFor(directory); return service != null && service.ready; }, 5);
		var parent = controller.sessionFor(directory);
		if (parent == null) throw "parent session missing";
		for (_ in 0...20) controller.update(Sys.time());
		require(processes.activeCount() == 1 && initializedCount(log, directory) == 1, "automatic opening duplicated server");
		var nested = directory + "/nested"; sys.FileSystem.createDirectory(nested);
		File.saveContent(nested + "/Child.hx", "class Child {}\n");
		var project = workspace.addProject(nested), child = workspace.documents.open(nested + "/Child.hx");
		root.openDocument(child);
		pump(controller, () -> { var service = controller.sessionFor(nested); return service != null && service.ready; }, 5);
		var settingsPath = nested + "/server-settings.json";
		var layer = new config.Preferences(null, settingsPath); project.setSettings(layer);
		layer.store.set("languages/haxeon/command", haxeon.ui.properties.PropertyValue.Text(haxe.Json.stringify(["python3", fake, "--events", log, "--profile", "nested"])));
		var originalChild = controller.sessionFor(nested);
		pump(controller, () -> { var service = controller.sessionFor(nested); return service != null && service != originalChild && service.ready; }, 5);
		require(controller.sessionFor(directory) == parent && processes.activeCount() == 2, "folder settings restarted unrelated root");
		var childService = controller.sessionFor(nested);
		if (childService == null) throw "child session missing";
		require(controller.client == childService && processes.activeCount() == 2, "document was routed to wrong root");
		workspace.addProject(directory); // Changing active folder must not change document ownership.
		controller.update(Sys.time());
		require(controller.client == childService && controller.sessionFor(directory) == parent, "active-folder switch restarted or rerouted sessions");
		for (document in workspace.documents.documents.copy()) workspace.documents.close(document, true);
		controller.update(Sys.time());
		require(controller.sessionFor(directory) == parent && controller.sessionFor(nested) == childService, "last-document closure tore down session");
		layer.store.set("languages/haxeon/command", haxeon.ui.properties.PropertyValue.Text(haxe.Json.stringify(["python3", fake, "--events", log, "--profile", "warm"])));
		pump(controller, () -> { var service = controller.sessionFor(nested); return service != null && service != childService && service.ready; }, 5);
		require(controller.sessionFor(directory) == parent && processes.activeCount() == 2, "warm-session configuration change affected unrelated root");
		workspace.removeProject(project);
		pump(controller, () -> processes.activeCount() == 1, 2);
		require(controller.sessionFor(directory) == parent && controller.sessionFor(nested) == null, "folder removal affected unrelated server");
		var main = workspace.documents.open(directory + "/Controller.hx"); root.openDocument(main);
		controller.stop(); pump(controller, () -> processes.activeCount() == 0, 2);
		for (_ in 0...20) controller.update(Sys.time());
		require(controller.sessionFor(directory) == null, "automatic mode ignored explicit Stop");
		require(controller.start(), "explicit Start did not clear suppression");
		pump(controller, () -> { var service = controller.client; return service != null && service.ready; }, 5);
		var pid = latestPid(log, directory);
		require(Sys.command("kill", ["-KILL", Std.string(pid)]) == 0, "could not externally kill server");
		pump(controller, () -> errors.length > 0, 2);
		require(root.getProblems().values().length > 0 && controller.statusLabel().indexOf("failed") >= 0, "crash was not visible");
		pump(controller, () -> { var service = controller.client; return service != null && service.ready && latestPid(log, directory) != pid; }, 5);
		require(processes.activeCount() == 1, "restart leaked or duplicated server");
		value.haxeonCommand = [directory + "/missing-server"];
		pump(controller, () -> root.getProblems().values().length > 0, 3);
		require(controller.statusLabel().indexOf("failed") >= 0, "wrong command was not visible");
		value.haxeonCommand = ["python3", fake, "--events", log];
		pump(controller, () -> { var service = controller.client; return service != null && service.ready; }, 5);
		require(root.getProblems().values().length == 0, "recovered server retained failure problem");
		value.haxeonCommand = ["python3", fake, "--events", log, "bad-encoding"];
		var beforeErrors = errors.length;
		pump(controller, () -> errors.length > beforeErrors && processes.activeCount() == 0, 3);
		var invalid = controller.client;
		if (invalid == null) throw "invalid initialization session missing";
		require(invalid.restartAttempts() == 1, "one failed initialization scheduled duplicate retries");
		value.haxeonCommand = ["python3", fake, "--events", log];
		pump(controller, () -> { var service = controller.client; return service != null && service.ready; }, 5);
		value.haxeonEnabled = false; pump(controller, () -> processes.activeCount() == 0, 2);
		value.haxeonEnabled = true;
		pump(controller, () -> { var service = controller.client; return service != null && service.ready; }, 5);
		controller.shutdown(); require(processes.activeCount() == 0, "multi-root shutdown retained a process");
		Sys.println("PASS: lazy per-folder servers, nested routing, retained sessions, explicit Stop, external crash and configuration recovery");
	}

	static function initializedCount(path:String, root:String):Int {
		var count = 0;
		for (line in File.getContent(path).split("\n")) if (line.length > 0) {
			var event:Dynamic = haxe.Json.parse(line);
			if (Reflect.field(event, "root") == "file://" + root && Reflect.field(event, "method") == "initialize") count++;
		}
		return count;
	}
	static function latestPid(path:String, root:String):Int {
		var pid = 0;
		for (line in File.getContent(path).split("\n")) if (line.length > 0) {
			var event:Dynamic = haxe.Json.parse(line);
			if (Reflect.field(event, "root") == "file://" + root && Reflect.field(event, "method") == "initialize") pid = Std.parseInt(Std.string(Reflect.field(event, "pid")));
		}
		return pid;
	}

	static function main():Int {

		var arguments = Sys.args(), sourcePath = arguments[1] + "/Controller.hx";
		File.saveContent(sourcePath, "😀 value\n");
		File.saveContent(arguments[1] + "/Other.hx", "old\n");
		var syntaxes = new SyntaxRegistry();
		BuiltinSyntax.install(syntaxes);
		var workspace = new Workspace(syntaxes);
		workspace.addProject(arguments[1]);
		var serverSettings = new config.Settings();
		serverSettings.haxeonCommand = ["python3", arguments[0], "--initialize-delay", "--definition-delay"];
		serverSettings.haxeonVerbose = true;
		var document = workspace.documents.open(sourcePath), focus = new FocusManager(),
			metrics = new ModelTextMetrics( "ignored-headlessly.ttf", 15), root = new ModelWorkbenchHost(metrics, new Theme(), focus, workspace, 640, 320),
			view = root.openDocument(document), commands = new CommandRegistry(), context = new CommandContext(root, focus, workspace.documents),
			processes = new ProcessManager(), failures:Array<String> = [], controller = new LanguageController(workspace, root, context, commands, processes,
				"python3", (source, message) -> failures.push(source + ":" + message), [arguments[0]], true, () -> serverSettings);
		var protocol:Array<String> = [];
		serverSettings.haxeonEnabled = false;
		require(!controller.start() && processes.activeCount() == 0, "disabled service launched a process");
		failures.resize(0); serverSettings.haxeonEnabled = true;
		require(commands.perform("language:haxeon-start", context), "language start command was not installed");
		var started = controller.client;
		if (started == null) throw "controller failed to create configured client";
		started.log = message -> protocol.push(message);
		require(commands.perform("language:go-to-definition", context), "early definition unavailable");
		pump(controller, () -> controller.statusLabel().indexOf("Initializing") >= 0, 5);
		pump(controller, () -> controller.lastDefinitionTiming != null && controller.lastDefinitionTiming.outcome == "completed", 5);
		require(controller.lastDefinitionTiming.readinessMs >= 200 && controller.lastDefinitionTiming.totalMs >= 400, "cold navigation timing missing");
		require(controller.statusLabel().indexOf("definition") < 0, "completed definition left progress active");
		require(protocol.length > 0 && protocol[0].indexOf("Haxeon LSP") == 0, "verbose protocol was not logged");
		var selection = view.getSelection();
		require(selection != null, "document view has no selection");
		selection.setCursor(document.buffer, new BufferPosition(0, 5));
		commands.perform("language:go-to-definition", context);
		pump(controller, () -> controller.statusLabel().indexOf("Finding definition") >= 0, 5);
		selection.setCursor(document.buffer, new BufferPosition(0, 0));
		controller.update(Sys.time());
		require(controller.lastDefinitionTiming.outcome == "cancelled" && !root.commandView.active, "cursor movement did not cancel navigation");
		commands.perform("language:go-to-definition", context);
		pump(controller, () -> controller.lastDefinitionTiming.outcome == "completed", 5);
		require(!root.commandView.active, "cancelled response opened a stale definition picker");
		// Repeating F12 supersedes the previous request; changing tabs cancels the newest one.
		selection.setCursor(document.buffer, new BufferPosition(0, 5));
		commands.perform("language:go-to-definition", context);
		commands.perform("language:go-to-definition", context);
		root.openDocument(workspace.documents.open(arguments[1] + "/Other.hx"));
		controller.update(Sys.time());
		require(controller.lastDefinitionTiming.outcome == "cancelled", "tab change did not cancel navigation");
		root.openDocument(document);
		selection.setCursor(document.buffer, new BufferPosition(0, 0));
		var freshPath = arguments[1] + "/Fresh.hx";
		File.saveContent(freshPath, "class Fresh {}\n");
		root.openDocument(workspace.documents.open(freshPath));
		var beforeFresh = controller.lastDefinitionTiming;
		commands.perform("language:go-to-definition", context);
		pump(controller, () -> controller.lastDefinitionTiming != beforeFresh && controller.lastDefinitionTiming.outcome == "completed", 5);
		root.openDocument(document);
		Sys.println("PASS: cold and unsynchronized F12 retention, progress, timings, repeated requests and cursor/tab cancellation");
		var formattingSettings = new config.Settings(); formattingSettings.indentSize = 3; formattingSettings.insertSpaces = true;
		controller.documentSettings = target -> formattingSettings;
		var unformatted = document.buffer.text;
		require(commands.perform("language:format-document", context), "format document command unavailable");
		pump(controller, () -> document.buffer.text != unformatted, 5);
		require(document.buffer.text == "   " + unformatted, "format command ignored resolved document settings");
		document.undo(selection);
		require(!commands.perform("language:format-selection", context), "format selection enabled without selection");
		selection.restore(document.buffer, new BufferPosition(0, 2), new BufferPosition(0, 0));
		require(commands.perform("language:format-selection", context), "format selection command unavailable");
		pump(controller, () -> document.buffer.text != unformatted, 5);
		require(document.buffer.text == "   " + unformatted.substring(2), "format selection did not use selected UTF-16 range");
		document.undo(selection);
		Sys.println("PASS: formatting commands use resolved settings and selection ranges");

		selection.setCursor(document.buffer, new BufferPosition(0, 2));
		document.insert(selection, "x");
		pump(controller, () -> root.pluginDecorations.forDocument(document).length == 1 && root.problems.values().length == 1, 5.0);
		require(root.pluginDecorations.forDocument(document)[0].kind == plugin.PluginDecorationKind.WavyUnderline,
			"language diagnostic did not request a wavy underline");
		require(commands.perform("language:hover", context), "hover command was not available");
		pump(controller, () -> root.languagePopup.visible, 5.0);
		require(root.languagePopup.visible, "hover was not surfaced through an anchored popup");
		root.languagePopup.close();
		selection.setCursor(document.buffer, new BufferPosition(0, 0));
		require(commands.perform("language:complete", context), "completion command was not available");
		pump(controller, () -> root.languagePopup.visible, 5.0);
		require(root.languagePopup.visible && root.languagePopup.keyPressed(Platform.KEY_ESCAPE, 0),
			"completion was not surfaced through an interactive anchored popup");
		require(commands.perform("language:signature-help", context), "signature-help command was not available");
		pump(controller, () -> root.languagePopup.visible, 5.0);
		require(root.languagePopup.visible && root.languagePopup.keyPressed(Platform.KEY_ESCAPE, 0),
			"signature help was not surfaced through an anchored popup");
		require(commands.perform("language:go-to-definition", context), "definition command was not available");
		for (_ in 0...32) controller.update(Sys.time());
		selection.setCursor(document.buffer, new BufferPosition(0, 5));
		require(commands.perform("language:go-to-definition", context), "multiple definition command unavailable");
		pump(controller, () -> root.commandView.active, 5);
		require(root.commandView.results.length == 2, "definitions did not open a picker");
		root.commandView.setQuery("Other.hx"); root.commandView.keyPressed(Platform.KEY_ENTER, 0);
		require(context.requireDocument().path == arguments[1] + "/Other.hx", "definition picker did not open selected file");
		require(context.activeView().cursorColumn() == 1, "definition picker missed target cursor");
		require(commands.perform("navigation:go-back", context), "Go Back unavailable after definition");
		require(context.requireDocument() == document && view.cursorColumn() == 5, "Go Back lost source cursor");
		require(commands.perform("navigation:go-forward", context), "Go Forward unavailable after Go Back");
		require(context.requireDocument().path == arguments[1] + "/Other.hx", "Go Forward lost destination");
		commands.perform("navigation:go-back", context);
		for (column in [6, 7]) {
			selection.setCursor(document.buffer, new BufferPosition(0, column));
			var notifications = root.notifications.entries.length;
			commands.perform("language:go-to-definition", context);
			pump(controller, () -> root.notifications.entries.length > notifications, 5);
			var message = root.notifications.entries[root.notifications.entries.length - 1].message;
			require(message.indexOf(column == 6 ? "No definition found" : "still being analysed") >= 0, "definition failure was silent");
		}
		selection.setCursor(document.buffer, new BufferPosition(0, 5));
		commands.perform("language:go-to-definition", context);
		pump(controller, () -> root.commandView.active, 5);
		selection.setCursor(document.buffer, new BufferPosition(0, 0));
		root.commandView.setQuery("Other.hx"); root.commandView.keyPressed(Platform.KEY_ENTER, 0);
		require(context.requireDocument() == document, "stale definition picker navigated after caret changed");
		Sys.println("PASS: definition picker, back/forward history, missing/error feedback and stale result guard");
		require(commands.perform("language:document-symbols", context), "symbols command unavailable");
		pump(controller, () -> root.commandView.active, 5);
		root.commandView.setQuery("value");
		require(root.commandView.results.length == 1 && root.commandView.results[0].label == "value", "symbol picker did not filter");
		root.commandView.keyPressed(Platform.KEY_ENTER, 0);
		require(!root.commandView.active && view.getSelection().hasSelection(), "symbol picker did not navigate");
		require(commands.perform("language:find-references", context), "references command unavailable");
		pump(controller, () -> root.commandView.active, 5);
		require(root.commandView.results.length == 2 && root.commandView.selected == 0, "references picker lost closed-file result");
		root.commandView.setQuery("Other.hx"); root.commandView.keyPressed(Platform.KEY_ENTER, 0);
		require(context.requireDocument().path == arguments[1] + "/Other.hx", "references picker did not open selected file");
		root.openDocument(document);
		require(commands.perform("language:rename-symbol", context), "rename command unavailable");
		root.commandView.setQuery("renamed"); root.commandView.keyPressed(Platform.KEY_ENTER, 0);
		pump(controller, () -> document.buffer.text.indexOf("renamed") >= 0, 5);
		document.undo(view.getSelection());
		Sys.println("PASS: searchable symbols, reference navigation to closed files and rename prompt");

		controller.stop();
		pump(controller, () -> processes.activeCount() == 0, 2.0);
		require(controller.start(), "service did not restart after graceful stop");
		controller.shutdown();
		require(processes.activeCount() == 0, "shutdown retained language process");
		require(root.pluginDecorations.forDocument(document).length == 0,
			"stopped language service left diagnostic decorations behind");
		folderLifecycle(workspace, root, context, processes, arguments[0], arguments[1]);
		processes.shutdown();

		require(failures.length == 0, "language controller reported unexpected errors");
		Sys.println("PASS: language commands, hover, completion, definition, and diagnostic decorations");
		return 0;
	}
}
