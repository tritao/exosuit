package controller;

import command.CommandContext;
import command.CommandRegistry;
import core.WorkbenchHost;
import editor.BufferPosition;
import editor.Document;
import language.LanguageServiceClient;
import process.ProcessManager;
import workspace.Workspace;

/** User-facing ownership and commands for the optional Haxeon language server. */
class LanguageController {

	public final available:Bool;
	public var client(get, never):Null<LanguageServiceClient>;
	final sessions:Map<String, FolderLanguageSession> = [];
	final suppressed:Map<String, Bool> = [];
	final failedRoots:Map<String, Bool> = [];
	var shuttingDown:Bool = false;

	final workspace:Workspace;
	final root:WorkbenchHost;
	final context:CommandContext;
	final commands:CommandRegistry;
	final processes:ProcessManager;
	final executable:String;
	final arguments:Array<String>;
	final settings:Null<Void->config.Settings>;
	final reportError:(String, String)->Void;
	final retiring:Array<FolderLanguageSession> = [];

	public function new(workspace:Workspace, root:WorkbenchHost, context:CommandContext, commands:CommandRegistry, processes:ProcessManager,
			executable:String, reportError:(String, String)->Void, ?arguments:Array<String>, available:Bool = true, ?settings:Void->config.Settings) {
		this.available = available && processes.available;
		this.settings = settings;
		this.workspace = workspace;
		this.root = root;
		this.context = context;
		this.commands = commands;
		this.processes = processes;
		this.executable = executable;
		this.arguments = arguments == null ? [] : arguments.copy();
		this.reportError = reportError;
		if (this.available) installCommands();
	}

	function projectFor(document:Null<Document>):Null<workspace.Project> {
		if (document == null || document.path == null) return null;
		var selected:Null<workspace.Project> = null;
		for (project in workspace.projects)
			if (StringTools.startsWith(document.path, StringTools.endsWith(project.root, "/") ? project.root : project.root + "/") &&
				(selected == null || project.root.length > selected.root.length)) selected = project;
		return selected;
	}

	function selectedProject():Null<workspace.Project> {
		var document = activeDocument();
		return document == null ? workspace.activeProject : projectFor(document);
	}

	function get_client():Null<LanguageServiceClient> {
		var project = selectedProject();
		var entry = project == null ? null : sessions.get(project.root);
		return entry == null ? null : entry.service;
	}

	public function sessionFor(path:String):Null<LanguageServiceClient> {
		var entry = sessions.get(path); return entry == null ? null : entry.service;
	}

	public function hasPendingWork():Bool {
		if (retiring.length > 0) return true;
		for (entry in sessions) if (entry.service.status != "disabled after repeated failures") return true;
		return false;
	}

	public function statusLabel():String {
		var service = client;
		return service == null ? "" : "Haxeon: " + service.status;
	}

	function configuration(project:workspace.Project):config.Settings {
		var local = project.settings;
		return local != null ? local.current : settings == null ? new config.Settings() : settings();
	}

	function commandFor(value:config.Settings):Array<String>
		return settings == null && value.haxeonCommand.length == 0 ? [executable].concat(arguments) : config.LanguageServerCommand.current(value);

	function configurationSignature(value:config.Settings):String {
		return haxe.Json.stringify({command: value.haxeonCommand, verbose: value.haxeonVerbose,
			environment: value.haxeonCommand.length == 0 ? Sys.getEnv("HAXEON_LSP") : "",
			compilerRoot: value.haxeonCommand.length == 0 ? Sys.getEnv("HAXEON_ROOT") : ""});
	}

	function launch(project:workspace.Project, value:config.Settings, command:Array<String>, now:Float):Bool {
		// A root has at most one owned process, even during explicit restart.
		var index = retiring.length;
		while (index > 0) {
			index--; var old = retiring[index];
			if (old.path == project.root) { old.service.shutdown(); retiring.splice(index, 1); }
		}
		var service = new LanguageServiceClient(processes, workspace.documents, command[0], command.slice(1), project.root);
		service.includesDocument = document -> { var owner = projectFor(document); return owner != null && owner.root == project.root; };
		service.verbose = value.haxeonVerbose;
		var entry = new FolderLanguageSession(project.root, service, configurationSignature(value));
		service.report = message -> {
			if (sessions.get(project.root) != entry) return;
			entry.failure = message;
			failedRoots.set(project.root, true);
			root.getProblems().removeOwner(entry.owner + ":status");
			var location = project.root + "/haxeon.json";
			for (document in workspace.documents.documents) { var owner = projectFor(document); if (owner != null && owner.root == project.root && document.path != null) { location = document.path; break; } }
			root.getProblems().add(new feedback.Problem(entry.owner + ":status", "server", location, 0, 0, 0, message, 1));
			reportError("language", project.name + ": " + message);
		};
		sessions.set(project.root, entry);
		return service.start(now);
	}

