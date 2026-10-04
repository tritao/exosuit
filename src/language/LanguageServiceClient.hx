package language;

import completion.CompletionItem;
import core.DocumentManager;
import editor.BufferChange;
import editor.BufferPosition;
import editor.BufferReplacement;
import editor.BufferSelection;
import editor.Document;
import process.OwnedProcess;
import process.ProcessManager;

/** One restartable LSP session, owning synchronization for backed Haxe documents. */
class LanguageServiceClient {
	public static inline final REQUEST_TIMEOUT = 5.0;
	public static inline final RESTART_DELAY = 0.25;
	public static inline final MAX_RESTARTS = 3;

	public final diagnostics:Map<String, Array<LanguageDiagnostic>> = [];
	public var ready(default, null):Bool = false;
	public var status(default, null):String = "stopped";
	public var hoverSupported(default, null):Bool = false;
	public var completionSupported(default, null):Bool = false;
	public var definitionSupported(default, null):Bool = false;
	public var signatureHelpSupported(default, null):Bool = false;
	public var verbose:Bool = false;
	public var log:String->Void = function(message) Sys.println(message);
	public var report:String->Void = function(message) {};

	final processes:ProcessManager;
	final documents:DocumentManager;
	final executable:String;
	final arguments:Array<String>;
	final rootPath:String;
	final states:Map<Int, LanguageDocumentState> = [];
	var process:Null<OwnedProcess>;
	var transport:Null<JsonRpcTransport>;
	var restartAt:Float = -1;
	var restartCount:Int = 0;
	var stopping:Bool = false;

	public function new(processes:ProcessManager, documents:DocumentManager, executable:String, arguments:Array<String>, rootPath:String) {
		this.processes = processes;
		this.documents = documents;
		this.executable = executable;
		this.arguments = arguments.copy();
		this.rootPath = rootPath;
	}

	public function start(now:Float):Bool {
		if (transport != null) return true;
		stopping = false;
		try {
			process = processes.start(executable, arguments, rootPath);
		} catch (error:Dynamic) {
			scheduleRestart(now, "could not start language server: " + Std.string(error));
			return false;
		}
		var session = new JsonRpcTransport(process);
		transport = session;
		if (verbose) session.trace = function(direction, payload) {
			log("Haxeon LSP " + direction + ": " + (payload.length > 2048 ? payload.substring(0, 2048) + " [truncated]" : payload));
		};
		session.notification = receiveNotification;
		session.serverRequest = receiveServerRequest;
		session.failed = message -> scheduleRestart(Sys.time(), session.stderr.length == 0 ? message : message + ": " + session.stderr);
		status = "initializing";
		session.request("initialize", {
			processId: null,
			rootUri: uri(rootPath),
			capabilities: {general: {positionEncodings: ["utf-16"]}},
			workspaceFolders: [{uri: uri(rootPath), name: fileName(rootPath)}]
		}, now, REQUEST_TIMEOUT, initialized);
		return true;
	}

	public function update(now:Float):Void {
		var session = transport;
		if (session != null) {
			session.update(now);
			if (session.failure != null) retireSession();
		}
		if (transport == null && !stopping && restartAt >= 0 && now >= restartAt) start(now);
		if (ready) synchronizeDocuments();
	}

	public function stop(now:Float):Void {
		if (stopping) return;
		stopping = true;
		ready = false;
		restartAt = -1;
		var session = transport;
		if (session == null) {
			retireSession();
			return;
		}
		status = "stopping";
		session.request("shutdown", null, now, 1.0, response -> {
			session.notify("exit", null);
			session.update(Sys.time());
			retireSession();
		});
	}

	/** Releases process and subscriptions immediately when the owning application exits. */
	public function shutdown():Void {
		stopping = true; ready = false; restartAt = -1;
		var session = transport;
		transport = null;
		if (session != null) session.close();
		retireSession();
	}

	public function requestHover(document:Document, position:BufferPosition, now:Float, complete:Null<String>->Void):Bool {
		if (!hoverSupported) return false;
		return requestAt("textDocument/hover", document, position, now, response -> {
			if (response.error != null || response.result == null) complete(null); else {
				var contents:Dynamic = Reflect.field(response.result, "contents"), value:Dynamic = contents == null ? null : Reflect.field(contents, "value");
				complete(value == null ? Std.string(contents) : Std.string(value));
			}
		});
	}

