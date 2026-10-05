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

	static function main():Int {

		var arguments = Sys.args();
		require(arguments.length == 2, "language service test requires fake server and project paths");
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
		require(!minimal.hoverSupported && !minimal.completionSupported && !minimal.definitionSupported && !minimal.signatureHelpSupported && !minimal.symbolsSupported && !minimal.referencesSupported && !minimal.renameSupported,
			"unsupported server capabilities were advertised by the client");
		require(!minimal.requestHover(document, new BufferPosition(0, 0), Sys.time(), value -> {}),
			"unsupported hover request was sent");
		require(!minimal.requestSymbols(document, Sys.time(), value -> {}) &&
			!minimal.requestReferences(document, new BufferPosition(0, 0), Sys.time(), value -> {}) &&
			!minimal.requestRename(document, new BufferPosition(0, 0), "newName", Sys.time(), value -> {}), "unsupported language requests were sent");

		minimal.stop(Sys.time());
		pump(minimal, () -> minimal.status == "stopped", 5.0);
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
