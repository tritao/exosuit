package app;

import core.DocumentManager;
import editor.BufferSelection;
import language.LanguageServiceClient;
import language.LanguageLocation;
import language.LanguageSymbol;
import language.LanguageEditResult;
import completion.CompletionItem;
import editor.BufferPosition;
import platform.Platform;
import process.ProcessManager;
import syntax.BuiltinSyntax;
import syntax.SyntaxRegistry;
import sys.io.File;

class RealLanguageServiceSmokeMain {
	static function require(condition:Bool, message:String):Void {
		if (!condition) throw message;
	}

	static function pump(client:LanguageServiceClient, condition:Void->Bool, timeout:Float):Void {
		var deadline = Sys.time() + timeout;
		while (!condition() && Sys.time() < deadline) client.update(Sys.time());
		if (!condition()) { client.shutdown(); throw "real Haxeon language service condition timed out: " + client.status; }
	}

	/** Exercise repository source through unsaved overlays; never write the checkout. */
	static function repositorySmoke(server:String, project:String):Int {
		var syntaxes = new SyntaxRegistry(); BuiltinSyntax.install(syntaxes);
		var documents = new DocumentManager(syntaxes), document = documents.open(project + "/src/config/ApplicationPaths.hx"),
			processes = new ProcessManager(), client = new LanguageServiceClient(processes, documents, server, [], project), selection = new BufferSelection();
		var original = document.buffer.text;
		client.report = message -> Sys.println(message); client.start(Sys.time());
		pump(client, () -> client.ready, 30);
		document.buffer.replaceAllText(StringTools.replace(original, 'var slash = path.lastIndexOf("/")', 'var slash:Int = "wrong"'), selection);
		pump(client, () -> client.diagnosticsFor(document).length > 0, 30);
		document.buffer.replaceAllText(original, selection);
		pump(client, () -> client.diagnosticsFor(document).length == 0, 30);
		var use = original.indexOf("slash >"), declaration = document.buffer.positionFromOffset(original.indexOf("slash =")),
			position = document.buffer.positionFromOffset(use + 2);
		var completions:Null<Array<CompletionItem>> = null, definitions:Null<Array<LanguageLocation>> = null,
			references:Null<Array<LanguageLocation>> = null, symbols:Null<Array<LanguageSymbol>> = null;
		require(client.requestCompletion(document, position, Sys.time(), value -> completions = value), "repository completion unavailable");
		require(client.requestDefinition(document, position, Sys.time(), value -> definitions = value), "repository definition unavailable");
		require(client.requestReferences(document, position, Sys.time(), value -> references = value), "repository references unavailable");
		require(client.requestSymbols(document, Sys.time(), value -> symbols = value), "repository symbols unavailable");
		pump(client, () -> completions != null && definitions != null && references != null && symbols != null, 30);
		var found = false; if (completions != null) for (item in completions) if (item.label == "slash") found = true;
		require(found && definitions != null && definitions.length > 0 && definitions[0].from.equals(declaration) &&
			references != null && references.length >= 2 && symbols != null && symbols.length > 0, "repository language navigation failed");
		var renamed:Null<LanguageEditResult> = null;
		require(client.requestRename(document, position, "folderSeparator", Sys.time(), value -> renamed = value), "repository rename unavailable");
		pump(client, () -> renamed != null, 30);
		require(renamed != null && renamed.applied && renamed.documents.length == 1 &&
			document.buffer.text.indexOf("var folderSeparator =") >= 0 && document.buffer.text.indexOf("separator = folderSeparator >") >= 0, "repository local rename failed");
		document.undo(selection);
		require(document.buffer.text == original && File.getContent(document.requirePath()) == original, "repository smoke changed checkout content");
		client.stop(Sys.time()); pump(client, () -> client.status == "stopped", 5);
		processes.shutdown();
		Sys.println("PASS: real repository diagnostics/fix, completion, symbols, definition, references and local rename through unsaved overlays");
		return 0;
	}

