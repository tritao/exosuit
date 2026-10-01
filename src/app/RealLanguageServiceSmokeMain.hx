package app;

import core.DocumentManager;
import editor.BufferSelection;
import language.LanguageServiceClient;
import platform.Native;
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
		require(condition(), "real Haxeon language service condition timed out: " + client.status);
	}

	static function main():Int {
		Platform.startHeadless();
		var arguments = Sys.args(), project = arguments[1], source = project + "/Main.hx";
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
		require(document.save() && File.getContent(source) == document.buffer.text, "fixed language-service document did not save");
		client.stop(Sys.time());
		pump(client, () -> client.status == "stopped", 5.0);
		processes.shutdown();
		Native.shutdown();
		Sys.println("PASS: real Haxeon LSP diagnosed an edit and cleared it after the fix");
		return 0;
	}
}
