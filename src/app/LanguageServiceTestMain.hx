package app;

import completion.CompletionItem;
import core.DocumentManager;
import editor.BufferPosition;
import editor.BufferSelection;
import language.LanguageLocation;
import language.LanguageServiceClient;
import language.SignatureHelp;
import platform.Native;
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
		Platform.startHeadless();
		var arguments = Sys.args();
		require(arguments.length == 2, "language service test requires fake server and project paths");
		var sourcePath = arguments[1] + "/Main.hx";
		File.saveContent(sourcePath, "😀 value\n");
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

		selection.setCursor(document.buffer, document.buffer.endPosition());
		document.insert(selection, "CRASH");
		pump(client, () -> !client.ready, 5.0);
		pump(client, () -> client.ready, 5.0);
		client.stop(Sys.time());
		pump(client, () -> client.status == "stopped", 5.0);
		var minimal = new LanguageServiceClient(manager, documents, "python3", [arguments[0], "minimal"], arguments[1]);
		minimal.start(Sys.time());
		pump(minimal, () -> minimal.ready, 5.0);
		require(!minimal.hoverSupported && !minimal.completionSupported && !minimal.definitionSupported && !minimal.signatureHelpSupported,
			"unsupported server capabilities were advertised by the client");
		require(!minimal.requestHover(document, new BufferPosition(0, 0), Sys.time(), value -> {}),
			"unsupported hover request was sent");
		minimal.stop(Sys.time());
		pump(minimal, () -> minimal.status == "stopped", 5.0);
		manager.shutdown();
		Native.shutdown();
		Sys.println("PASS: LSP lifecycle, synchronization, stale diagnostics, requests, edits, and restart");
		return 0;
	}
}