	static function main():Int {

		var arguments = Sys.args();
		if (arguments.length > 2) return repositorySmoke(arguments[0], arguments[1]);
		var project = arguments[1], source = project + "/Main.hx";
		File.saveContent(source, "function main():Int return 1;\n");
		var syntaxes = new SyntaxRegistry();
		BuiltinSyntax.install(syntaxes);
		var documents = new DocumentManager(syntaxes), document = documents.open(source), processes = new ProcessManager(),
			client = new LanguageServiceClient(processes, documents, arguments[0], [], project), selection = new BufferSelection();
		client.report = message -> Sys.println(message);
		client.start(Sys.time());
		pump(client, () -> client.ready, 30.0);
		document.buffer.replaceAllText('function main():Int return "wrong";\n', selection);
		pump(client, () -> client.diagnosticsFor(document).length > 0, 30.0);
		document.buffer.replaceAllText("function main():Int return 42;\n", selection);
		pump(client, () -> client.diagnosticsFor(document).length == 0, 30.0);
		var sourceText = "function main():Int { var answer = 42; return answer; }\n";
		document.buffer.replaceAllText(sourceText, selection);
		client.update(Sys.time());
		var use = sourceText.lastIndexOf("answer"), definitionOffset = sourceText.indexOf("answer");
		var completions:Null<Array<CompletionItem>> = null, definitions:Null<Array<LanguageLocation>> = null,
			references:Null<Array<LanguageLocation>> = null, symbols:Null<Array<LanguageSymbol>> = null;
		require(client.requestCompletion(document, new BufferPosition(0, use + 3), Sys.time(), value -> completions = value), "real completion unavailable");
		require(client.requestDefinition(document, new BufferPosition(0, use + 1), Sys.time(), value -> definitions = value), "real definition unavailable");
		require(client.requestReferences(document, new BufferPosition(0, use + 1), Sys.time(), value -> references = value), "real references unavailable");
		require(client.requestSymbols(document, Sys.time(), value -> symbols = value), "real symbols unavailable");
		pump(client, () -> completions != null && definitions != null && references != null && symbols != null, 30);
		var foundCompletion = false;
		if (completions != null) for (item in completions) if (item.label == "answer") foundCompletion = true;
		require(foundCompletion, "real completion omitted local symbol");
		require(definitions != null && definitions.length > 0 && definitions[0].from.column == definitionOffset, "real definition did not resolve local declaration");
		pump(client, () -> client.lastServerRequestTiming != null, 5);
		require(client.initializationMs >= 0 && client.lastServerRequestTiming.queueMs >= 0 && client.lastServerRequestTiming.analysisMs >= 0,
			"real navigation omitted startup/queue/analysis timing");
		Sys.println("Definition timing: " + haxe.Json.stringify(client.lastServerRequestTiming));
		require(references != null && references.length >= 2, "real references omitted local usage/declaration");
		require(symbols != null && symbols.length > 0 && symbols[0].name == "main", "real symbols omitted entry function");
		var renamed:Null<LanguageEditResult> = null;
		require(client.requestRename(document, new BufferPosition(0, use + 1), "result", Sys.time(), value -> renamed = value), "real rename unavailable");
		pump(client, () -> renamed != null, 30);
		require(renamed != null && renamed.applied && document.buffer.text.indexOf("answer") < 0 && document.buffer.text.indexOf("var result = 42") >= 0 &&
			document.buffer.text.indexOf("return result") >= 0, "real rename did not update declaration and reference");
		pump(client, () -> client.diagnosticsFor(document).length == 0, 30);

		var beforeFormatting = document.buffer.text, formatted:Null<LanguageEditResult> = null;
		require(client.formattingSupported && client.rangeFormattingSupported, "real server formatting capabilities missing");
		require(client.requestFormatting(document, selection, 2, true, false, Sys.time(), value -> formatted = value), "real formatting request unavailable");
		pump(client, () -> formatted != null, 30);
		require(formatted != null && formatted.applied && document.buffer.text != beforeFormatting
			&& document.buffer.text.indexOf("\n  var result") >= 0, "real formatter did not use two-space indentation");
		document.undo(selection);
		require(document.buffer.text == beforeFormatting, "real formatting was not undoable");
		Sys.println("PASS: real Haxeon document formatting with resolved style and undo");

		require(document.save() && File.getContent(source) == document.buffer.text, "fixed language-service document did not save");
		client.stop(Sys.time());
		pump(client, () -> client.status == "stopped", 5.0);
		processes.shutdown();

		Sys.println("PASS: real Haxeon LSP diagnoses, fixes, completes, resolves symbols/definitions/references and renames a local symbol");
		return 0;
	}
}