	public function requestCompletion(document:Document, position:BufferPosition, now:Float, complete:Array<CompletionItem>->Void):Bool {
		if (!completionSupported) return false;
		return requestAt("textDocument/completion", document, position, now, response -> {
			var result:Array<CompletionItem> = [];
			if (response.error == null && response.result != null) {
				var raw:Dynamic = Reflect.field(response.result, "items");
				if (raw == null) raw = response.result;
				if (Std.isOfType(raw, Array))
					for (item in cast(raw, Array<Dynamic>)) {
						var label:Dynamic = Reflect.field(item, "label"), detail:Dynamic = Reflect.field(item, "detail"), insert:Dynamic = Reflect.field(item, "insertText");
						if (label != null) result.push(new CompletionItem(Std.string(label), detail == null ? "" : Std.string(detail), insert == null ? null : Std.string(insert)));
					}
			}
			complete(result);
		});
	}

	public function requestDefinition(document:Document, position:BufferPosition, now:Float, complete:Array<LanguageLocation>->Void):Bool {
		if (!definitionSupported) return false;
		return requestAt("textDocument/definition", document, position, now, response -> complete(response.error == null ? locations(response.result) : []));
	}

	public function requestSignatureHelp(document:Document, position:BufferPosition, now:Float, complete:Null<SignatureHelp>->Void):Bool {
		if (!signatureHelpSupported) return false;
		return requestAt("textDocument/signatureHelp", document, position, now, response -> {
			if (response.error != null || response.result == null) { complete(null); return; }
			var signatures:Dynamic = Reflect.field(response.result, "signatures");
			if (!Std.isOfType(signatures, Array) || cast(signatures, Array<Dynamic>).length == 0) { complete(null); return; }
			var values:Array<Dynamic> = cast signatures, activeSignature = integer(response.result, "activeSignature", 0);
			if (activeSignature < 0 || activeSignature >= values.length) activeSignature = 0;
			var signature = values[activeSignature], label:Dynamic = Reflect.field(signature, "label"), documentation = text(Reflect.field(signature, "documentation"));
			if (label == null) { complete(null); return; }
			var parameter = "", parameters:Dynamic = Reflect.field(signature, "parameters"), activeParameter = integer(response.result, "activeParameter", integer(signature, "activeParameter", 0));
			if (Std.isOfType(parameters, Array)) {
				var list:Array<Dynamic> = cast parameters;
				if (activeParameter >= 0 && activeParameter < list.length) parameter = parameterLabel(Std.string(label), Reflect.field(list[activeParameter], "label"));
			}
			complete(new SignatureHelp(Std.string(label), documentation, parameter));
		});
	}

	public function applyWorkspaceEdits(document:Document, expectedRevision:Int, edits:Array<Dynamic>, selection:BufferSelection):Bool {
		if (document.buffer.stateId != expectedRevision) return false;
		var replacements = parseWorkspaceEdits(document, edits);
		return replacements != null && document.buffer.applyReplacements(selection, replacements);
	}

	function parseWorkspaceEdits(document:Document, edits:Array<Dynamic>):Null<Array<BufferReplacement>> {
		var replacements:Array<BufferReplacement> = [];
		for (edit in edits) {
			var range:Dynamic = Reflect.field(edit, "range"), text:Dynamic = Reflect.field(edit, "newText");
			if (range == null || text == null) return null;
			var from = LspPositionCodec.decode(document.buffer, Reflect.field(range, "start")),
				to = LspPositionCodec.decode(document.buffer, Reflect.field(range, "end"));
			if (from == null || to == null || to.before(from)) return null;
			replacements.push(new BufferReplacement(from, to, Std.string(text)));
		}
		return replacements;
	}

	function receiveServerRequest(method:String, params:Dynamic):JsonRpcResponse {
		if (method != "workspace/applyEdit") return new JsonRpcResponse(null, "Method not found");
		var edit:Dynamic = params == null ? null : Reflect.field(params, "edit"), changes:Dynamic = edit == null ? null : Reflect.field(edit, "documentChanges");
		if (!Std.isOfType(changes, Array)) return new JsonRpcResponse({applied: false, failureReason: "documentChanges is required"});
		var plans:Array<{document:Document, revision:Int, replacements:Array<BufferReplacement>}> = [];
		for (change in cast(changes, Array<Dynamic>)) {
			var textDocument:Dynamic = Reflect.field(change, "textDocument"), rawEdits:Dynamic = Reflect.field(change, "edits"), rawUri:Dynamic = textDocument == null ? null : Reflect.field(textDocument, "uri");
			if (rawUri == null || !Std.isOfType(rawEdits, Array)) return new JsonRpcResponse({applied: false, failureReason: "invalid text document edit"});
			var state = stateForUri(Std.string(rawUri)), version:Dynamic = Reflect.field(textDocument, "version");
			if (state == null || version != null && Std.parseInt(Std.string(version)) != state.version)
				return new JsonRpcResponse({applied: false, failureReason: "document version conflict"});
			var replacements = parseWorkspaceEdits(state.document, cast rawEdits);
			if (replacements == null) return new JsonRpcResponse({applied: false, failureReason: "workspace edit validation failed"});
			plans.push({document: state.document, revision: state.document.buffer.stateId, replacements: replacements});
		}
		for (plan in plans)
			if (plan.document.buffer.stateId != plan.revision || !plan.document.buffer.applyReplacements(new BufferSelection(), plan.replacements))
				return new JsonRpcResponse({applied: false, failureReason: "workspace edit validation failed"});
		return new JsonRpcResponse({applied: true});
	}