	public function start():Bool {
		if (!available) { reportError("language", "Language services are unavailable on this host"); return false; }
		var project = selectedProject();
		if (project == null) { reportError("language", "Open a workspace folder before starting Haxeon"); return false; }
		var value = configuration(project);
		if (!value.haxeonEnabled) { reportError("language", "Haxeon language services are disabled in settings"); return false; }
		suppressed.remove(project.root);
		var existing = sessions.get(project.root);
		if (existing != null && (existing.service.ready || existing.service.status == "initializing")) return true;
		if (existing != null) retire(existing, Sys.time());
		return launch(project, value, commandFor(value), Sys.time());
	}

	function retire(entry:FolderLanguageSession, now:Float):Void {
		sessions.remove(entry.path);
		entry.service.stop(now);
		if (entry.service.status != "stopped") retiring.push(entry);
		root.getPluginDecorations().removeOwner(entry.owner);
		root.getProblems().removeOwner(entry.owner);
		root.getProblems().removeOwner(entry.owner + ":status");
	}

	public function update(now:Float):Void {
		var index = retiring.length;
		while (index > 0) {
			index--; var previous = retiring[index]; previous.service.update(now);
			if (previous.service.status == "stopped") retiring.splice(index, 1);
		}
		if (!available || shuttingDown) return;
		var removed:Array<FolderLanguageSession> = [];
		for (entry in sessions) {
			var present = false;
			for (project in workspace.projects) if (project.root == entry.path) present = true;
			if (!present) removed.push(entry);
		}
		for (entry in removed) { retire(entry, now); suppressed.remove(entry.path); failedRoots.remove(entry.path); }
		var expired:Array<String> = [];
		for (path in suppressed.keys()) { var present = false; for (project in workspace.projects) if (project.root == path) present = true; if (!present) expired.push(path); }
		for (path in expired) suppressed.remove(path);
		for (project in workspace.projects) {
			var value = configuration(project), entry = sessions.get(project.root);
			var fingerprint = configurationSignature(value);
			var reconfigure = entry != null && entry.configuration != fingerprint;
			if (entry != null && (!value.haxeonEnabled || entry.configuration != fingerprint)) { retire(entry, now); entry = null; }
			if (!value.haxeonEnabled || suppressed.exists(project.root)) continue;
			if (entry == null && settings != null) {
				var needed = reconfigure;
				for (document in workspace.documents.documents)
					if (document.path != null && StringTools.endsWith(document.path.toLowerCase(), ".hx") && projectFor(document) == project) needed = true;
				if (needed) { launch(project, value, commandFor(value), now); entry = sessions.get(project.root); }
			}
			if (entry != null) {
				entry.service.update(now);
				if (entry.service.ready && failedRoots.remove(project.root)) root.getNotifications().publish("Haxeon ready: " + project.name);
				if (entry.service.ready && entry.failure.length > 0) { entry.failure = ""; root.getProblems().removeOwner(entry.owner + ":status"); }
				refreshDiagnostics(entry);
			}
		}
	}

	public function stop():Void {
		var project = selectedProject();
		if (project == null) return;
		suppressed.set(project.root, true);
		var entry = sessions.get(project.root);
		if (entry != null) retire(entry, Sys.time());
	}

	public function shutdown():Void {
		shuttingDown = true;
		var entries:Array<FolderLanguageSession> = [for (entry in sessions) entry];
		for (entry in entries) retire(entry, Sys.time());
		for (entry in retiring) entry.service.shutdown();
		retiring.resize(0); suppressed.clear(); failedRoots.clear();
	}

	function installCommands():Void {
		commands.add("language:haxeon-start", commandContext -> start());
		commands.add("language:haxeon-stop", commandContext -> stop(), commandContext -> client != null);
		commands.add("language:hover", commandContext -> hover(), commandContext -> supports("hover"));
		commands.add("language:complete", commandContext -> complete(), commandContext -> supports("completion"));
		commands.add("language:go-to-definition", commandContext -> definition(), commandContext -> supports("definition"));
		commands.add("language:signature-help", commandContext -> signatureHelp(), commandContext -> supports("signature"));
	}

	function hover():Void {
		var service = client, view = context.activeView(), document = activeDocument();
		if (service == null || view == null || document == null) return;
		service.requestHover(document, new BufferPosition(view.cursorLine(), view.cursorColumn()), Sys.time(), value -> {
			var area = root.textInputArea();
			if (value != null && area != null && context.activeView() == view && client == service) root.openLanguageInformation(area, value);
		});
	}

