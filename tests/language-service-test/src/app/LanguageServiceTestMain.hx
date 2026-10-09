package app;

import completion.CompletionItem;
import core.DocumentManager;
import editor.BufferPosition;
import editor.BufferSelection;
import language.LanguageLocation;
import language.LanguageDiagnostic;
import editor.BufferChange;
import language.LanguageServiceClient;
import language.SignatureHelp;
import language.LanguageSymbol;
import language.LanguageEditResult;
import platform.Platform;
import process.ProcessManager;
import syntax.BuiltinSyntax;
import syntax.SyntaxRegistry;
import sys.io.File;

class LanguageServiceTestMain {
	static function require(condition:Bool, message:String):Void {
		if (!condition) throw message;
	}

	static function pump(client:LanguageServiceClient, condition:Void->Bool, timeout:Float):Void {
		var deadline = Sys.time() + timeout;
		while (!condition() && Sys.time() < deadline) client.update(Sys.time());
		require(condition(), "language service condition timed out: " + client.status);
	}

	static function completionResult(value:Null<Array<CompletionItem>>):Array<CompletionItem> {
		if (value == null) throw "completion response missing";
		return value;
	}

	static function definitionResult(value:Null<Array<LanguageLocation>>):Array<LanguageLocation> {
		if (value == null) throw "definition response missing";
		return value;
	}

	static function semanticColors(server:String, project:String):Void {
		var registry = new SyntaxRegistry(); BuiltinSyntax.install(registry);
		var documents = new DocumentManager(registry), path = project + "/Semantic.hx";
		File.saveContent(path, "😀 value\n");
		var document = documents.open(path), manager = new ProcessManager();
		var client = new LanguageServiceClient(manager, documents, "python3", [server, "--semantic"], project);
		client.start(Sys.time());
		pump(client, () -> client.semanticTokensFor(document) != null, 5.0);
		var snapshot = client.semanticTokensFor(document);
		require(snapshot != null && snapshot.tokens.length == 1 && snapshot.tokens[0].start == 2 && snapshot.tokens[0].end == 7 &&
			snapshot.tokens[0].type == "function" && snapshot.tokens[0].modifiers[0] == "readonly", "semantic legend or UTF-16 conversion failed");
		var theme = new style.Theme();
		var foreground = editor.SemanticPresentation.foreground(document, theme, snapshot, 0, document.buffer.document.codepointCount);
		require([for (range in foreground) if (range.start == 2 && range.end == 7 && range.color == theme.semanticColor("function", [])) range].length == 1,
			"semantic function color did not override syntax");
		for (index in 1...foreground.length) require(foreground[index].start >= foreground[index - 1].end, "foreground ranges overlap");
		var other = new editor.Document(null, "😀 value\n", registry);
		var otherColors = editor.SemanticPresentation.foreground(other, theme, snapshot, 0, other.buffer.document.codepointCount);
		require([for (range in otherColors) if (range.color == theme.semanticColor("function", [])) range].length == 0, "another document inherited semantic colors");
		var original = snapshot;
		document.insert(new BufferSelection(new BufferPosition(0, 2)), "x");
		require(client.semanticTokensFor(document) == null, "edit retained semantic snapshot");
		var fallback = editor.SemanticPresentation.foreground(document, theme, original, 0, document.buffer.document.codepointCount);
		require([for (range in fallback) if (range.color == theme.semanticColor("function", [])) range].length == 0, "stale semantic colors survived edit");
		pump(client, () -> { var state:Null<language.LanguageDocumentState> = @:privateAccess client.states.get(document.id); return state != null && state.semanticRequest >= 0; }, 5.0);
		document.insert(new BufferSelection(new BufferPosition(0, 2)), "y");
		require(client.semanticTokensFor(document) == null, "pending edit retained colors");
		pump(client, () -> client.semanticTokensFor(document) != null, 5.0);
		snapshot = client.semanticTokensFor(document);
		require(snapshot != null && snapshot.revision == document.buffer.stateId && snapshot.tokens[0].start == 4,
			"cancelled semantic reply replaced newer tokens");
		var types = ["function"], modifiers = ["readonly"];
		for (data in [[0, 0, 1, 0, 0], [0, 1, 1, 0, 0], [0, 99, 1, 0, 0], [0, 5, 99, 0, 0], [0, 5, 1, 9, 0],
			[0, 5, 2, 0, 0, 0, 1, 2, 0, 0], [0, 5, 1, 0], [0, 5, 1, 0, 2]])
			require(language.SemanticTokenCodec.decode(document, data, types, modifiers) == null, "malformed semantic tokens were accepted");
		var collision = new editor.Document(project + "/Color.hx", "String", registry);
		var semanticOverride = new language.LanguageSemanticSnapshot(collision.id, collision.buffer.stateId,
			[new language.LanguageSemanticToken(1, 4, "function", [])]);
		var merged = editor.SemanticPresentation.foreground(collision, theme, semanticOverride, 0, 6);
		require(merged.length == 3 && merged[0].start == 0 && merged[0].end == 1 && merged[1].start == 1 && merged[1].end == 4 &&
			merged[1].color == theme.semanticColor("function", []) && merged[2].start == 4 && merged[2].end == 6, "semantic override lost surrounding syntax");
		var clipped = editor.SemanticPresentation.foreground(collision, theme, semanticOverride, 2, 3);
		require(clipped.length == 1 && clipped[0].start == 2 && clipped[0].end == 3, "semantic ranges escaped requested viewport");
		var future = new language.LanguageSemanticSnapshot(collision.id, collision.buffer.stateId,
			[new language.LanguageSemanticToken(0, 6, "futureEntity", [])]);
		var preserved = editor.SemanticPresentation.foreground(collision, theme, future, 0, 6);
		require(preserved.length == 1 && preserved[0].color == theme.tokenColor(syntax.HighlightToken.TYPE), "unknown semantic category removed syntax fallback");
		var before = snapshot;
		@:privateAccess client.receiveServerRequest("workspace/semanticTokens/refresh", null);
		require(client.semanticTokensFor(document) == null, "refresh retained old snapshot");
		pump(client, () -> client.semanticTokensFor(document) != null, 5.0);
		require(client.semanticTokensFor(document) != before, "refresh did not request new tokens");
		client.stop(Sys.time());
		require(client.semanticTokensFor(document) == null, "stopped server retained colors");
		pump(client, () -> client.status == "stopped", 5.0);
		manager.shutdown();
		Sys.println("PASS: semantic colors, Unicode, stale/cancelled replies, refresh, malformed tokens and syntax fallback");
	}

