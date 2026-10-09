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
	public static inline final INITIALIZE_REQUEST_TIMEOUT = 30.0;
	/** Editing a large project may queue analysis before an interactive reply. */
	public static inline final FEATURE_REQUEST_TIMEOUT = 30.0;
	public static inline final RESTART_DELAY = 0.25;
	public static inline final MAX_RESTARTS = 3;

	public final diagnostics:Map<String, Array<LanguageDiagnostic>> = [];
	public var ready(default, null):Bool = false;
	public var semanticTokensSupported(default, null):Bool = false;
	public var semanticTokensChanged:Void->Void = function() {};
	public var preferredDocument:Null<Document>;
	var semanticTypes:Array<String> = [];
	var semanticModifiers:Array<String> = [];
	static final TOKEN_TYPES = ["namespace", "type", "class", "enum", "interface", "struct", "typeParameter", "parameter", "variable", "property", "enumMember", "event", "function", "method", "macro", "keyword", "modifier", "comment", "string", "number", "regexp", "operator", "decorator"];
	static final TOKEN_MODIFIERS = ["declaration", "definition", "readonly", "static", "deprecated", "abstract", "async", "modification", "documentation", "defaultLibrary"];
	public var status(default, null):String = "stopped";
	public var hoverSupported(default, null):Bool = false;
	public var completionSupported(default, null):Bool = false;
	public var definitionSupported(default, null):Bool = false;
	public var signatureHelpSupported(default, null):Bool = false;
	public var symbolsSupported(default, null):Bool = false;
	public var referencesSupported(default, null):Bool = false;
	public var renameSupported(default, null):Bool = false;
	public var formattingSupported(default, null):Bool = false;
	public var rangeFormattingSupported(default, null):Bool = false;
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
	var clock:Float = 0;
	var readySince:Float = -1;
	var failureScheduled:Bool = false;
	public var includesDocument:Document->Bool;

	public function new(processes:ProcessManager, documents:DocumentManager, executable:String, arguments:Array<String>, rootPath:String) {
		this.processes = processes;
		this.documents = documents;
		this.executable = executable;
		this.arguments = arguments.copy();
		this.rootPath = rootPath;
		includesDocument = document -> document.path != null && StringTools.startsWith(document.path, StringTools.endsWith(rootPath, "/") ? rootPath : rootPath + "/");
	}

	public function start(now:Float):Bool {
		clock = now;
		if (transport != null) return true;
		stopping = false; failureScheduled = false; readySince = -1;
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
		session.failed = message -> scheduleRestart(clock, session.stderr.length == 0 ? message : message + ": " + session.stderr);
		status = "initializing";
		session.request("initialize", {
			processId: null,
			rootUri: uri(rootPath),
			capabilities: {
				general: {positionEncodings: ["utf-16"]},
				workspace: {semanticTokens: {refreshSupport: true}},
				textDocument: {semanticTokens: {
					requests: {full: true}, tokenTypes: TOKEN_TYPES, tokenModifiers: TOKEN_MODIFIERS,
					formats: ["relative"], overlappingTokenSupport: false, multilineTokenSupport: false
				}}
			},
			workspaceFolders: [{uri: uri(rootPath), name: fileName(rootPath)}]
		}, now, INITIALIZE_REQUEST_TIMEOUT, initialized);
		return true;
	}

	public function update(now:Float):Void {
		clock = now;
		if (ready && readySince >= 0 && now - readySince >= 30) restartCount = 0;
		var session = transport;
		if (session != null) {
			session.update(now);
			if (session.failure != null || status == "failed" || status == "disabled after repeated failures") retireSession();
		}
		if (transport == null && !stopping && restartAt >= 0 && now >= restartAt) start(now);
		if (ready) { synchronizeDocuments(); updateSemanticTokens(now); }
	}

	public function stop(now:Float):Void {
		if (stopping) return;
		clock = now;
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
			session.update(clock);
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
						var filter:Dynamic = Reflect.field(item, "filterText"), kind:Dynamic = Reflect.field(item, "kind");
						if (label != null) result.push(new CompletionItem(Std.string(label), detail == null ? "" : Std.string(detail), insert == null ? null : Std.string(insert), filter == null ? null : Std.string(filter), kind == null ? 0 : Std.int(kind), text(Reflect.field(item, "documentation"))));
					}
			}
			complete(result);
		});
	}

	public function requestDefinition(document:Document, position:BufferPosition, now:Float, complete:Array<LanguageLocation>->Void, ?failed:String->Void):Bool {
		if (!definitionSupported) return false;
		return requestAt("textDocument/definition", document, position, now, response -> {
			if (response.error != null && failed != null) failed(response.error);
			else complete(response.error == null ? locations(response.result) : []);
		});
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

	public function accepts(document:Document):Bool return eligible(document) && includesDocument(document);

	public function requestSymbols(document:Document, now:Float, complete:Array<LanguageSymbol>->Void):Bool {
		var state = states.get(document.id), session = transport, revision = document.buffer.stateId;
		if (!symbolsSupported || !ready || !accepts(document) || state == null || session == null) return false;
		session.request("textDocument/documentSymbol", {textDocument: {uri: state.uri}}, now, FEATURE_REQUEST_TIMEOUT, response -> {
			var result:Array<LanguageSymbol> = [];
			if (response.error == null && document.buffer.stateId == revision && transport == session && accepts(document))
				decodeSymbols(document, response.result, "", result);
			complete(result);
		});
		return true;
	}

	public function requestReferences(document:Document, position:BufferPosition, now:Float, complete:Array<LanguageLocation>->Void):Bool {
		var state = states.get(document.id), session = transport, revision = document.buffer.stateId;
		if (!referencesSupported || !ready || !accepts(document) || state == null || session == null) return false;
		session.request("textDocument/references", {textDocument: {uri: state.uri}, position: LspPositionCodec.encode(position), context: {includeDeclaration: true}},
			now, FEATURE_REQUEST_TIMEOUT, response -> complete(response.error == null && transport == session && document.buffer.stateId == revision && accepts(document)
				? locations(response.result) : []));
		return true;
	}

	public function requestRename(document:Document, position:BufferPosition, name:String, now:Float, complete:LanguageEditResult->Void):Bool {
		var state = states.get(document.id), session = transport;
		if (!renameSupported || !ready || !accepts(document) || state == null || session == null || name.length == 0) return false;
		var revision = document.buffer.stateId, captured = captureDocuments();
		session.request("textDocument/rename", {textDocument: {uri: state.uri}, position: LspPositionCodec.encode(position), newName: name},
			now, FEATURE_REQUEST_TIMEOUT, response -> {
			if (response.error != null) { complete(new LanguageEditResult(false, response.error)); return; }
			if (transport != session || !ready || !accepts(document) || documents.documents.indexOf(document) < 0 || document.buffer.stateId != revision) {
				complete(new LanguageEditResult(false, "Rename rejected: document or language session changed")); return;
			}
			complete(applyWorkspaceEdit(response.result, captured));
		});
		return true;
	}

	/** Explicit formatting only: edits are validated against the requesting buffer/session. */
	public function requestFormatting(document:Document, selection:BufferSelection, tabSize:Int, insertSpaces:Bool,
			ranged:Bool, now:Float, complete:LanguageEditResult->Void, ?stillActive:Void->Bool):Bool {
		var state = states.get(document.id), session = transport;
		if (!(ranged ? rangeFormattingSupported : formattingSupported) || !ready || !accepts(document)
				|| state == null || session == null || state.revision != document.buffer.stateId || tabSize <= 0) return false;
		var revision = document.buffer.stateId, path = document.path, ranges = selection.allRanges();
		var params:Dynamic = {textDocument: {uri: state.uri}, options: {tabSize: tabSize, insertSpaces: insertSpaces}};
		if (ranged) {
			if (ranges.length != 1 || !selection.hasSelection()) return false;
			Reflect.setField(params, "range", {start: LspPositionCodec.encode(selection.start()), end: LspPositionCodec.encode(selection.end())});
		}
		session.request(ranged ? "textDocument/rangeFormatting" : "textDocument/formatting", params, now, FEATURE_REQUEST_TIMEOUT, response -> {
			if (response.error != null) { complete(new LanguageEditResult(false, response.error)); return; }
			var current = selection.allRanges(), sameSelection = current.length == ranges.length;
			if (sameSelection) for (index in 0...ranges.length)
				if (!current[index].cursor.equals(ranges[index].cursor) || !current[index].anchor.equals(ranges[index].anchor)) sameSelection = false;
			if (transport != session || !ready || !accepts(document) || documents.documents.indexOf(document) < 0
					|| document.path != path || document.buffer.stateId != revision || !sameSelection || (stillActive != null && !stillActive())) {
				complete(new LanguageEditResult(false, "Formatting cancelled: document, selection or language session changed")); return;
			}
			if (response.result == null) { complete(new LanguageEditResult(true)); return; }
			if (!Std.isOfType(response.result, Array)) { complete(new LanguageEditResult(false, "Invalid formatting response")); return; }
			var replacements = parseWorkspaceEdits(document, cast response.result);
			if (replacements == null) { complete(new LanguageEditResult(false, "Formatting edit validation failed")); return; }
			if (replacements.length == 0) { complete(new LanguageEditResult(true)); return; }
			var applied = document.buffer.applyReplacements(selection, replacements);
			complete(new LanguageEditResult(applied, applied ? "" : "Could not apply formatting", applied ? [document] : []));
		});
		return true;
	}

	function decodeSymbols(document:Document, value:Dynamic, container:String, result:Array<LanguageSymbol>):Void {
		if (!Std.isOfType(value, Array)) return;
		for (item in cast(value, Array<Dynamic>)) {
			var name:Dynamic = Reflect.field(item, "name"), location:Dynamic = Reflect.field(item, "location"),
				range:Dynamic = location == null ? Reflect.field(item, "selectionRange") : Reflect.field(location, "range");
			if (range == null) range = Reflect.field(item, "range");
			var from = range == null ? null : LspPositionCodec.decode(document.buffer, Reflect.field(range, "start")),
				to = range == null ? null : LspPositionCodec.decode(document.buffer, Reflect.field(range, "end"));
			if (name != null && from != null && to != null && !to.before(from)) {
				var detail:Dynamic = Reflect.field(item, "detail");
				result.push(new LanguageSymbol(Std.string(name), container + (detail == null ? "" : Std.string(detail)),
					new LanguageLocation(document.requirePath(), from, to)));
				decodeSymbols(document, Reflect.field(item, "children"), container + Std.string(name) + " / ", result);
			}
		}
	}

	function captureDocuments():Map<String, LanguageRequestDocument> {
		var result:Map<String, LanguageRequestDocument> = [];
		for (document in documents.documents) if (accepts(document)) {
			var state = states.get(document.id);
			result.set(uri(document.requirePath()), new LanguageRequestDocument(document, state == null ? -1 : state.version));
		}
		return result;
	}

	function applyWorkspaceEdit(edit:Dynamic, captured:Map<String, LanguageRequestDocument>):LanguageEditResult {
		var changes:Dynamic = edit == null ? null : Reflect.field(edit, "documentChanges"),
			unversioned:Dynamic = edit == null ? null : Reflect.field(edit, "changes");
		var items:Array<Dynamic> = [];
		if (Std.isOfType(changes, Array)) items = cast changes;
		else if (unversioned != null) for (key in Reflect.fields(unversioned))
			items.push({textDocument: {uri: key, version: null}, edits: Reflect.field(unversioned, key)});
		else return new LanguageEditResult(false, "Workspace edit has no text changes");
		var plans:Array<LanguageDocumentEdit> = [], seen:Map<String, Bool> = [];
		for (item in items) {
			var target:Dynamic = Reflect.field(item, "textDocument"), rawUri:Dynamic = target == null ? null : Reflect.field(target, "uri"),
				rawEdits:Dynamic = Reflect.field(item, "edits"), version:Dynamic = target == null ? null : Reflect.field(target, "version");
			if (rawUri == null || !Std.isOfType(rawEdits, Array)) return new LanguageEditResult(false, "Unsupported or invalid workspace edit");
			var key = Std.string(rawUri);
			if (!StringTools.startsWith(key, "file://")) return new LanguageEditResult(false, "Invalid workspace edit target");
			var path:String;
			try path = documents.fileSystem.normalize(pathFromUri(key)) catch (error:Dynamic) return new LanguageEditResult(false, "Invalid workspace edit path: " + Std.string(error));
			if (seen.exists(path)) return new LanguageEditResult(false, "Duplicate workspace edit target");
			seen.set(path, true);
			var document = documentForPath(path), expected = captured.get(uri(path));
			if (expected != null) {
				if (document == null || document != expected.document || document.buffer.stateId != expected.revision || document.path != expected.path)
					return new LanguageEditResult(false, "Workspace edit rejected: document changed since request");
				if (version != null && integer(target, "version", -1) != expected.version)
					return new LanguageEditResult(false, "Workspace edit rejected: document version conflict");
			} else {
				if (document != null || version != null || !StringTools.startsWith(path, StringTools.endsWith(rootPath, "/") ? rootPath : rootPath + "/"))
					return new LanguageEditResult(false, "Workspace edit rejected: target was not captured by this session");
				try document = documents.open(path) catch (error:Dynamic) return new LanguageEditResult(false, "Could not open workspace edit target: " + Std.string(error));
			}
			if (document == null || !accepts(document)) return new LanguageEditResult(false, "Workspace edit target belongs to another folder or language");
			var replacements = parseWorkspaceEdits(document, cast rawEdits);
			if (replacements == null) return new LanguageEditResult(false, "Workspace edit validation failed");
			plans.push(new LanguageDocumentEdit(document, replacements));
		}
		// Validate every target before the first mutation. Each buffer supplies its
		// existing transactional replacement/undo behavior; files remain unsaved.
		for (plan in plans) if (plan.document.buffer.stateId != plan.revision)
			return new LanguageEditResult(false, "Workspace edit target changed during validation");
		var changed:Array<Document> = [];
		for (plan in plans) if (plan.replacements.length > 0) {
			if (plan.document.buffer.stateId != plan.revision || !plan.document.buffer.applyReplacements(new BufferSelection(), plan.replacements))
				return new LanguageEditResult(false, "Workspace edit target changed during application", changed);
			changed.push(plan.document);
		}
		return new LanguageEditResult(true, "", changed);
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
			if (range == null || !Std.isOfType(text, String)) return null;
			var from = LspPositionCodec.decode(document.buffer, Reflect.field(range, "start")),
				to = LspPositionCodec.decode(document.buffer, Reflect.field(range, "end"));
			if (from == null || to == null || to.before(from)) return null;
			replacements.push(new BufferReplacement(from, to, Std.string(text)));
		}
		replacements.sort((left, right) -> left.from.line == right.from.line ? left.from.column - right.from.column : left.from.line - right.from.line);
		for (index in 1...replacements.length)
			if (replacements[index].from.before(replacements[index - 1].to)) return null;
		return [for (replacement in replacements) if (document.buffer.textRange(replacement.from, replacement.to) != replacement.text) replacement];
	}

	function receiveServerRequest(method:String, params:Dynamic):JsonRpcResponse {
		if (method == "workspace/semanticTokens/refresh") {
			for (state in states) invalidateSemanticTokens(state);
			return new JsonRpcResponse(null);
		}
		if (method != "workspace/applyEdit") return new JsonRpcResponse(null, "Method not found");
		var result = applyWorkspaceEdit(params == null ? null : Reflect.field(params, "edit"), captureDocuments());
		return new JsonRpcResponse({applied: result.applied, failureReason: result.error});
	}

	/** Distinguish a published empty result from diagnostics that have not arrived yet. */
	public function hasReceivedDiagnostics(document:Document):Bool {
		var state = states.get(document.id);
		return state != null && diagnostics.exists(state.uri);
	}

	public function diagnosticsFor(document:Document):Array<LanguageDiagnostic> {
		var state = states.get(document.id);
		return state == null || !diagnostics.exists(state.uri) ? [] : diagnostics.get(state.uri);
	}

	public function restartAttempts():Int return restartCount;

	function initialized(response:JsonRpcResponse):Void {
		if (stopping) return;
		if (response.error != null || response.result == null) {
			scheduleRestart(clock, response.error == null ? "language server returned no initialize result" : response.error);
			return;
		}
		var capabilities:Dynamic = Reflect.field(response.result, "capabilities"), encoding:Dynamic = capabilities == null ? null : Reflect.field(capabilities, "positionEncoding");
		if (encoding != null && Std.string(encoding).toLowerCase() != "utf-16") {
			scheduleRestart(clock, "language server does not support UTF-16 positions");
			return;
		}
		ready = true;
		hoverSupported = capability(capabilities, "hoverProvider");
		completionSupported = capability(capabilities, "completionProvider");
		definitionSupported = capability(capabilities, "definitionProvider");
		signatureHelpSupported = capability(capabilities, "signatureHelpProvider");
		symbolsSupported = capability(capabilities, "documentSymbolProvider");
		referencesSupported = capability(capabilities, "referencesProvider");
		renameSupported = capability(capabilities, "renameProvider");
		formattingSupported = capability(capabilities, "documentFormattingProvider");
		rangeFormattingSupported = capability(capabilities, "documentRangeFormattingProvider");
		var semantic:Dynamic = capabilities == null ? null : Reflect.field(capabilities, "semanticTokensProvider");
		var legend:Dynamic = semantic == null ? null : Reflect.field(semantic, "legend");
		semanticTypes = stringArray(legend == null ? null : Reflect.field(legend, "tokenTypes"));
		semanticModifiers = stringArray(legend == null ? null : Reflect.field(legend, "tokenModifiers"));
		semanticTokensSupported = semanticTypes.length > 0 && capability(semantic, "full");
		status = "ready";
		readySince = clock;
		transport.notify("initialized", {});
		synchronizeDocuments();
	}

	function synchronizeDocuments():Void {
		var live:Map<Int, Bool> = [];
		for (document in documents.documents) {
			if (!accepts(document)) continue;
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
		state.semanticDue = clock + 0.15;
		state.subscription = document.buffer.subscribe(change -> changed(state, change));
		transport.notify("textDocument/didOpen", {textDocument: {uri: documentUri, languageId: "haxe", version: state.version, text: document.buffer.text}});
	}

	function changed(state:LanguageDocumentState, change:BufferChange):Void {
		if (!ready || states.get(state.document.id) != state) return;
		state.version++;
		state.revision = change.stateAfter;
		invalidateSemanticTokens(state);
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
		invalidateSemanticTokens(state);
		state.release();
		if (ready && transport != null) transport.notify("textDocument/didClose", {textDocument: {uri: state.uri}});
		diagnostics.remove(state.uri);
	}

	public function semanticTokensFor(document:Document):Null<LanguageSemanticSnapshot> {
		var state = states.get(document.id);
		return !ready || !accepts(document) || state == null || state.uri != uri(document.requirePath()) ||
			state.semanticSnapshot == null || state.semanticSnapshot.revision != document.buffer.stateId ? null : state.semanticSnapshot;
	}

	function invalidateSemanticTokens(state:LanguageDocumentState):Void {
		state.semanticEpoch++;
		var request = state.semanticRequest;
		state.semanticRequest = -1;
		state.semanticWanted = true;
		state.semanticDue = clock + 0.15;
		if (state.semanticSnapshot != null) { state.semanticSnapshot = null; semanticTokensChanged(); }
		if (request >= 0 && transport != null) transport.cancel(request);
	}

	function updateSemanticTokens(now:Float):Void {
		var session = transport;
		// Background coloring yields to interactive requests, with one request in flight.
		if (!semanticTokensSupported || session == null || session.pendingCount() > 0) return;
		var ordered:Array<LanguageDocumentState> = [];
		var preferred = preferredDocument == null ? null : states.get(preferredDocument.id);
		if (preferred != null) ordered.push(preferred);
		for (state in states) if (state != preferred) ordered.push(state);
		for (state in ordered) {
			if (!state.semanticWanted || state.semanticDue > now || state.revision != state.document.buffer.stateId) continue;
			state.semanticWanted = false;
			var revision = state.revision, epoch = state.semanticEpoch;
			state.semanticRequest = session.request("textDocument/semanticTokens/full", {textDocument: {uri: state.uri}}, now, FEATURE_REQUEST_TIMEOUT, response -> {
				if (transport != session || states.get(state.document.id) != state || state.semanticEpoch != epoch) return;
				state.semanticRequest = -1;
				if (!ready || !accepts(state.document) || uri(state.document.requirePath()) != state.uri || state.document.buffer.stateId != revision) return;
				if (response.error != null) return;
				var data:Dynamic = response.result == null ? new Array<Int>() : Reflect.field(response.result, "data");
				var tokens = SemanticTokenCodec.decode(state.document, data, semanticTypes, semanticModifiers);
				if (tokens == null) { if (verbose) log("Ignored malformed semantic tokens for " + state.uri); return; }
				state.semanticSnapshot = new LanguageSemanticSnapshot(state.document.id, revision, tokens);
				semanticTokensChanged();
			});
			return;
		}
	}

	static function stringArray(raw:Dynamic):Array<String> {
		if (!Std.isOfType(raw, Array)) return [];
		var result:Array<String> = [];
		for (value in cast(raw, Array<Dynamic>)) { if (!Std.isOfType(value, String)) return []; result.push(cast value); }
		return result;
	}

	function requestAt(method:String, document:Document, position:BufferPosition, now:Float, complete:JsonRpcResponse->Void):Bool {
		var state = states.get(document.id), session = transport;
		if (!ready || !accepts(document) || state == null || session == null || state.revision != document.buffer.stateId) return false;
		session.request(method, {textDocument: {uri: state.uri}, position: LspPositionCodec.encode(position)}, now, FEATURE_REQUEST_TIMEOUT, complete);
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
			var start:Dynamic = Reflect.field(range, "start"), end:Dynamic = Reflect.field(range, "end");
			var from = document == null ? new BufferPosition(integer(start, "line", -1), integer(start, "character", -1)) : LspPositionCodec.decode(document.buffer, start),
				to = document == null ? new BufferPosition(integer(end, "line", -1), integer(end, "character", -1)) : LspPositionCodec.decode(document.buffer, end);
			if (from != null && to != null && from.line >= 0 && from.column >= 0 && to.line >= 0 && to.column >= 0 && !to.before(from)) result.push(new LanguageLocation(path, from, to));
		}
		return result;
	}

	function scheduleRestart(now:Float, message:String):Void {
		if (stopping || failureScheduled) return;
		failureScheduled = true;
		ready = false;
		status = "failed";
		report("Language server: " + message);
		if (restartCount >= MAX_RESTARTS) {
			restartAt = -1;
			status = "disabled after repeated failures";
			return;
		}
		restartCount++;
		restartAt = now + RESTART_DELAY * Math.pow(2, restartCount - 1);
	}

	function retireSession():Void {
		ready = false;
		semanticTokensSupported = false; semanticTypes = []; semanticModifiers = [];
		semanticTokensChanged();
		hoverSupported = false;
		formattingSupported = false; rangeFormattingSupported = false;
		completionSupported = false;
		definitionSupported = false;
		signatureHelpSupported = false; symbolsSupported = false; referencesSupported = false; renameSupported = false;
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

private class LanguageRequestDocument {
	public final document:Document;
	public final revision:Int;
	public final path:String;
	public final version:Int;
	public function new(document:Document, version:Int) {
		this.document = document; this.revision = document.buffer.stateId;
		this.path = document.requirePath(); this.version = version;
	}
}

private class LanguageDocumentEdit {
	public final document:Document;
	public final revision:Int;
	public final replacements:Array<BufferReplacement>;
	public function new(document:Document, replacements:Array<BufferReplacement>) {
		this.document = document; this.revision = document.buffer.stateId; this.replacements = replacements;
	}
}