	public function diagnosticsFor(document:Document):Array<LanguageDiagnostic> {
		var state = states.get(document.id);
		return state == null || !diagnostics.exists(state.uri) ? [] : diagnostics.get(state.uri);
	}

	public function restartAttempts():Int return restartCount;

	function initialized(response:JsonRpcResponse):Void {
		if (stopping) return;
		if (response.error != null || response.result == null) {
			scheduleRestart(Sys.time(), response.error == null ? "language server returned no initialize result" : response.error);
			return;
		}
		var capabilities:Dynamic = Reflect.field(response.result, "capabilities"), encoding:Dynamic = capabilities == null ? null : Reflect.field(capabilities, "positionEncoding");
		if (encoding != null && Std.string(encoding).toLowerCase() != "utf-16") {
			scheduleRestart(Sys.time(), "language server does not support UTF-16 positions");
			return;
		}
		ready = true;
		hoverSupported = capability(capabilities, "hoverProvider");
		completionSupported = capability(capabilities, "completionProvider");
		definitionSupported = capability(capabilities, "definitionProvider");
		signatureHelpSupported = capability(capabilities, "signatureHelpProvider");
		status = "ready";
		restartCount = 0;
		transport.notify("initialized", {});
		synchronizeDocuments();
	}

	function synchronizeDocuments():Void {
		var live:Map<Int, Bool> = [];
		for (document in documents.documents) {
			if (!eligible(document)) continue;
			live.set(document.id, true);
			var documentUri = uri(document.requirePath()), state = states.get(document.id);
			if (state == null) openDocument(document, documentUri); else if (state.uri != documentUri) {
				closeState(state);
				openDocument(document, documentUri);
			}
		}
		var removed:Array<Int> = [];
		for (id in states.keys()) if (!live.exists(id)) removed.push(id);
		for (id in removed) {
			var state = states.get(id);
			closeState(state);
			states.remove(id);
		}
	}

	function openDocument(document:Document, documentUri:String):Void {
		var state = new LanguageDocumentState(document, documentUri);
		states.set(document.id, state);
		state.subscription = document.buffer.subscribe(change -> changed(state, change));
		transport.notify("textDocument/didOpen", {textDocument: {uri: documentUri, languageId: "haxe", version: state.version, text: document.buffer.text}});
	}

	function changed(state:LanguageDocumentState, change:BufferChange):Void {
		if (!ready || states.get(state.document.id) != state) return;
		state.version++;
		state.revision = change.stateAfter;
		var previous = diagnostics.get(state.uri);
		if (previous != null) {
			var moved:Array<LanguageDiagnostic> = [];
			for (diagnostic in previous) {
				var value = diagnostic.afterEdit(change);
				if (value != null) moved.push(value);
			}
			diagnostics.set(state.uri, moved);
		}
		transport.notify("textDocument/didChange", {
			textDocument: {uri: state.uri, version: state.version},
			contentChanges: [{range: {start: LspPositionCodec.encode(change.start), end: LspPositionCodec.encode(LspPositionCodec.advance(change.start, change.removed))}, rangeLength: change.removed.length, text: change.inserted}]
		});
	}

	function closeState(state:LanguageDocumentState):Void {
		state.release();
		if (ready && transport != null) transport.notify("textDocument/didClose", {textDocument: {uri: state.uri}});
		diagnostics.remove(state.uri);
	}

	function requestAt(method:String, document:Document, position:BufferPosition, now:Float, complete:JsonRpcResponse->Void):Bool {
		var state = states.get(document.id), session = transport;
		if (!ready || state == null || session == null || state.revision != document.buffer.stateId) return false;
		session.request(method, {textDocument: {uri: state.uri}, position: LspPositionCodec.encode(position)}, now, REQUEST_TIMEOUT, complete);
		return true;
	}

	function receiveNotification(method:String, params:Dynamic):Void {
		if (method == "textDocument/publishDiagnostics") publishDiagnostics(params);
		else if (method == "window/showMessage") {
			var message:Dynamic = params == null ? null : Reflect.field(params, "message");
			if (message != null) report("Language server: " + Std.string(message));
		}
	}

