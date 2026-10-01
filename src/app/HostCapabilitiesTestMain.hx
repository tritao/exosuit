package app;

import core.Application;
import platform.HostCapability;
import platform.HostCapabilities;
import platform.Native;
import platform.Platform;
import renderer.Renderer;
import view.RootView;

class HostCapabilitiesTestMain {
	static function require(condition:Bool, message:String):Void {
		if (!condition) throw message;
	}

	static function main():Int {
		Platform.startHeadless();
		var capabilities = HostCapabilities.browser();
		for (capability in [Processes, Threads, LocalIpc, Terminal, LanguageServices, SourcePlugins, Clipboard])
			require(!capabilities.supports(capability), 'browser advertised $capability');
		require(capabilities.supports(Filesystem) && capabilities.supports(Url), "browser session services missing");
		var supplied:Array<HostCapability> = [Filesystem];
		var immutable = new HostCapabilities(supplied);
		supplied.push(Processes);
		require(!immutable.supports(Processes), "host policy changed through constructor alias");
		require(!new HostCapabilities([LanguageServices, SourcePlugins]).supports(LanguageServices), "LSP lacks process prerequisite");
		require(!new HostCapabilities([SourcePlugins]).supports(SourcePlugins), "source plugins lack thread prerequisite");
		var renderer = new Renderer(Native.window_create("capabilities-test", 320, 200), "ignored.ttf", 15);
		var application = new Application((theme, focus, workspace, settings) ->
			new RootView(renderer, theme, focus, workspace, 320, 200, settings), null, null, capabilities);
		application.newDocument();
		for (command in application.commands.all()) {
			require(!StringTools.startsWith(command.name, "build:"), "build command leaked into restricted host");
			require(!StringTools.startsWith(command.name, "language:"), "language command leaked into restricted host");
			require(!StringTools.startsWith(command.name, "plugins:"), "source plugin command leaked into restricted host");
		}
		for (name in ["doc:copy", "doc:cut", "doc:paste"])
			require(!application.commands.contains(name) && !application.commands.perform(name, application.context), "clipboard command leaked");
		application.textInput("session text");
		require(application.context.requireDocument().buffer.text == "session text", "restricted host cannot edit");
		require(application.commands.perform("doc:undo", application.context), "restricted host lost undo command");
		require(application.context.requireDocument().buffer.text == "", "restricted host undo failed");
		require(!application.language.start() && !application.build.openTaskPicker(), "restricted services started");
		require(!application.loadPluginManifest("absent/plugin.conf"), "restricted host read a source plugin");
		require(application.errors.entries.length == 3, "unavailable services need clear feedback");
		require(application.processes.activeCount() == 0 && application.plugins.count() == 0, "restricted service owns resources");
		application.update();
		application.shutdown();
		Native.shutdown();
		Sys.println("PASS: typed host capabilities hide unavailable commands and preserve editing");
		return 0;
	}
}
