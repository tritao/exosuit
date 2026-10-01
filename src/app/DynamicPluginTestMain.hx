package app;

import core.Application;
import platform.Native;
import platform.Platform;
import plugin.DynamicPlugin;
import plugin.DynamicHostRouter;
import plugin.PluginManifest;
import renderer.Renderer;
import view.RootView;
import sys.FileSystem;
import sys.io.File;

class DynamicPluginTestMain {
	static function require(condition:Bool, message:String):Void {
		if (!condition)
			throw message;
	}

	static function main():Int {
		var arguments = Sys.args();
		require(arguments.length == 2, "expected manifest and source paths");
		// Extend only the disposable fixture to exercise SDK errors caught inside plugin code.
		File.saveContent(arguments[1], File.getContent(arguments[1])
			+ "\nfunction hostErrorProbe():Int { try { Editor.connect(\"missing-é😀\"); } catch (error:Dynamic) return error == 'plugin \"missing-é😀\" is not being activated' ? 1 : 2; return 0; }\n");
		Platform.startHeadless();
		var window = Native.window_create("dynamic-plugin-test", 320, 200),
			renderer = new Renderer(window, "ignored-headlessly.ttf", 15),
			application = new Application((theme, focus, workspace, settings) -> new RootView(renderer, theme, focus, workspace, 320, 200, settings)),
			root:RootView = cast application.root,
			plugin = new DynamicPlugin(new PluginManifest(arguments[0]));
		var separator = arguments[0].lastIndexOf("/"), pluginDirectory = arguments[0].substring(0, separator), incompatiblePath = pluginDirectory + "/incompatible.conf";
		File.saveContent(incompatiblePath, "manifestVersion=1\napiVersion=99\nid=incompatible\nversion=1.0.0\nsource=Main.hx\n");
		var errorsBeforeIncompatible = application.errors.entries.length;
		require(!application.loadPluginManifest(incompatiblePath) && application.errors.entries.length == errorsBeforeIncompatible + 1,
			"incompatible plugin API was not rejected with a visible diagnostic");
		application.newDocument();
		require(application.plugins.load(plugin), "dynamic plugin did not load");
		require(application.syntaxes.find("file.example").name == "Example", "manifest syntax did not register");
		require(plugin.callInt("hostErrorProbe") == 1, "host callback error did not reach the plugin with Unicode intact");
		require(plugin.callInt("hostProbe") == 42, "dynamic plugin direct host API probe failed");
		require(root.pluginPanels.find("example", "status") != null, "dynamic plugin did not invoke the host panel API during activation");
		require(root.pluginStatusItems.find("example", "mode") != null
			&& root.pluginDecorations.find("example", "first-character") != null,
			"dynamic plugin did not register its owned UI contributions");
		application.context.requireView().undo();
		var eventsBeforeCommand = plugin.callInt("eventCount");
		require(application.commands.perform("example:increment", application.context), "dynamic command did not dispatch");
		require(plugin.callInt("current") == 1, "dynamic command did not update plugin state");
		require(application.context.requireDocument().buffer.text == "dynamic", "dynamic command did not invoke the host document transaction API");
		require(plugin.callInt("eventCount") == eventsBeforeCommand + 1, "dynamic document event did not invoke the plugin callback exactly once");
		var panel = root.pluginPanels.find("example", "status");
		require(panel != null && panel.text == "dynamic", "dynamic plugin panel did not observe the document event");

		var source = File.getContent(arguments[1]);
		File.saveContent(arguments[1], StringTools.replace(source, "PluginState.value + 1", "PluginState.value + 2"));
		require(!plugin.update(10.0) && !plugin.update(10.2), "source edit bypassed the reload debounce");
		var revisionBeforeBackgroundCompile = plugin.revision;
		require(!plugin.update(10.31) && plugin.revision == revisionBeforeBackgroundCompile,
			"debounced compilation published on the observing event-loop turn");
		var compileWait = 0;
		while (plugin.revision == revisionBeforeBackgroundCompile && compileWait < 2000) {
			Sys.sleep(0.001);
			plugin.update(10.32 + compileWait * 0.001);
			compileWait++;
		}
		require(plugin.revision != revisionBeforeBackgroundCompile, 'background compatible source edit did not publish: ${plugin.lastError}');
		require(application.commands.perform("example:increment", application.context), "patched command did not dispatch");
		require(plugin.callInt("current") == 3, "compatible patch did not preserve state or replace behavior");
		var eventsAfterPatchedCommand = plugin.callInt("eventCount");
		require(application.context.requireDocument().buffer.text == "dynamicdynamic" && eventsAfterPatchedCommand == eventsBeforeCommand + 2,
			"patched dynamic plugin lost host API access or duplicated its event subscription");

		var compatibleSource = File.getContent(arguments[1]);
		File.saveContent(arguments[1], compatibleSource + "\nfunction unfinished(");
		require(!plugin.refresh() && plugin.lastError != null, "compile failure replaced the last working module");
		var eventsBeforeCompileFailureProbe = plugin.callInt("eventCount");
		require(plugin.callInt("hostProbe") == 42
			&& plugin.callInt("current") == 3
			&& plugin.callInt("eventCount") == eventsBeforeCompileFailureProbe + 1,
			"compile failure disabled the last working plugin");
		File.saveContent(arguments[1], compatibleSource);
		require(plugin.refresh() && plugin.lastError == null, "restoring last-good source did not clear the compile diagnostic");
		File.saveContent(arguments[1], StringTools.replace(compatibleSource, "public static var events = 0;",
			"public static var events = 0;\n\tpublic static var structural = 7;"));
		require(plugin.refresh(), 'structural source edit did not publish: ${plugin.lastError}');
		var eventsBeforeStructuralCommand = plugin.callInt("eventCount");
		require(application.commands.perform("example:increment", application.context)
			&& plugin.callInt("current") == 5
			&& plugin.callInt("eventCount") == eventsBeforeStructuralCommand + 1
			&& root.pluginPanels.find("example", "status") != null,
			"structural reload lost state, registrations, or installed duplicate callbacks");

		var structuralSource = File.getContent(arguments[1]);
		File.saveContent(arguments[1], StringTools.replace(structuralSource, "function activate():Void {",
			"function activate():Void {\n\tthrow \"injected activation failure\";"));
		require(!plugin.refresh() && plugin.lastError != null, "activation failure published a structural module");
		var eventsBeforeRollbackCommand = plugin.callInt("eventCount");
		require(application.commands.perform("example:increment", application.context)
			&& plugin.callInt("current") == 7
			&& plugin.callInt("eventCount") == eventsBeforeRollbackCommand + 1,
			"activation failure did not restore the last working module and registrations");
		File.saveContent(arguments[1], structuralSource);
		require(plugin.refresh(), 'plugin did not recover after activation failure: ${plugin.lastError}');
		var recoveredSource = File.getContent(arguments[1]);
		File.saveContent(arguments[1], StringTools.replace(recoveredSource, "function stateVersion():Int\n\treturn 1;",
			"function stateVersion():Int\n\treturn 2;\n\nclass IncompatibleStateShape {\n\tpublic static var marker = 1;\n}"));
		require(plugin.refresh() && plugin.callInt("current") == 0,
			"incompatible state version restored an obsolete state payload");
		structuralSource = File.getContent(arguments[1]);

		FileSystem.deleteFile(arguments[1]);
		var errorsBeforeRemoval = application.errors.entries.length;
		application.plugins.update(20.0);
		application.plugins.update(20.31);
		var removalWait = 0;
		while (plugin.busy() && removalWait < 2000) {
			Sys.sleep(0.001);
			application.plugins.update(20.32 + removalWait * 0.001);
			removalWait++;
		}
		require(plugin.lastError != null
			&& application.plugins.diagnostics().length == 1
			&& application.errors.entries.length == errorsBeforeRemoval + 1,
			"removed plugin source did not retain the last working module with a diagnostic");
		var eventsBeforeMissingSourceCommand = plugin.callInt("eventCount");
		require(application.commands.perform("example:increment", application.context)
			&& plugin.callInt("eventCount") == eventsBeforeMissingSourceCommand + 1,
			"source removal disabled the last working plugin");
		File.saveContent(arguments[1], structuralSource);
		application.plugins.update(21.0);
		application.plugins.update(21.31);
		var restoreWait = 0;
		while (plugin.busy() && restoreWait < 2000) {
			Sys.sleep(0.001);
			application.plugins.update(21.32 + restoreWait * 0.001);
			restoreWait++;
		}
		require(plugin.lastError == null && application.plugins.diagnostics().length == 0,
			"restoring unchanged working source did not clear its diagnostic");
		File.saveContent(arguments[1], structuralSource + "\n");
		application.plugins.update(30.0);
		application.plugins.update(30.31);
		require(plugin.busy(), "debounced source edit did not start background compilation");
		require(application.plugins.unload("example"), "dynamic plugin did not unload");
		Sys.sleep(0.05);
		var textAfterUnload = application.context.requireDocument().buffer.text;
		application.textInput("after");
		require(root.pluginPanels.find("example", "status") == null
			&& root.pluginStatusItems.find("example", "mode") == null
			&& root.pluginDecorations.find("example", "first-character") == null
			&& application.context.requireDocument().buffer.text != textAfterUnload, "dynamic plugin panel survived unload");

		application.shutdown();
		renderer.destroy();
		Platform.require(Native.window_destroy(window), "destroy dynamic plugin test window");
		Native.shutdown();
		Platform.startHeadless();
		DynamicHostRouter.initialize();
		require(Native.plugin_api_call(1, "1", "", "", "") == "error:dynamic plugin host token is invalid or retired",
			"host callback did not reinstall after shutdown or retained an unloaded token");
		Native.shutdown();
		Sys.println("PASS: manifest plugin loading and compatible hot reload");
		return 0;
	}
}
