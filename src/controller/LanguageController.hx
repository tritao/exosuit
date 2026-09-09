package controller;

import command.CommandContext;
import command.CommandRegistry;
import editor.BufferPosition;
import editor.Document;
import language.LanguageServiceClient;
import process.ProcessManager;
import view.RootView;
import workspace.Workspace;

/** User-facing ownership and commands for the optional Haxeon language server. */
class LanguageController {
	static inline final OWNER = "language:haxeon";

	public var client(default, null):Null<LanguageServiceClient>;

	final workspace:Workspace;
	final root:RootView;
	final context:CommandContext;
	final commands:CommandRegistry;
	final processes:ProcessManager;
	final executable:String;
	final arguments:Array<String>;
	final reportError:(String, String)->Void;
	var diagnosticFingerprint:String = "";

	public function new(workspace:Workspace, root:RootView, context:CommandContext, commands:CommandRegistry, processes:ProcessManager,
			executable:String, reportError:(String, String)->Void, ?arguments:Array<String>) {
		this.workspace = workspace;
		this.root = root;
		this.context = context;
		this.commands = commands;
		this.processes = processes;
		this.executable = executable;
		this.arguments = arguments == null ? [] : arguments.copy();
		this.reportError = reportError;
		installCommands();
	}

	public function start():Bool {
		if (client != null) return true;
		var project = workspace.activeProject;
		if (project == null) {
			reportError("language", "Open a project before starting the Haxeon language server");
			return false;
		}
		var service = new LanguageServiceClient(processes, workspace.documents, executable, arguments, project.root);
		service.report = message -> reportError("language", message);
		client = service;
		return service.start(Sys.time());
	}

	public function update(now:Float):Void {
		var service = client;
		if (service == null) return;
		service.update(now);
		refreshDiagnostics(service);
	}

	public function stop():Void {
		var service = client;
		if (service == null) return;
		service.stop(Sys.time());
		client = null;
		diagnosticFingerprint = "";
		root.pluginDecorations.removeOwner(OWNER);
		root.problems.removeOwner(OWNER);
	}

	public function shutdown():Void
		stop();

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
			if (value != null && area != null && context.activeView() == view) root.languagePopup.openInformation(area, value);
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
			root.languagePopup.openCompletion(area, items, function(item) {
				if (document.buffer.stateId == revision && context.activeView() == view) {
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
			if (locations.length == 0) return;
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
			if (value != null && area != null && context.activeView() == view) root.languagePopup.openSignature(area, value);
		});
	}

	function refreshDiagnostics(service:LanguageServiceClient):Void {
		var parts:Array<String> = [];
		for (document in workspace.documents.documents) {
			for (value in service.diagnosticsFor(document))
				parts.push('${document.id}:${value.from.line}:${value.from.column}:${value.to.line}:${value.to.column}:${value.message}');
		}
		var fingerprint = parts.join("\n");
		if (fingerprint == diagnosticFingerprint) return;
		diagnosticFingerprint = fingerprint;
		root.pluginDecorations.removeOwner(OWNER);
		root.problems.removeOwner(OWNER);
		for (document in workspace.documents.documents) {
			var values = service.diagnosticsFor(document);
			for (index in 0...values.length) {
				var value = values[index];
				if (document.path != null) root.problems.add(new feedback.Problem(OWNER, document.id + ":" + index, document.path,
					value.from.line, value.from.column, value.to.column, value.message, value.severity));
				if (value.from.line != value.to.line || value.to.column <= value.from.column) continue;
				root.pluginDecorations.add(OWNER, document.id + ":" + index, document, value.from.line, value.from.column, value.to.column,
					root.theme.error);
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