	function publishDiagnostics(params:Dynamic):Void {
		var rawUri:Dynamic = params == null ? null : Reflect.field(params, "uri"), rawItems:Dynamic = params == null ? null : Reflect.field(params, "diagnostics");
		if (rawUri == null || !Std.isOfType(rawItems, Array)) return;
		var documentUri = Std.string(rawUri), state = stateForUri(documentUri), rawVersion:Dynamic = Reflect.field(params, "version");
		if (state == null || rawVersion != null && Std.parseInt(Std.string(rawVersion)) != state.version) return;
		var values:Array<LanguageDiagnostic> = [];
		for (item in cast(rawItems, Array<Dynamic>)) {
			var range:Dynamic = Reflect.field(item, "range"), from = range == null ? null : LspPositionCodec.decode(state.document.buffer, Reflect.field(range, "start")),
				to = range == null ? null : LspPositionCodec.decode(state.document.buffer, Reflect.field(range, "end"));
			if (from == null || to == null) continue;
			var message:Dynamic = Reflect.field(item, "message"), severity:Dynamic = Reflect.field(item, "severity");
			values.push(new LanguageDiagnostic(from, to, message == null ? "Language service diagnostic" : Std.string(message), severity == null ? 1 : Std.parseInt(Std.string(severity))));
		}
		diagnostics.set(documentUri, values);
	}

	function locations(value:Dynamic):Array<LanguageLocation> {
		var result:Array<LanguageLocation> = [], values:Array<Dynamic> = value == null ? [] : Std.isOfType(value, Array) ? cast value : [value];
		for (location in values) {
			var rawUri:Dynamic = Reflect.field(location, "uri"), range:Dynamic = Reflect.field(location, "range");
			if (rawUri == null || range == null) continue;
			var path = pathFromUri(Std.string(rawUri)), document = documentForPath(path);
			if (document == null) continue;
			var from = LspPositionCodec.decode(document.buffer, Reflect.field(range, "start")), to = LspPositionCodec.decode(document.buffer, Reflect.field(range, "end"));
			if (from != null && to != null) result.push(new LanguageLocation(path, from, to));
		}
		return result;
	}

	function scheduleRestart(now:Float, message:String):Void {
		if (stopping) return;
		ready = false;
		status = "failed";
		report("Language server: " + message);
		if (restartCount >= MAX_RESTARTS) {
			restartAt = -1;
			status = "disabled after repeated failures";
			return;
		}
		restartCount++;
		restartAt = now + RESTART_DELAY;
	}

	function retireSession():Void {
		ready = false;
		hoverSupported = false;
		completionSupported = false;
		definitionSupported = false;
		signatureHelpSupported = false;
		for (state in states) state.release();
		states.clear();
		diagnostics.clear();
		var owned = process;
		process = null;
		transport = null;
		if (owned != null) processes.release(owned);
		if (stopping) status = "stopped";
	}

	function stateForUri(documentUri:String):Null<LanguageDocumentState> {
		for (state in states) if (state.uri == documentUri) return state;
		return null;
	}

	function documentForPath(path:String):Null<Document> {
		for (document in documents.documents) if (document.path == path) return document;
		return null;
	}

	static function eligible(document:Document):Bool
		return document.path != null && StringTools.endsWith(document.path.toLowerCase(), ".hx");

	static function uri(path:String):String
		return StringTools.startsWith(path, "file://") ? path : "file://" + path;

	static function pathFromUri(value:String):String
		return StringTools.startsWith(value, "file://") ? value.substring(7) : value;

	static function fileName(path:String):String {
		var slash = path.lastIndexOf("/");
		return slash < 0 ? path : path.substring(slash + 1);
	}

	static function capability(capabilities:Dynamic, name:String):Bool {
		if (capabilities == null) return false;
		var value:Dynamic = Reflect.field(capabilities, name);
		if (value == null) return false;
		// LSP capability values are either a boolean or an options object (e.g.
		// `"completionProvider": {}`); only explicit `false` means unsupported.
		// Comparing a non-boolean Dynamic against a Bool literal with `!=` can
		// throw ("Can't cast dynobj to bool") under Haxeon, so branch on the
		// runtime type instead of relying on that comparison.
		return !Std.isOfType(value, Bool) || cast(value, Bool);
	}

	static function integer(value:Dynamic, field:String, fallback:Int):Int {
		var raw:Dynamic = value == null ? null : Reflect.field(value, field);
		return raw == null ? fallback : Std.parseInt(Std.string(raw));
	}

	static function text(value:Dynamic):String {
		if (value == null) return "";
		var marked:Dynamic = Reflect.field(value, "value");
		return marked == null ? Std.string(value) : Std.string(marked);
	}

	static function parameterLabel(signature:String, value:Dynamic):String {
		if (value == null) return "";
		if (Std.isOfType(value, Array)) {
			var range:Array<Dynamic> = cast value;
			if (range.length == 2) {
				var from = Std.parseInt(Std.string(range[0])), to = Std.parseInt(Std.string(range[1]));
				if (from >= 0 && to >= from && to <= signature.length) return signature.substring(from, to);
			}
			return "";
		}
		return Std.string(value);
	}
}