	function complete():Void {
		var service = client, view = context.activeView(), document = activeDocument();
		if (service == null || view == null || document == null) return;
		var position = new BufferPosition(view.cursorLine(), view.cursorColumn()), revision = document.buffer.stateId,
			from = wordStart(document, position);
		service.requestCompletion(document, position, Sys.time(), items -> {
			if (items.length == 0 || document.buffer.stateId != revision || context.activeView() != view) return;
			var area = root.textInputArea();
			if (area == null) return;
			root.openLanguageCompletion(area, items, function(item) {
				if (document.buffer.stateId == revision && context.activeView() == view && client == service) {
					view.replaceRange(from, position, item.insertText);
					view.cursorChanged();
				}
			});
		});
	}

	function definition():Void {
		var service = client, view = context.activeView(), document = activeDocument();
		if (service == null || view == null || document == null) return;
		service.requestDefinition(document, new BufferPosition(view.cursorLine(), view.cursorColumn()), Sys.time(), locations -> {
			if (locations.length == 0 || client != service || context.activeView() != view) return;
			var location = locations[0], target = root.openDocument(workspace.documents.open(location.path));
			target.restoreCursor(location.from.line, location.from.column);
			target.cursorChanged();
		});
	}

	function signatureHelp():Void {
		var service = client, view = context.activeView(), document = activeDocument();
		if (service == null || view == null || document == null) return;
		service.requestSignatureHelp(document, new BufferPosition(view.cursorLine(), view.cursorColumn()), Sys.time(), value -> {
			var area = root.textInputArea();
			if (value != null && area != null && context.activeView() == view && client == service) root.openLanguageSignature(area, value);
		});
	}

	function refreshDiagnostics(entry:FolderLanguageSession):Void {
		var service = entry.service, owner = entry.owner;
		var parts:Array<String> = [];
		for (document in workspace.documents.documents) {
			for (value in service.diagnosticsFor(document))
				parts.push('${document.id}:${value.from.line}:${value.from.column}:${value.to.line}:${value.to.column}:${value.severity}:${value.message}');
		}
		var fingerprint = parts.join("\n");
		if (fingerprint == entry.diagnostics) return;
		entry.diagnostics = fingerprint;
		var problems = root.getProblems(), decorations = root.getPluginDecorations(), theme = root.getTheme();
		decorations.removeOwner(owner);
		problems.removeOwner(owner);
		for (document in workspace.documents.documents) {
			var values = service.diagnosticsFor(document);
			for (index in 0...values.length) {
				var value = values[index];
				if (document.path != null) problems.add(new feedback.Problem(owner, document.id + ":" + index, document.path,
					value.from.line, value.from.column, value.to.column, value.message, value.severity));
				for (line in value.from.line...value.to.line + 1) {
					var from = line == value.from.line ? value.from.column : 0;
					var to = line == value.to.line ? value.to.column : document.buffer.line(line).length;
					if (to <= from) continue;
					decorations.add(owner, document.id + ":" + index + ":" + line, document, line, from, to,
						value.severity == 2 ? theme.diagnosticWarning : theme.diagnosticError,
						plugin.PluginDecorationKind.WavyUnderline);
				}
			}
		}
	}

	function supports(feature:String):Bool {
		var service = client;
		if (service == null || !service.ready || activeDocument() == null) return false;
		return feature == "hover" ? service.hoverSupported : feature == "completion" ? service.completionSupported
			: feature == "signature" ? service.signatureHelpSupported : service.definitionSupported;
	}

	function activeDocument():Null<Document> {
		var view = context.activeView();
		return view == null ? null : view.getDocument();
	}

	static function wordStart(document:Document, position:BufferPosition):BufferPosition {
		var result = document.buffer.positionAt(position.line, position.column);
		while (result.column > 0) {
			var previous = document.buffer.positionOffset(result, -1), code = document.buffer.characterCodeAt(previous);
			if (!(code >= 48 && code <= 57 || code >= 65 && code <= 90 || code >= 97 && code <= 122 || code == 95 || code >= 128)) break;
			result = previous;
		}
		return result;
	}
}

private class FolderLanguageSession {
	public final path:String;
	public final owner:String;
	public final service:LanguageServiceClient;
	public final configuration:String;
	public var diagnostics:String = "";
	public var failure:String = "";
	public function new(path:String, service:LanguageServiceClient, configuration:String) {
		this.path = path; this.service = service; this.configuration = configuration;
		owner = "language:haxeon:" + path;
	}
}
