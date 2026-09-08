package app;

import command.CommandContext;
import command.CommandRegistry;
import controller.LanguageController;
import core.FocusManager;
import editor.BufferPosition;
import platform.Native;
import platform.Platform;
import process.ProcessManager;
import renderer.Renderer;
import style.Theme;
import syntax.BuiltinSyntax;
import syntax.SyntaxRegistry;
import sys.io.File;
import view.RootView;
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

	static function main():Int {
		Platform.startHeadless();
		var arguments = Sys.args(), sourcePath = arguments[1] + "/Controller.hx";
		File.saveContent(sourcePath, "😀 value\n");
		var syntaxes = new SyntaxRegistry();
		BuiltinSyntax.install(syntaxes);
		var workspace = new Workspace(syntaxes);
		workspace.addProject(arguments[1]);
		var document = workspace.documents.open(sourcePath), focus = new FocusManager(), window = Native.window_create("language-controller", 640, 320),
			renderer = new Renderer(window, "ignored-headlessly.ttf", 15), root = new RootView(renderer, new Theme(), focus, workspace, 640, 320),
			view = root.openDocument(document), commands = new CommandRegistry(), context = new CommandContext(root, focus, workspace.documents),
			processes = new ProcessManager(), failures:Array<String> = [], controller = new LanguageController(workspace, root, context, commands, processes,
				"python3", (source, message) -> failures.push(source + ":" + message), [arguments[0]]);
		require(commands.perform("language:haxeon-start", context), "language start command was not installed");
		pump(controller, () -> controller.client != null && controller.client.ready, 5.0);
		var selection = view.getSelection();
		require(selection != null, "document view has no selection");
		selection.setCursor(document.buffer, new BufferPosition(0, 2));
		document.insert(selection, "x");
		pump(controller, () -> root.pluginDecorations.forDocument(document).length == 1, 5.0);
		require(commands.perform("language:hover", context), "hover command was not available");
		pump(controller, () -> root.languagePopup.visible, 5.0);
		require(root.languagePopup.visible, "hover was not surfaced through an anchored popup");
		root.languagePopup.close();
		require(commands.perform("language:complete", context), "completion command was not available");
		pump(controller, () -> root.languagePopup.visible, 5.0);
		require(root.languagePopup.visible && root.languagePopup.keyPressed(Platform.KEY_ESCAPE, 0),
			"completion was not surfaced through an interactive anchored popup");
		require(commands.perform("language:go-to-definition", context), "definition command was not available");
		for (_ in 0...32) controller.update(Sys.time());
		controller.shutdown();
		processes.shutdown();
		renderer.destroy();
		Native.window_destroy(window);
		Native.shutdown();
		require(failures.length == 0, "language controller reported unexpected errors");
		Sys.println("PASS: language commands, hover, completion, definition, and diagnostic decorations");
		return 0;
	}
}