	static function main():Int {

		var arguments = Sys.args();
		require(arguments.length == 2, "language service test requires fake server and project paths");
		semanticColors(arguments[0], arguments[1]);
		var sourcePath = arguments[1] + "/Main.hx";
		File.saveContent(sourcePath, "😀 value\n");
		File.saveContent(arguments[1] + "/Other.hx", "old\n");
		var syntaxes = new SyntaxRegistry();
		BuiltinSyntax.install(syntaxes);
		var documents = new DocumentManager(syntaxes), document = documents.open(sourcePath), manager = new ProcessManager(),
			client = new LanguageServiceClient(manager, documents, "python3", [arguments[0]], arguments[1]);
		client.start(Sys.time());
		pump(client, () -> client.ready, 5.0);

		var selection = new BufferSelection(new BufferPosition(0, 2));
		document.insert(selection, "x");
		pump(client, () -> client.diagnosticsFor(document).length == 1, 5.0);
		var diagnostic = client.diagnosticsFor(document)[0];
		require(diagnostic.message == "current 😀" && diagnostic.to.column == 2, "stale or incorrectly positioned diagnostics were accepted");

		var anchored = new LanguageDiagnostic(new BufferPosition(0, 3), new BufferPosition(0, 8), "pending", 1);
		var moved = anchored.afterEdit(new BufferChange(new BufferPosition(0, 0), "", "é🙂\n", 0, 1, 0, 1));
		require(moved != null && moved.from.equals(new BufferPosition(1, 3)) && moved.to.equals(new BufferPosition(1, 8)),
			"pending diagnostic did not move through a Unicode multiline insertion");
		require(anchored.afterEdit(new BufferChange(new BufferPosition(0, 3), "value", "", 0, 0, 0, 1)) == null,
			"deleted diagnostic range did not clear");
		var hover:Null<String> = null, completions:Null<Array<CompletionItem>> = null, definitions:Null<Array<LanguageLocation>> = null,
			signature:Null<SignatureHelp> = null;
		require(client.requestHover(document, new BufferPosition(0, 2), Sys.time(), value -> hover = value), "hover request was rejected");
		require(client.requestCompletion(document, new BufferPosition(0, 2), Sys.time(), value -> completions = value), "completion request was rejected");
		require(client.requestDefinition(document, new BufferPosition(0, 2), Sys.time(), value -> definitions = value), "definition request was rejected");
		require(client.requestSignatureHelp(document, new BufferPosition(0, 2), Sys.time(), value -> signature = value), "signature-help request was rejected");
		pump(client, () -> hover != null && completions != null && definitions != null && signature != null, 5.0);
		require(hover == "hover 😀", "hover response was not decoded");
		pump(client, () -> document.buffer.line(0) == "😀serverx value", 5.0);
		var completed = completionResult(completions), located = definitionResult(definitions);
		require(completed.length == 1 && completed[0].insertText == "completion", "completion response was not decoded");
		require(completed[0].filterText == "completion", "completion filterText was not decoded");
		require(completed[0].kind == 3 && completed[0].documentation == "Completion documentation",
			"completion kind or markup documentation was lost");
		var duplicate = new CompletionItem("same", "same");
		require(duplicate.displayDetail() == "" && duplicate.kindLabel() == "", "unspecified completion metadata should be unobtrusive");
		var ranked = [new CompletionItem("alphaSecond", "", "second", "alpha"), new CompletionItem("alphaFirst")];
		var narrowed = CompletionItem.matching(ranked, "AL");
		require(narrowed.length == 2 && narrowed[0] == ranked[0] && narrowed[1] == ranked[1],
			"completion filtering changed provider ranking or item identity");
		require(located.length == 1 && located[0].path == sourcePath && located[0].from.column == 2,
			"definition response did not retain its UTF-16 location");
		require(signature != null && signature.activeParameter == "right:Int" && signature.documentation == "Adds values",
			"signature help did not decode its active parameter or documentation");

		var revision = document.buffer.stateId, edit:Dynamic = {
			range: {start: {line: 0, character: 8}, end: {line: 0, character: 9}},
			newText: "ok"
		};
		require(!client.applyWorkspaceEdits(document, revision - 1, [edit], selection), "stale workspace edit was applied");
		require(client.applyWorkspaceEdits(document, revision, [edit], selection) && document.buffer.line(0) == "😀serverok value",
			"workspace edit was not applied transactionally");
		document.undo(selection);
		require(document.buffer.line(0) == "😀serverx value", "workspace edit was not one undo transaction");

		var formatted:Null<LanguageEditResult> = null;
		require(client.formattingSupported && client.rangeFormattingSupported, "formatting capabilities missing");
		var beforeFormat = document.buffer.text;
		require(client.requestFormatting(document, selection, 3, true, false, Sys.time(), value -> formatted = value), "formatting request rejected");
		pump(client, () -> formatted != null, 5);
		require(formatted != null && formatted.applied && document.buffer.text == "   " + beforeFormat, "document formatting or options failed");
		document.undo(selection);
		require(document.buffer.text == beforeFormat, "formatting was not one undo transaction");
		selection.restore(document.buffer, new BufferPosition(0, 2), new BufferPosition(0, 0));
		formatted = null;
		require(client.requestFormatting(document, selection, 3, true, true, Sys.time(), value -> formatted = value), "range formatting request rejected");
		pump(client, () -> formatted != null, 5);
		require(formatted != null && formatted.applied && document.buffer.text == "   " + beforeFormat.substring(2), "UTF-16 formatting range incorrect");
		document.undo(selection);
		for (moveOnly in [false, true]) {
			selection.setCursor(document.buffer, new BufferPosition(0, 0));
			formatted = null;
			require(client.requestFormatting(document, selection, 3, true, false, Sys.time(), value -> formatted = value), "stale formatting request rejected early");
			selection.setCursor(document.buffer, document.buffer.endPosition());
			if (!moveOnly) document.insert(selection, "pending");
			pump(client, () -> formatted != null, 5);
			require(formatted != null && !formatted.applied && !StringTools.startsWith(document.buffer.text, "   "), "stale formatting overwrote typing or cursor movement");
			if (!moveOnly) document.undo(selection);
			else selection.setCursor(document.buffer, new BufferPosition(0, 0));
		}
		Sys.println("PASS: document/range formatting, settings, UTF-16, undo and stale replies");

		var symbols:Null<Array<LanguageSymbol>> = null, references:Null<Array<LanguageLocation>> = null;
		require(client.requestSymbols(document, Sys.time(), value -> symbols = value), "symbols request was rejected");
		require(client.requestReferences(document, new BufferPosition(0, 2), Sys.time(), value -> references = value), "references request was rejected");
		pump(client, () -> symbols != null && references != null, 5);
		require(symbols != null && symbols.length == 2 && symbols[1].name == "value" && symbols[1].detail == "Main / Int", "nested document symbols were not decoded");
		require(references != null && references.length == 2 && references[1].path == arguments[1] + "/Other.hx", "references omitted unopened document");
		var renamed:Null<LanguageEditResult> = null;
		require(client.requestRename(document, new BufferPosition(0, 2), "multi", Sys.time(), value -> renamed = value), "rename request rejected");
		pump(client, () -> renamed != null, 5);
		require(renamed != null && renamed.applied && renamed.documents.length == 2, "multi-document rename failed");
		var other = documents.open(arguments[1] + "/Other.hx");
		require(document.buffer.line(0) == "😀multiserverx value" && other.buffer.line(0) == "otherld" && other.dirty,
			"rename did not edit managed unsaved buffers");
		document.undo(selection); other.undo(new BufferSelection());
		require(document.buffer.line(0) == "😀serverx value" && other.buffer.line(0) == "old", "rename was not one undo transaction per document");
		renamed = null;
		require(client.requestRename(document, new BufferPosition(0, 2), "stale", Sys.time(), value -> renamed = value), "stale rename request rejected before response");
		selection.setCursor(document.buffer, document.buffer.endPosition()); document.insert(selection, "pending");
		pump(client, () -> renamed != null, 5);
		require(renamed != null && !renamed.applied && document.buffer.text.indexOf("stale") < 0 && document.buffer.text.indexOf("pending") >= 0,
			"delayed rename overwrote newer typing");
		document.undo(selection);
		for (name in ["overlap", "version-conflict"]) {
			renamed = null;
			require(client.requestRename(document, new BufferPosition(0, 2), name, Sys.time(), value -> renamed = value), "invalid rename request was not sent");
			pump(client, () -> renamed != null, 5);
			require(renamed != null && !renamed.applied && document.buffer.line(0) == "😀serverx value" && other.buffer.line(0) == "old",
				"invalid rename batch partially applied: " + name);
		}
		Sys.println("PASS: symbols, unopened references, multi-file rename, per-document undo, delayed rename and invalid-batch rejection");

		for (uri in client.diagnostics.keys()) client.diagnostics.set(uri, [anchored]);
		document.buffer.replaceRange(selection, new BufferPosition(0, 0), new BufferPosition(0, 0), "x");
		var pending = client.diagnosticsFor(document);
		require(pending.length == 1 && pending[0].from.column == 4 && pending[0].to.column == 9,
			"live diagnostics did not follow an edit before server publication");
		document.undo(selection);
		pending = client.diagnosticsFor(document);
		require(pending.length == 1 && pending[0].from.column == 3 && pending[0].to.column == 8,
			"live diagnostic range did not follow undo");
		selection.setCursor(document.buffer, document.buffer.endPosition());
		document.insert(selection, "CRASH");
		pump(client, () -> !client.ready, 5.0);
		pump(client, () -> client.ready, 5.0);
		client.stop(Sys.time());
		pump(client, () -> client.status == "stopped", 5.0);
		var minimal = new LanguageServiceClient(manager, documents, "python3", [arguments[0], "minimal"], arguments[1]);
		minimal.start(Sys.time());
		pump(minimal, () -> minimal.ready, 5.0);
		require(!minimal.semanticTokensSupported && !minimal.formattingSupported && !minimal.rangeFormattingSupported && !minimal.hoverSupported && !minimal.completionSupported && !minimal.definitionSupported && !minimal.signatureHelpSupported && !minimal.symbolsSupported && !minimal.referencesSupported && !minimal.renameSupported,
			"unsupported server capabilities were advertised by the client");
		require(!minimal.requestFormatting(document, selection, 3, true, false, Sys.time(), value -> {}), "unsupported formatting request was sent");
		require(!minimal.requestHover(document, new BufferPosition(0, 0), Sys.time(), value -> {}),
			"unsupported hover request was sent");
		require(!minimal.requestSymbols(document, Sys.time(), value -> {}) &&
			!minimal.requestReferences(document, new BufferPosition(0, 0), Sys.time(), value -> {}) &&
			!minimal.requestRename(document, new BufferPosition(0, 0), "newName", Sys.time(), value -> {}), "unsupported language requests were sent");

		minimal.stop(Sys.time());
		pump(minimal, () -> minimal.status == "stopped", 5.0);
		var cold = new LanguageServiceClient(manager, documents, "python3", [arguments[0], "--slow-initialize"], arguments[1]);
		cold.start(Sys.time());
		pump(cold, () -> cold.ready, 8.0);
		require(cold.ready, "cold initialization used the short shutdown timeout");
		cold.stop(Sys.time());
		pump(cold, () -> cold.status == "stopped", 5.0);
		Sys.println("PASS: cold initialization has its own timeout and still shuts down promptly");
		var slow = new LanguageServiceClient(manager, documents, "python3", [arguments[0], "--slow-completion"], arguments[1]);
		slow.start(Sys.time());
		pump(slow, () -> slow.ready, 5.0);
		var delayed:Null<Array<CompletionItem>> = null;
		require(slow.requestCompletion(document, new BufferPosition(0, 0), Sys.time(), value -> delayed = value), "slow completion request unavailable");
		pump(slow, () -> delayed != null, 10.0);
		require(completionResult(delayed).length == 1, "interactive completion expired at the lifecycle deadline");
		slow.stop(Sys.time());
		pump(slow, () -> slow.status == "stopped", 5.0);
		manager.shutdown();

		Sys.println("PASS: LSP lifecycle, synchronization, stale diagnostics, requests, edits, and restart");
		return 0;
	}
}
