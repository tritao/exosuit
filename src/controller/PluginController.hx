package controller;

import command.CommandContext;
import command.CommandRegistry;
import command.Keymap;
import commandview.CommandViewEntry;
import commandview.CommandViewProvider;
import completion.CompletionRegistry;
import config.Settings;
import core.WorkbenchHost;
import jobs.JobScheduler;
#if !wasm
import plugin.NativeSourcePluginLoader;
#end
import plugin.PluginManager;
import plugin.SourcePluginLoader;
import plugin.PluginPanelRegistry;
import syntax.SyntaxRegistry;
import process.ProcessManager;

class PluginController {
	public final available:Bool;
	public final manager:PluginManager;

	var sourceLoader:Null<SourcePluginLoader>;
	final root:WorkbenchHost;
	final reportError:(String, String)->Void;
	final reportInformation:String->Void;

	public function new(commands:CommandRegistry, keymap:Keymap, context:CommandContext, syntaxes:SyntaxRegistry,
		completions:CompletionRegistry, panels:PluginPanelRegistry, jobs:JobScheduler, settings:Void->Settings, root:WorkbenchHost,
		processes:ProcessManager, reportError:(String, String)->Void, reportInformation:String->Void, available:Bool = true, ?sourceLoader:SourcePluginLoader) {
		this.sourceLoader = sourceLoader;
		#if !wasm
		if (available && this.sourceLoader == null) this.sourceLoader = new NativeSourcePluginLoader();
		#end
		this.available = available && this.sourceLoader != null;
		this.root = root;
		this.reportError = reportError;
		this.reportInformation = reportInformation;
		manager = new PluginManager(commands, keymap, context, syntaxes, completions, panels, root.getPluginDecorations(),
			root.getPluginStatusItems(), jobs, processes, settings,
			message -> reportError("plugin", message), this.available, this.sourceLoader);
		if (this.available) installCommands(commands);
	}

	public function loadManifest(path:String):Bool {
		if (!this.available) { reportError("plugin", "Source plugins are unavailable on this host"); return false; }
		var loader = sourceLoader;
		if (loader == null) return false;
		try {
			return manager.load(loader.load(path));
		} catch (error:Dynamic) {
			reportError("plugin", 'Could not load "$path": ' + Std.string(error));
			return false;
		}
	}

	public function update(now:Float):Void {
		try {
			manager.update(now);
		} catch (error:Dynamic) {
			reportError("plugin", Std.string(error));
		}
	}

	public function shutdown():Void
		manager.shutdown();

	public function openDiagnostics():Void {
		var entries = [for (diagnostic in manager.diagnostics()) new CommandViewEntry("Plugin error", diagnostic, diagnostic)];
		root.openCommandView(new CommandViewProvider("Plugin Diagnostics: ", entries, function(query) {}, function(entry, query, backwards) {
			root.closeCommandView();
		}));
	}

	function installCommands(commands:CommandRegistry):Void {
		commands.add("plugins:disable", context -> openAction("Disable Plugin: ", manager.enabledIds(), manager.disable),
			context -> manager.enabledIds().length > 0);
		commands.add("plugins:enable", context -> openAction("Enable Plugin: ", manager.disabledIds(), manager.enable),
			context -> manager.disabledIds().length > 0);
		commands.add("plugins:reload", context -> openAction("Reload Plugin: ", manager.enabledIds(), manager.reload),
			context -> manager.enabledIds().length > 0);
		commands.add("plugins:show-diagnostics", function(context) {
			openDiagnostics();
		});
	}

	function openAction(prompt:String, ids:Array<String>, action:String->Bool):Void {
		var entries = [for (id in ids) new CommandViewEntry(id, "", id)];
		root.openCommandView(new CommandViewProvider(prompt, entries, function(query) {}, function(entry, query, backwards) {
			if (entry != null)
				try {
					if (action(entry.value)) reportInformation(prompt + entry.value);
				} catch (error:Dynamic) {
					reportError("plugin", prompt + entry.value + ": " + Std.string(error));
				}
			root.closeCommandView();
		}));
	}
}
